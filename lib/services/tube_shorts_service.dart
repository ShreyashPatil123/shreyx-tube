import 'package:flutter/foundation.dart';
import '../models/tube_models.dart';
import '../models/tube_stream.dart';
import 'tube_cache_service.dart';
import 'tube_innertube_client.dart';
import 'tube_stream_resolver.dart';

/// Dedicated service for public Shorts feed discovery, pagination, and bounded prefetching.
/// Does not flood network with dozens of resolutions — pre-fetches strictly N+1.
class TubeShortsService {
  static final TubeShortsService _instance = TubeShortsService._internal();
  factory TubeShortsService() => _instance;
  TubeShortsService._internal() : _innertube = TubeInnertubeClient();
  TubeShortsService.withClient(this._innertube);

  final TubeInnertubeClient _innertube;
  final TubeStreamResolver _resolver = TubeStreamResolver();
  final TubeMemoryCache<List<TubeVideoItem>> _cache =
      TubeMemoryCache(defaultTtl: const Duration(minutes: 15));

  // In-memory prefetch stream cache (Key: Video ID, Value: Resolved stream)
  final Map<String, TubeResolvedVideo> _prefetchedStreams = {};
  final Set<String> _currentlyPrefetching = {};

  final Map<int, String?> _continuations = {};
  final Set<String> _seen = {};

  /// Keeps the public Shorts ordering and follows actual continuation cursors.
  Future<List<TubeVideoItem>> getShortsFeed({int page = 0}) async {
    final cacheKey = 'shorts_page_$page';
    final cached = _cache.get(cacheKey);
    if (cached != null) return cached;
    if (page == 0) {
      _seen.clear();
      _continuations.clear();
    }
    final token = _continuations[page - 1];
    if (page > 0 && token == null) return [];
    final result = await _innertube.searchVideos('#shorts viral trending',
        continuation: token);
    _continuations[page] =
        result.continuationToken == token ? null : result.continuationToken;
    // A short duration or a #shorts title does not establish a Shorts video.
    final items = result.items
        .where((video) => video.isShort && _seen.add(video.id))
        .toList();
    _cache.set(cacheKey, items);
    return items;
  }
  // =========================================================================
  // BOUNDED PREFETCHING (Strictly N+1)
  // =========================================================================

  /// Asynchronously prefetches the video stream for the very next Short.
  /// Strictly bounded to 1 concurrent extraction request.
  Future<void> prefetchNextShort(TubeVideoItem nextShort) async {
    final videoId = nextShort.id;
    if (_prefetchedStreams.containsKey(videoId) ||
        _currentlyPrefetching.contains(videoId)) {
      return;
    }

    // Limit in-memory cache to 3 prefetched streams
    if (_prefetchedStreams.length >= 3) {
      _prefetchedStreams.remove(_prefetchedStreams.keys.first);
    }

    _currentlyPrefetching.add(videoId);
    try {
      debugPrint(
          '[TubeShortsService] ⚡ Prefetching stream for upcoming short: $videoId ("${nextShort.title}")');
      final resolved = await _resolver.resolve(videoId);
      _prefetchedStreams[videoId] = resolved;
    } catch (e) {
      debugPrint('[TubeShortsService] Prefetching skipped for $videoId: $e');
    } finally {
      _currentlyPrefetching.remove(videoId);
    }
  }

  /// Returns prefetched resolved video if available, and frees it from cache
  TubeResolvedVideo? getPrefetchedStream(String videoId) {
    return _prefetchedStreams.remove(videoId);
  }
}
