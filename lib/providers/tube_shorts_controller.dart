import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/tube_models.dart';
import '../models/tube_stream.dart';
import '../services/tube_database_service.dart';
import '../services/tube_home_feed_service.dart';
import '../services/tube_shorts_service.dart';
import '../services/tube_storage_service.dart';
import '../services/tube_stream_resolver.dart';
import '../services/tube_user_profile_service.dart';
import 'tube_player_provider.dart';

/// Dedicated controller for the vertical Shorts feed.
/// Features:
/// - Single active short playback enforcement (stops previous short immediately)
/// - Pauses main video player so only one audio/video stream ever plays
/// - Bounded N+1 prefetching
/// - Continuous pagination before reaching bottom
/// - Mute/unmute volume control
/// - Tap to play/pause with ripple HUD
/// - On-device fast-skip and completion behavioral tracking
class TubeShortsController extends ChangeNotifier {
  final TubeShortsService _shortsService = TubeShortsService();
  final TubeStreamResolver _resolver = TubeStreamResolver();
  final TubeStorageService _storage = TubeStorageService();

  static const MethodChannel _channel = MethodChannel('com.shreyx.tube/shorts_player_channel');

  List<TubeVideoItem> _shorts = [];
  int _activeIndex = 0;
  bool _isLoadingFeed = false;
  bool _isLoadingActiveShort = false;
  bool _isPlaying = false;
  bool _isBuffering = false;
  bool _isMuted = false;
  String? _errorMessage;
  int _feedPage = 0;
  bool _isFetchingMore = false;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  // Active watch metrics for local recommendation scoring
  DateTime? _activeShortStartTime;
  bool _isScreenActive = false;

