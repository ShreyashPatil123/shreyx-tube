import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../models/tube_stream.dart';
import 'tube_cache_service.dart';
import 'tube_youtube_explode_pool.dart';

class TubeMembersOnlyException implements Exception {
  const TubeMembersOnlyException();
}

class TubeStreamResolver {
  static final TubeStreamResolver _instance = TubeStreamResolver._internal();
  factory TubeStreamResolver() => _instance;
  TubeStreamResolver._internal() : _loader = null;
  @visibleForTesting
  TubeStreamResolver.withLoader(this._loader);
  final Future<TubeResolvedVideo> Function(String)? _loader;

  static const MethodChannel _extractorChannel =
      MethodChannel('com.shreyx.tube/native_extractor');
  final TubeYoutubeExplodePool _ytPool = TubeYoutubeExplodePool.instance;
  final Map<String, Future<TubeResolvedVideo>> _pending = {};

  // Ephemeral stream cache (YouTube stream URLs remain valid for ~6 hours; 2h TTL provides high hit rate with safety)
  final TubeMemoryCache<TubeResolvedVideo> _streamCache =
      TubeMemoryCache(defaultTtl: const Duration(hours: 2), maxCapacity: 25);

  /// Extracts the 11-character YouTube video ID from various URL patterns
  String extractVideoId(String input) {
    final trimmed = input.trim();
    if (trimmed.length == 11 &&
        RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(trimmed)) {
      return trimmed;
    }

    final vMatch = RegExp(r'[?&]v=([a-zA-Z0-9_-]{11})').firstMatch(trimmed);
    if (vMatch != null) return vMatch.group(1)!;

    final shortMatch =
        RegExp(r'youtu\.be/([a-zA-Z0-9_-]{11})').firstMatch(trimmed);
    if (shortMatch != null) return shortMatch.group(1)!;

    final liveMatch =
        RegExp(r'youtube\.com/live/([a-zA-Z0-9_-]{11})').firstMatch(trimmed);
    if (liveMatch != null) return liveMatch.group(1)!;

    final shortsMatch =
        RegExp(r'youtube\.com/shorts/([a-zA-Z0-9_-]{11})').firstMatch(trimmed);
    if (shortsMatch != null) return shortsMatch.group(1)!;

    return trimmed;
  }

  /// Multi-tier stream resolution:
  /// 1. Android NewPipeExtractor (Tier 1)
  /// 2. youtube_explode_dart fallback (Tier 2)
  /// 3. In-memory ephemeral stream caching (2-hour TTL)
  Future<TubeResolvedVideo> resolve(String rawUrlOrId,
      {bool forceRefresh = false}) async {
    final videoId = extractVideoId(rawUrlOrId);
    if (forceRefresh) _streamCache.remove(videoId);
    final existing = _pending[videoId];
    if (existing != null) return existing;
    final task = _resolve(videoId, forceRefresh: forceRefresh);
    _pending[videoId] = task;
    try {
      return await task;
    } finally {
      if (identical(_pending[videoId], task)) _pending.remove(videoId);
    }
  }

  Future<TubeResolvedVideo> _resolve(String rawUrlOrId,
      {bool forceRefresh = false}) async {
    final videoId = extractVideoId(rawUrlOrId);
    if (videoId.isEmpty || videoId.length != 11) {
      throw Exception('Invalid YouTube Video ID or URL: "$rawUrlOrId"');
    }

    if (!forceRefresh) {
      final cached = _streamCache.get(videoId);
      if (cached != null) {
        debugPrint(
            '[TubeStreamResolver] ⚡ Cache HIT for $videoId (skipping extraction)');
        return cached;
      }
    }

    debugPrint('[TubeStreamResolver] Resolving stream for videoId: $videoId');
    final loader = _loader;
    if (loader != null) {
      final result = await loader(videoId);
      _streamCache.set(videoId, result);
      return result;
    }

    // Tier 1: Android Native NewPipeExtractor
    if (Platform.isAndroid) {
      try {
        final nativeResult = await _resolveNative(videoId);
        if (nativeResult != null) {
          _streamCache.set(videoId, nativeResult);
          return nativeResult;
        }
      } catch (e) {
        if (_isMembershipError(e)) throw const TubeMembersOnlyException();
        debugPrint(
            '[TubeStreamResolver] Native NewPipe failed: $e, trying Tier 2 (youtube_explode_dart)...');
      }
    }

    // Tier 2: youtube_explode_dart Fallback
    try {
      final fallbackResult = await _resolveYoutubeExplode(videoId);
      _streamCache.set(videoId, fallbackResult);
      return fallbackResult;
    } catch (e) {
      if (_isMembershipError(e)) throw const TubeMembersOnlyException();
      debugPrint('[TubeStreamResolver] youtube_explode_dart failed: $e');
      throw Exception(
          'Failed to resolve video ($videoId). Please check connection or verify the video is publicly available.');
    }
  }

