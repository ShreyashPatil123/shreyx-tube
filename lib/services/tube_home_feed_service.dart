import 'package:flutter/foundation.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../models/tube_models.dart';
import 'tube_cache_service.dart';
import 'tube_feed_refresh_controller.dart';
import 'tube_innertube_client.dart';
import 'tube_recommendation_engine.dart';
import 'tube_storage_service.dart';
import 'tube_user_profile_service.dart';
import 'tube_youtube_explode_pool.dart';

/// Service dedicated to Home Feed discovery, category browsing, and personalized recommendations.
/// Enforces fresh Home feeds on every cold app launch, daily feed rotation, and seamless pagination.
class TubeHomeFeedService {
  static final TubeHomeFeedService _instance = TubeHomeFeedService._internal();
  factory TubeHomeFeedService() => _instance;
  TubeHomeFeedService._internal();

  final TubeInnertubeClient _innertube = TubeInnertubeClient();
  final TubeYoutubeExplodePool _ytPool = TubeYoutubeExplodePool.instance;
  final TubeRecommendationEngine _recEngine = TubeRecommendationEngine();
  final TubeUserProfileService _profileService = TubeUserProfileService();
  final TubeFeedRefreshController _refreshController = TubeFeedRefreshController();
  final TubeStorageService _storage = TubeStorageService();

  final TubeMemoryCache<List<TubeVideoItem>> _cache =
      TubeMemoryCache(defaultTtl: const Duration(minutes: 10));

  final Map<String, String?> _categoryContinuationTokens = {};
  final Map<String, List<TubeVideoItem>> _candidateCache = {};

  static const Map<String, String> categoryQueries = {
    'Recommended': 'trending today latest videos',
    'Trending': 'trending today viral new',
    'Music': 'official music video trending 2026',
    'Gaming': 'new gaming highlights gameplay trailers',
    'Technology': 'latest tech innovations gadgets review',
    'Education': 'science documentary education lecture new',
    'News': 'global news headlines today live',
    'Sports': 'sports highlights best moments match today',
  };

  /// Invalidates the cached Recommended feed so the next view reflects recent watch behavior.
  void invalidateRecommendedFeed() {
    _cache.remove('category_Recommended');
    _candidateCache.remove('category_Recommended');
    _categoryContinuationTokens.remove('Recommended');
  }

