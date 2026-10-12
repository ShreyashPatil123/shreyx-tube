import 'package:flutter/foundation.dart';
import '../models/tube_models.dart';
import 'tube_cache_service.dart';
import 'tube_feed_refresh_controller.dart';
import 'tube_innertube_client.dart';
import 'tube_storage_service.dart';

typedef TubeFeedPage = ({List<TubeVideoItem> items, String? continuationToken});

/// Uses YouTube's public ordering. An accountless session may have no Home feed;
/// in that case, use public Up Next for the last watched video, then discovery.
class TubeHomeFeedService {
  static final TubeHomeFeedService _instance = TubeHomeFeedService._internal();
  factory TubeHomeFeedService() => _instance;
  TubeHomeFeedService._internal() : _innertube = TubeInnertubeClient();
  TubeHomeFeedService.withClient(this._innertube);

  final TubeInnertubeClient _innertube;
  final TubeFeedRefreshController _refreshController =
      TubeFeedRefreshController();
  final TubeStorageService _storage = TubeStorageService();
  final TubeMemoryCache<List<TubeVideoItem>> _cache =
      TubeMemoryCache(defaultTtl: const Duration(minutes: 10));
  final Map<String, String?> _tokens = {};
  final Map<String, String> _sources = {};
  final Map<String, String> _seeds = {};
  final Map<String, Set<String>> _seen = {};
  final Map<String, int> _generations = {};
  final Map<String, Future<List<TubeVideoItem>>> _pendingPages = {};

  static const Map<String, String> categoryQueries = {
    'Recommended': 'popular videos India',
    'Trending': 'trending today India',
    'Music': 'official music video',
    'Gaming': 'gaming gameplay',
    'Technology': 'technology gadgets review',
    'Education': 'science education',
    'News': 'news today India',
    'Sports': 'sports highlights',
    'Live': 'live news',
  };

  bool hasMore(String category) => _tokens[category]?.isNotEmpty == true;

  void invalidateRecommendedFeed() => _cache.remove('category_Recommended');

  List<TubeVideoItem> _visible(List<TubeVideoItem> items, String category) =>
      items
          .where((v) =>
              !v.isShort &&
              !v.isPrivate &&
              (category != 'Live' || v.isLive) &&
              !_storage.isNotInterested(v.id, v.channelTitle))
          .toList();

  Future<TubeFeedPage> _initialPage(String category) async {
    if (category == 'Recommended') {
      try {
        final page = await _innertube.homeFeed();
        if (page.items.isNotEmpty) {
          _sources[category] = 'home';
          return page;
        }
      } catch (e) {
        debugPrint('[TubeHomeFeedService] Public home unavailable: $e');
      }
      final history = _storage.getWatchHistory();
      if (history.isNotEmpty) {
        try {
          final seed = history.first.video.id;
          final page = await _innertube.relatedFeed(seed);
          if (page.items.isNotEmpty) {
            _sources[category] = 'next';
            _seeds[category] = seed;
            return page;
          }
        } catch (e) {
          debugPrint(
              '[TubeHomeFeedService] Public recommendations unavailable: $e');
        }
      }
    }
    _sources[category] = 'search';
    return _innertube.searchVideos(categoryQueries[category] ?? category);
  }

  Future<List<TubeVideoItem>> generateFreshCandidates(String category) async =>
      _visible((await _initialPage(category)).items, category);

  Future<List<TubeVideoItem>> getCategoryFeed(String category,
      {bool forceRefresh = false}) async {
    if (!forceRefresh && !_refreshController.shouldRefreshHome()) {
      final cached = _cache.get('category_$category');
      if (cached != null && cached.isNotEmpty) return cached;
    }
    final generation = (_generations[category] ?? 0) + 1;
    _generations[category] = generation;
    _tokens.remove(category);
    final timer = Stopwatch()..start();
    final page = await _initialPage(category);
    final seen = <String>{};
    final visible =
        _visible(page.items, category).where((v) => seen.add(v.id)).toList();
    if (_generations[category] != generation) return visible;
    if (visible.isEmpty) throw StateError('No public videos were returned');
    _tokens[category] = page.continuationToken;
    _seen[category] = seen;
    _cache.set('category_$category', visible);
    _refreshController.recordHomeRefresh(
      candidateCount: page.items.length,
      suppressedCount: page.items.length - visible.length,
      freshCandidateCount: visible
          .where((v) =>
              v.effectiveUploadDate != null &&
              DateTime.now().difference(v.effectiveUploadDate!).inHours <= 48)
          .length,
      generationDuration: timer.elapsed,
    );
    return visible;
  }

  Future<List<TubeVideoItem>> getCategoryFeedNextPage(String category) async {
    final existing = _pendingPages[category];
    if (existing != null) return existing;
    final task = _nextPage(category);
    _pendingPages[category] = task;
    try {
      return await task;
    } finally {
      if (identical(_pendingPages[category], task)) {
        _pendingPages.remove(category);
      }
    }
  }

  Future<List<TubeVideoItem>> _nextPage(String category) async {
    final generation = _generations[category];
    final token = _tokens[category];
    if (token == null || token.isEmpty) return [];
    final TubeFeedPage page;
    switch (_sources[category]) {
      case 'home':
        page = await _innertube.homeFeed(continuation: token);
      case 'next':
        page = await _innertube.relatedFeed(_seeds[category] ?? '',
            continuation: token);
      default:
        page = await _innertube.searchVideos('', continuation: token);
    }
    if (_generations[category] != generation) return [];
    final seen = _seen.putIfAbsent(category, () => <String>{});
    final fresh =
        _visible(page.items, category).where((v) => seen.add(v.id)).toList();
    _tokens[category] =
        page.continuationToken == token ? null : page.continuationToken;
    _cache.set(
        'category_$category', [...?_cache.get('category_$category'), ...fresh]);
    return fresh;
  }

  Future<List<TubeVideoItem>> getRelatedVideos(
      TubeVideoItem currentVideo) async {
    final key = 'related_${currentVideo.id}';
    final cached = _cache.get(key);
    if (cached != null) return cached;
    final page = await _innertube.relatedFeed(currentVideo.id);
    final items = _visible(page.items, 'Recommended')
        .where((v) => v.id != currentVideo.id)
        .toList();
    if (items.isNotEmpty) _cache.set(key, items);
    return items;
  }
}