  bool _isMembershipError(Object error) {
    if (error is TubeMembersOnlyException) return true;
    final message = error.toString().toLowerCase();
    return message.contains('members-only') ||
        message.contains('members only') ||
        message.contains('join this channel');
  }

  Future<TubeResolvedVideo?> _resolveNative(String videoId) async {
    final dynamic res =
        await _extractorChannel.invokeMethod('extractVideoStreams', {
      'videoId': videoId,
    }).timeout(const Duration(seconds: 18));

    if (res is Map && res['ok'] != true && _isMembershipError(res)) {
      throw const TubeMembersOnlyException();
    }
    if (res is Map && res['ok'] == true) {
      final rawProg = (res['progressiveStreams'] as List<dynamic>?) ?? [];
      final rawVideoOnly = (res['videoOnlyStreams'] as List<dynamic>?) ?? [];
      final rawAudio = (res['audioStreams'] as List<dynamic>?) ?? [];
      final rawSubtitles = (res['subtitles'] as List<dynamic>?) ?? [];

      final progressive =
          rawProg.map((e) => TubeVideoStream.fromMap(e as Map)).toList();
      final videoOnly =
          rawVideoOnly.map((e) => TubeVideoStream.fromMap(e as Map)).toList();
      final audio =
          rawAudio.map((e) => TubeAudioStream.fromMap(e as Map)).toList();
      final subtitles =
          rawSubtitles.map((e) => TubeSubtitle.fromMap(e as Map)).toList();

      // Pair best audio stream (Opus 160kbps / AAC) with adaptive video-only streams
      TubeAudioStream? bestAudio;
      if (audio.isNotEmpty) {
        // Prefer Opus audio >= 140kbps, then AAC
        bestAudio = audio.firstWhere(
          (a) => a.codec.toLowerCase().contains('opus') && a.bitrate >= 140000,
          orElse: () => audio.reduce((a, b) => a.bitrate > b.bitrate ? a : b),
        );
      }

      for (final vs in videoOnly) {
        vs.pairedAudioUrl = bestAudio?.url;
      }

      final allVideoStreams = [...progressive, ...videoOnly];
      allVideoStreams.sort((a, b) {
        final hDiff = b.height.compareTo(a.height);
        if (hDiff != 0) return hDiff;
        return b.bitrate.compareTo(a.bitrate);
      });

      return TubeResolvedVideo(
        videoId: videoId,
        title: res['title']?.toString() ?? 'YouTube Video',
        uploader: res['uploader']?.toString() ?? 'Unknown Creator',
        uploaderUrl: res['uploaderUrl']?.toString() ?? '',
        uploaderAvatarUrl: res['uploaderAvatarUrl']?.toString() ?? '',
        durationSeconds: (res['durationSeconds'] as num?)?.toInt() ?? 0,
        thumbnailUrl: res['thumbnailUrl']?.toString() ??
            'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
        videoStreams: allVideoStreams,
        audioStreams: audio,
        subtitles: subtitles,
        hlsUrl: res['hlsUrl']?.toString(),
        dashMpdUrl: res['dashMpdUrl']?.toString(),
        extractorSource: res['extractor']?.toString() ?? 'NewPipeExtractor',
        isLive: res['isLive'] == true,
      );
    }
    return null;
  }