  /// Generates a fresh candidate pool combining category search, trending, user watching behavior, and followed channels
  Future<List<TubeVideoItem>> generateFreshCandidates(String category) async {
    final List<TubeVideoItem> candidatePool = [];
    final List<String> queries = [];

    if (category == 'Recommended') {
      // 1. Incorporate user's learned topics from active watching signals
      final profile = _profileService.profile;
      final topTopics = profile.shortTermTopics.entries
          .where((e) => e.value >= 0.15)
          .toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      for (final t in topTopics.take(2)) {
        queries.add('${t.key} latest');
      }

      // 2. Incorporate recent creators from watch history
      final history = _storage.getWatchHistory();
      final recentCreators = history
          .take(3)
          .map((h) => h.video.channelTitle)
          .where((title) => title.isNotEmpty)
          .toSet();
      for (final creator in recentCreators) {
        queries.add('$creator new');
      }

      // 3. Contemporary trending & viral candidates
      queries.add('trending today latest videos');
      queries.add('new popular videos');
    } else {
      queries.add(categoryQueries[category] ?? 'trending today');
    }

    // 1. Primary: Fetch candidates across dynamic queries from Innertube
    for (final q in queries.take(3)) {
      try {
        final res = await _innertube.searchVideos(q);
        candidatePool.addAll(res.items);
        if (_categoryContinuationTokens[category] == null && res.continuationToken != null) {
          _categoryContinuationTokens[category] = res.continuationToken;
        }
      } catch (e) {
        debugPrint('[TubeHomeFeedService] Innertube candidate error for "$q": $e');
      }
    }

    // 2. Fallback / Augment: YoutubeExplode search if candidates are sparse
    if (candidatePool.length < 15) {
      final fallbackQuery = queries.first;
      try {
        final searchList = await _ytPool.yt.search.search(fallbackQuery);
        for (final item in searchList) {
          if (item is SearchVideo) {
            candidatePool.add(TubeVideoItem(
              id: item.id.value,
              title: item.title,
              channelTitle: item.author,
              channelId: item.channelId.value,
              thumbnailUrl: item.thumbnails.highResUrl.isNotEmpty
                  ? item.thumbnails.highResUrl
                  : 'https://i.ytimg.com/vi/${item.id.value}/hqdefault.jpg',
              durationSeconds: item.duration?.inSeconds ?? 0,
              uploadDate: item.uploadDate,
              description: item.description,
            ));
          }
        }
      } catch (e) {
        debugPrint('[TubeHomeFeedService] Fallback pool error: $e');
      }
    }

    // 3. Augment with followed channel uploads if in Recommended category
    if (category == 'Recommended') {
      try {
        final followed = _storage.getFollowedChannels();
        for (final channel in followed.take(3)) {
          final uploads = await _ytPool.yt.channels.getUploads(channel.id).take(2).toList();
          for (final u in uploads) {
            candidatePool.add(TubeVideoItem(
              id: u.id.value,
              title: u.title,
              channelTitle: u.author,
              channelId: u.channelId.value,
              thumbnailUrl: u.thumbnails.highResUrl.isNotEmpty
                  ? u.thumbnails.highResUrl
                  : 'https://i.ytimg.com/vi/${u.id.value}/hqdefault.jpg',
              durationSeconds: u.duration?.inSeconds ?? 0,
              uploadDate: u.uploadDate,
            ));
          }
        }
      } catch (_) {}
    }

    // Deduplicate by videoId
    final seen = <String>{};
    return candidatePool.where((v) => seen.add(v.id)).toList();
  }

  /// Fetches and personalizes public feed videos for a selected Home category.
  /// Respects cold launch refresh policy (ALWAYS fresh on cold open).
  Future<List<TubeVideoItem>> getCategoryFeed(String category, {bool forceRefresh = false}) async {
    final isStaleOrCold = _refreshController.shouldRefreshHome();

    if (!forceRefresh && !isStaleOrCold) {
      final cached = _cache.get('category_$category');
      if (cached != null && cached.isNotEmpty) {
        return cached;
      }
    } else {
      _cache.pruneExpired();
      _categoryContinuationTokens.remove(category);
      _candidateCache.remove(category);
    }

    final stopwatch = Stopwatch()..start();
    final candidates = await generateFreshCandidates(category);
    _candidateCache[category] = List.from(candidates);

    // Apply 100% on-device personalized ranking with freshness priority
    final ranked = _recEngine.rankHomeFeed(candidates);
    _cache.set('category_$category', ranked);

    stopwatch.stop();
    _refreshController.recordHomeRefresh(
      candidateCount: candidates.length,
      suppressedCount: candidates.length - ranked.length,
      freshCandidateCount: ranked.where((v) => v.uploadDate != null && DateTime.now().difference(v.uploadDate!).inHours <= 48).length,
      generationDuration: stopwatch.elapsed,
    );

    return ranked;
  }

