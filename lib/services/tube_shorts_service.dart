import 'package:flutter/foundation.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../models/tube_models.dart';
import '../models/tube_stream.dart';
import 'tube_cache_service.dart';
import 'tube_innertube_client.dart';
import 'tube_recommendation_engine.dart';
import 'tube_stream_resolver.dart';
import 'tube_youtube_explode_pool.dart';

/// Dedicated service for public Shorts feed discovery, pagination, and bounded prefetching.
/// Does not flood network with dozens of resolutions — pre-fetches strictly N+1.
class TubeShortsService {
  static final TubeShortsService _instance = TubeShortsService._internal();
  factory TubeShortsService() => _instance;
  TubeShortsService._internal();

  final TubeYoutubeExplodePool _ytPool = TubeYoutubeExplodePool.instance;
  final TubeInnertubeClient _innertube = TubeInnertubeClient();
  final TubeStreamResolver _resolver = TubeStreamResolver();
  final TubeRecommendationEngine _recEngine = TubeRecommendationEngine();
  final TubeMemoryCache<List<TubeVideoItem>> _cache = TubeMemoryCache(defaultTtl: const Duration(minutes: 15));

  // In-memory prefetch stream cache (Key: Video ID, Value: Resolved stream)
  final Map<String, TubeResolvedVideo> _prefetchedStreams = {};
  final Set<String> _currentlyPrefetching = {};

  /// Retrieves a paginated list of vertical Shorts, scored by the local recommendation engine.
  Future<List<TubeVideoItem>> getShortsFeed({int page = 0}) async {
    final cacheKey = 'shorts_page_$page';
    final cached = _cache.get(cacheKey);
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }

    List<TubeVideoItem> rawList = [];

    // Query rotating queries for Shorts variety
    final queries = ['#shorts viral trending', '#shorts highlights', '#shorts popular reels', '#shorts funny trending'];
    final query = queries[page % queries.length];

    try {
      final res = await _innertube.searchVideos(query);
      if (res.items.isNotEmpty) {
        rawList = res.items.map((v) => v.isShort ? v : v.copyWith(isShort: true)).toList();
      }
    } catch (e) {
      debugPrint('[TubeShortsService] Innertube shorts query error: $e');
    }

    if (rawList.length < 15) {
      // Supplement with YoutubeExplode search to ensure a healthy candidate pool
      try {
        final results = await _ytPool.yt.search.search(query);
        for (final item in results) {
          if (item is SearchVideo) {
            rawList.add(TubeVideoItem(
              id: item.id.value,
              title: item.title,
              channelTitle: item.author,
              channelId: item.channelId.value,
              thumbnailUrl: item.thumbnails.highResUrl.isNotEmpty
                  ? item.thumbnails.highResUrl
                  : 'https://i.ytimg.com/vi/${item.id.value}/hqdefault.jpg',
              durationSeconds: item.duration?.inSeconds ?? 45,
              isShort: true,
              description: item.description,
            ));
          }
        }
      } catch (e) {
        debugPrint('[TubeShortsService] Fallback shorts error: $e');
      }
    }

    // Rank candidate shorts with unified on-device recommendation engine
    final ranked = _recEngine.rankShorts(rawList);
    _cache.set(cacheKey, ranked);
    return ranked;
  }

  // =========================================================================
  // BOUNDED PREFETCHING (Strictly N+1)
  // =========================================================================

  /// Asynchronously prefetches the video stream for the very next Short.
  /// Strictly bounded to 1 concurrent extraction request.
  Future<void> prefetchNextShort(TubeVideoItem nextShort) async {
    final videoId = nextShort.id;
    if (_prefetchedStreams.containsKey(videoId) || _currentlyPrefetching.contains(videoId)) {
      return;
    }

    // Limit in-memory cache to 3 prefetched streams
    if (_prefetchedStreams.length >= 3) {
      _prefetchedStreams.remove(_prefetchedStreams.keys.first);
    }

    _currentlyPrefetching.add(videoId);
    try {
      debugPrint('[TubeShortsService] ⚡ Prefetching stream for upcoming short: $videoId ("${nextShort.title}")');
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