  Future<TubeResolvedVideo> _resolveYoutubeExplode(String videoId) async {
    final videoFuture = _ytPool.yt.videos.get(videoId);
    final manifestFuture = _ytPool.yt.videos.streamsClient
        .getManifest(videoId)
        .then<StreamManifest?>((value) => value)
        .catchError((_) => null);
    final results = await Future.wait<dynamic>([videoFuture, manifestFuture]);
    final video = results[0] as Video;
    if (video.isLive) {
      final hls = await _ytPool.yt.videos.streamsClient
          .getHttpLiveStreamUrl(VideoId(videoId));
      return TubeResolvedVideo(
          videoId: videoId,
          title: video.title,
          uploader: video.author,
          durationSeconds: 0,
          thumbnailUrl: video.thumbnails.highResUrl,
          videoStreams: [],
          audioStreams: [],
          subtitles: [],
          hlsUrl: hls,
          extractorSource: 'youtube_explode_dart',
          isLive: true);
    }
    final manifest = results[1] as StreamManifest?;
    if (manifest == null) throw Exception('Video streams are unavailable');

    final List<TubeVideoStream> videoStreams = [];
    final List<TubeAudioStream> audioStreams = [];

    // Muxed progressive streams (360p / 720p)
    for (final s in manifest.muxed) {
      videoStreams.add(TubeVideoStream(
        url: s.url.toString(),
        resolution: '${s.videoResolution.height}p',
        width: s.videoResolution.width,
        height: s.videoResolution.height,
        container: s.container.name,
        mimeType: s.codec.mimeType,
        codec: s.videoCodec,
        fps: s.framerate.framesPerSecond.toInt(),
        bitrate: s.bitrate.bitsPerSecond.toInt(),
        isVideoOnly: false,
        deliveryMethod: 'PROGRESSIVE',
        manifestType: 'PROGRESSIVE',
      ));
    }

    // Audio-only streams
    for (final a in manifest.audioOnly) {
      audioStreams.add(TubeAudioStream(
        url: a.url.toString(),
        container: a.container.name,
        mimeType: a.codec.mimeType,
        codec: a.audioCodec,
        bitrate: a.bitrate.bitsPerSecond.toInt(),
      ));
    }

    // Pick best audio for merging
    TubeAudioStream? bestAudio;
    if (audioStreams.isNotEmpty) {
      bestAudio = audioStreams.reduce((a, b) => a.bitrate > b.bitrate ? a : b);
    }

    // Adaptive video-only streams (1080p, 1440p, 4K)
    for (final v in manifest.videoOnly) {
      videoStreams.add(TubeVideoStream(
        url: v.url.toString(),
        resolution: '${v.videoResolution.height}p',
        width: v.videoResolution.width,
        height: v.videoResolution.height,
        container: v.container.name,
        mimeType: v.codec.mimeType,
        codec: v.videoCodec,
        fps: v.framerate.framesPerSecond.toInt(),
        bitrate: v.bitrate.bitsPerSecond.toInt(),
        isVideoOnly: true,
        deliveryMethod: 'DASH_ADAPTIVE',
        manifestType: 'ADAPTIVE_VIDEO_ONLY',
        pairedAudioUrl: bestAudio?.url,
      ));
    }

    videoStreams.sort((a, b) => b.height.compareTo(a.height));

    // Captions arrive independently and never hold up the first video frame.
    final List<TubeSubtitle> subtitles = [];
    unawaited(_loadFallbackCaptions(videoId, subtitles));

    return TubeResolvedVideo(
      videoId: videoId,
      title: video.title,
      uploader: video.author,
      durationSeconds: video.duration?.inSeconds ?? 0,
      thumbnailUrl: video.thumbnails.highResUrl,
      videoStreams: videoStreams,
      audioStreams: audioStreams,
      subtitles: subtitles,
      extractorSource: 'youtube_explode_dart',
    );
  }

  Future<void> _loadFallbackCaptions(
      String videoId, List<TubeSubtitle> subtitles) async {
    try {
      final trackManifest = await _ytPool.yt.videos.closedCaptions
          .getManifest(VideoId(videoId))
          .timeout(const Duration(seconds: 6));
      for (final track in trackManifest.tracks) {
        subtitles.add(TubeSubtitle(
          url: track.url.toString(),
          languageName: track.language.name,
          languageCode: track.language.code,
          format: 'vtt',
          isAutoGenerated: track.isAutoGenerated,
        ));
      }
    } catch (_) {}
  }

  /// Invalidate cache for a specific video ID (e.g. on 403 or stream expiration)
  void invalidateCache(String videoId) {
    _streamCache.remove(videoId);
  }
}