  /// Paginates and fetches next batch of videos for infinite scroll.
  Future<List<TubeVideoItem>> getCategoryFeedNextPage(String category) async {
    final token = _categoryContinuationTokens[category];
    List<TubeVideoItem> newItems = [];
    String? nextToken;

    if (token != null && token.isNotEmpty) {
      try {
        final res = await _innertube.searchVideos('', continuation: token);
        newItems = res.items;
        nextToken = res.continuationToken;
      } catch (e) {
        debugPrint('[TubeHomeFeedService] Continuation fetch error: $e');
      }
    }

    // Fallback 1: Contextual query extension via Innertube
    if (newItems.isEmpty) {
      final baseQuery = categoryQueries[category] ?? 'trending today';
      final existingCount = _candidateCache[category]?.length ?? 0;
      final pageIndex = (existingCount ~/ 15) + 1;
      final extendedQuery = '$baseQuery page $pageIndex';
      try {
        final res = await _innertube.searchVideos(extendedQuery);
        newItems = res.items;
        nextToken = res.continuationToken;
      } catch (_) {}
    }

    // Fallback 2: YoutubeExplode search to guarantee infinite scroll never stops
    if (newItems.isEmpty) {
      try {
        final baseQuery = categoryQueries[category] ?? 'trending today';
        final existingCount = _candidateCache[category]?.length ?? 0;
        final pageIndex = (existingCount ~/ 15) + 1;
        final searchList = await _ytPool.yt.search.search('$baseQuery latest $pageIndex');
        for (final item in searchList) {
          if (item is SearchVideo) {
            newItems.add(TubeVideoItem(
              id: item.id.value,
              title: item.title,
              channelTitle: item.author,
              channelId: item.channelId.value,
              thumbnailUrl: item.thumbnails.highResUrl.isNotEmpty
                  ? item.thumbnails.highResUrl
                  : 'https://i.ytimg.com/vi/${item.id.value}/hqdefault.jpg',
              durationSeconds: item.duration?.inSeconds ?? 0,
              uploadDate: item.uploadDate,
              description: item.description,
            ));
          }
        }
      } catch (e) {
        debugPrint('[TubeHomeFeedService] Fallback 2 pagination error: $e');
      }
    }

    if (newItems.isNotEmpty) {
      _categoryContinuationTokens[category] = nextToken;

      // Deduplicate with existing candidates
      final existingIds = (_candidateCache[category] ?? []).map((v) => v.id).toSet();
      final fresh = newItems.where((v) => !existingIds.contains(v.id)).toList();

      _candidateCache.putIfAbsent(category, () => []).addAll(fresh);

      // Rank newly acquired batch locally
      final rankedFresh = _recEngine.rankHomeFeed(fresh);
      final currentRanked = _cache.get('category_$category') ?? [];
      _cache.set('category_$category', [...currentRanked, ...rankedFresh]);
      return rankedFresh;
    }

    return [];
  }

  /// Fetches and ranks related "Up Next" videos for an active video item.
  Future<List<TubeVideoItem>> getRelatedVideos(TubeVideoItem currentVideo) async {
    final cacheKey = 'related_${currentVideo.id}';
    final cached = _cache.get(cacheKey);
    if (cached != null) return cached;

    List<TubeVideoItem> candidates = [];
    try {
      final videoObj = await _ytPool.yt.videos.get(VideoId(currentVideo.id));
      final related = await _ytPool.yt.videos.getRelatedVideos(videoObj);
      if (related != null) {
        for (final v in related.take(20)) {
          candidates.add(TubeVideoItem(
            id: v.id.value,
            title: v.title,
            channelTitle: v.author,
            channelId: v.channelId.value,
            thumbnailUrl: v.thumbnails.highResUrl.isNotEmpty
                ? v.thumbnails.highResUrl
                : 'https://i.ytimg.com/vi/${v.id.value}/hqdefault.jpg',
            durationSeconds: v.duration?.inSeconds ?? 0,
          ));
        }
      }
    } catch (e) {
      debugPrint('[TubeHomeFeedService] Related videos error: $e');
    }

    if (candidates.isEmpty) {
      try {
        final query = '${currentVideo.channelTitle} ${currentVideo.title.split(" ").take(3).join(" ")}';
        final res = await _innertube.searchVideos(query);
        candidates = res.items;
      } catch (_) {}
    }

    final ranked = _recEngine.rankUpNext(currentVideo: currentVideo, candidates: candidates);
    _cache.set(cacheKey, ranked);
    return ranked;
  }
}