  // Getters
  List<TubeVideoItem> get shorts => List.unmodifiable(_shorts);
  int get activeIndex => _activeIndex;
  TubeVideoItem? get activeShort => _shorts.isNotEmpty && _activeIndex < _shorts.length ? _shorts[_activeIndex] : null;
  bool get isLoadingFeed => _isLoadingFeed;
  bool get isLoadingActiveShort => _isLoadingActiveShort;
  bool get isPlaying => _isPlaying;
  bool get isBuffering => _isBuffering;
  bool get isMuted => _isMuted;
  bool get isScreenActive => _isScreenActive;
  String? get errorMessage => _errorMessage;
  Duration get position => _position;
  Duration get duration => _duration;
  double get progressRatio => _duration.inMilliseconds > 0 ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0) : 0.0;

  TubeShortsController() {
    _initChannel();
    // Do NOT load or play initial feed on construction.
    // Feed and playback are strictly initiated only when the Shorts screen becomes active.
  }

  /// Explicitly called when user opens the Shorts tab
  void activateScreen({TubePlayerProvider? mainPlayerProvider}) {
    _isScreenActive = true;
    mainPlayerProvider?.pause();
    if (_shorts.isEmpty) {
      loadInitialFeed(autoPlay: true);
    } else if (!_isPlaying) {
      playShortAtIndex(_activeIndex);
    }
  }

  /// Explicitly called when user leaves the Shorts tab or app is backgrounded
  void deactivateScreen() {
    _isScreenActive = false;
    _recordPreviousShortMetrics();
    pause();
    _channel.invokeMethod('stop');
  }

  void _initChannel() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onPlaybackStateChanged':
          final args = call.arguments as Map<dynamic, dynamic>?;
          final state = args?['state']?.toString();
          if (state == 'BUFFERING') {
            _isBuffering = true;
          } else if (state == 'READY') {
            _isBuffering = false;
            _errorMessage = null;
          }
          notifyListeners();
          break;
        case 'onIsPlayingChanged':
          _isPlaying = call.arguments as bool? ?? false;
          notifyListeners();
          break;
        case 'onProgressUpdate':
          final data = call.arguments as Map<dynamic, dynamic>?;
          if (data != null) {
            _position = Duration(milliseconds: (data['positionMs'] as num?)?.toInt() ?? 0);
            final durMs = (data['durationMs'] as num?)?.toInt() ?? 0;
            if (durMs > 0) _duration = Duration(milliseconds: durMs);
            _isPlaying = data['isPlaying'] as bool? ?? false;
            _isBuffering = data['isBuffering'] as bool? ?? false;
            notifyListeners();
          }
          break;
        case 'onPlaybackError':
          final errMap = call.arguments as Map<dynamic, dynamic>?;
          _errorMessage = errMap?['message']?.toString() ?? 'Failed to play short';
          _isBuffering = false;
          _isLoadingActiveShort = false;
          notifyListeners();
          break;
      }
    });
  }

  Future<void> loadInitialFeed({bool autoPlay = false}) async {
    _isLoadingFeed = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final list = await _shortsService.getShortsFeed(page: 0);
      _shorts = list;
      _isLoadingFeed = false;
      notifyListeners();

      if (_shorts.isNotEmpty && autoPlay && _isScreenActive) {
        // Start playing the first short only if screen is explicitly active
        await playShortAtIndex(0);
      }
    } catch (e) {
      _errorMessage = 'Failed to load Shorts feed. Tap Retry.';
      _isLoadingFeed = false;
      notifyListeners();
    }
  }

  Future<void> fetchMoreShorts() async {
    if (_isFetchingMore) return;
    _isFetchingMore = true;
    _feedPage++;

    try {
      final more = await _shortsService.getShortsFeed(page: _feedPage);
      if (more.isNotEmpty) {
        // Filter duplicates
        final existingIds = _shorts.map((s) => s.id).toSet();
        final newItems = more.where((s) => !existingIds.contains(s.id)).toList();
        _shorts.addAll(newItems);
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[TubeShortsController] Fetch more error: $e');
    } finally {
      _isFetchingMore = false;
    }
  }

  /// Paging handler when user swipes up or down
  Future<void> onPageChanged(int newIndex, {TubePlayerProvider? mainPlayerProvider}) async {
    if (newIndex == _activeIndex && _isPlaying) return;

    // 1. Record metrics for the previous short before leaving
    _recordPreviousShortMetrics();

    // 2. Stop previous short immediately
    await _channel.invokeMethod('stop');
    _isLoadingActiveShort = true;
    _activeIndex = newIndex;
    _errorMessage = null;
    _position = Duration.zero;
    _duration = Duration.zero;
    notifyListeners();

    // 3. Ensure main video player is paused so never two playbacks run
    mainPlayerProvider?.pause();

    // 4. Play the new active short
    await playShortAtIndex(newIndex);

    // 5. Trigger bounded N+1 prefetch
    if (newIndex + 1 < _shorts.length) {
      _shortsService.prefetchNextShort(_shorts[newIndex + 1]);
    }

    // 6. Paginate if approaching end (within 3 items)
    if (newIndex >= _shorts.length - 3) {
      fetchMoreShorts();
    }
  }

  Future<void> playShortAtIndex(int index, {TubePlayerProvider? mainPlayerProvider}) async {
    if (index < 0 || index >= _shorts.length) return;
    if (!_isScreenActive) {
      debugPrint('[TubeShortsController] Ignored playShortAtIndex($index) - screen not active');
      return;
    }
    mainPlayerProvider?.pause();
    final short = _shorts[index];
    _activeIndex = index;
    _isLoadingActiveShort = true;
    _errorMessage = null;
    _activeShortStartTime = DateTime.now();
    notifyListeners();

    try {
      // 1. Check if stream was already prefetched
      TubeResolvedVideo? resolved = _shortsService.getPrefetchedStream(short.id);
      resolved ??= await _resolver.resolve(short.id);

      // Re-verify index has not changed and screen is still active after async resolve
      if (_activeIndex != index || !_isScreenActive) {
        debugPrint('[TubeShortsController] Aborted playback: index $index superseded by $_activeIndex');
        return;
      }

      final stream = resolved.getBestStream('720p') ?? resolved.getBestStream('360p');
      if (stream == null) {
        throw Exception('No playable video stream found for this Short.');
      }

      final params = stream.toMediaParams(autoPlay: true);

      await _channel.invokeMethod('loadMedia', params);
      _isLoadingActiveShort = false;
      notifyListeners();
    } catch (e) {
      debugPrint('[TubeShortsController] Error resolving/playing short: $e');
      _errorMessage = 'Could not load Short. Tap to retry.';
      _isLoadingActiveShort = false;
      notifyListeners();
    }
  }

  void togglePlayPause({TubePlayerProvider? mainPlayerProvider}) {
    if (_isPlaying) {
      pause();
    } else {
      play(mainPlayerProvider: mainPlayerProvider);
    }
  }

  void play({TubePlayerProvider? mainPlayerProvider}) {
    if (!_isScreenActive) return;
    mainPlayerProvider?.pause();
    _channel.invokeMethod('play');
    _isPlaying = true;
    notifyListeners();
  }

  void pause() {
    _channel.invokeMethod('pause');
    _isPlaying = false;
    notifyListeners();
  }

  void toggleMute() {
    _isMuted = !_isMuted;
    _channel.invokeMethod('setMuted', {'muted': _isMuted});
    notifyListeners();
  }

  void retryActiveShort() {
    if (_shorts.isNotEmpty) {
      playShortAtIndex(_activeIndex);
    } else {
      loadInitialFeed();
    }
  }

  void _recordPreviousShortMetrics() {
    if (activeShort == null || _activeShortStartTime == null) return;
    final watchDurationSec = DateTime.now().difference(_activeShortStartTime!).inSeconds;
    final durSec = _duration.inSeconds > 0 ? _duration.inSeconds : 45;
    final ratio = (watchDurationSec / durSec).clamp(0.0, 1.0);
    final isFastSkip = watchDurationSec < 3 && ratio < 0.15;

    final signal = TubeWatchSignal(
      videoId: activeShort!.id,
      channelTitle: activeShort!.channelTitle,
      completionRatio: ratio,
      watchDurationSeconds: watchDurationSec,
      isFastSkip: isFastSkip,
      timestamp: DateTime.now(),
    );

    _storage.recordWatchSignal(signal);
    TubeUserProfileService().updateFromWatchSignal(signal);
    TubeHomeFeedService().invalidateRecommendedFeed();
    TubeDatabaseService.instance.insertWatchSignal({
      'video_id': activeShort!.id,
      'channel_id': activeShort!.channelId,
      'topics': jsonEncode([]),
      'completion_ratio': ratio,
      'watch_duration_ms': watchDurationSec * 1000,
      'is_fast_skip': isFastSkip ? 1 : 0,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  @override
  void dispose() {
    _recordPreviousShortMetrics();
    _channel.invokeMethod('stop');
    super.dispose();
  }
}
