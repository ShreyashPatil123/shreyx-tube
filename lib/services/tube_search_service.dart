import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/tube_models.dart';
import 'tube_cache_service.dart';
import 'tube_user_profile_service.dart';
import 'tube_youtube_explode_pool.dart';

enum TubeInputType {
  textQuery,
  videoUrl,
  shortsUrl,
  playlistUrl,
  channelUrl,
}

class TubeParsedInput {
  final TubeInputType type;
  final String rawInput;
  final String? extractedId;

  const TubeParsedInput({
    required this.type,
    required this.rawInput,
    this.extractedId,
  });
}

class TubeSearchResults {
  final List<TubeVideoItem> videos;
  final List<TubeChannelInfo> channels;
  final List<TubeLocalPlaylist> playlists;
  final String? continuationToken;

  const TubeSearchResults({
    this.videos = const [],
    this.channels = const [],
    this.playlists = const [],
    this.continuationToken,
  });

  TubeSearchResults copyWith({
    List<TubeVideoItem>? videos,
    List<TubeChannelInfo>? channels,
    List<TubeLocalPlaylist>? playlists,
    String? continuationToken,
  }) {
    return TubeSearchResults(
      videos: videos ?? this.videos,
      channels: channels ?? this.channels,
      playlists: playlists ?? this.playlists,
      continuationToken: continuationToken ?? this.continuationToken,
    );
  }
}

class TubeSearchFilters {
  final String uploadDate; // 'any', 'hour', 'today', 'week', 'month', 'year'
  final String duration; // 'any', 'short', 'medium', 'long'
  final String contentType; // 'all', 'videos', 'shorts', 'channels', 'playlists'
  final String sortBy; // 'relevance', 'upload_date', 'view_count', 'rating'

  const TubeSearchFilters({
    this.uploadDate = 'any',
    this.duration = 'any',
    this.contentType = 'all',
    this.sortBy = 'relevance',
  });

  String? toInnertubeParams() {
    if (sortBy == 'upload_date') return 'CAISAhAB';
    if (sortBy == 'view_count') return 'CAMSAhAB';
    if (sortBy == 'rating') return 'CAESAhAB';

    if (uploadDate == 'hour') return 'EgIIAQ%3D%3D';
    if (uploadDate == 'today') return 'EgIIAg%3D%3D';
    if (uploadDate == 'week') return 'EgIIAw%3D%3D';
    if (uploadDate == 'month') return 'EgIIBA%3D%3D';
    if (uploadDate == 'year') return 'EgIIBQ%3D%3D';

    if (duration == 'short') return 'EgQQARgB';
    if (duration == 'medium') return 'EgQQARgD';
    if (duration == 'long') return 'EgQQARgC';

    if (contentType == 'channels') return 'EgIQAg%3D%3D';
    if (contentType == 'playlists') return 'EgIQAw%3D%3D';

    return null;
  }
}

/// Universal Search Service:
/// Intelligently parses input into Text Queries, Video URLs, Shorts URLs, Playlist URLs, and Channel URLs.
/// Retrieves public search results without resolving stream URLs.
/// Supports infinite-scroll continuation pagination, multi-parameter filters, and caching.
class TubeSearchService {
  static final TubeSearchService _instance = TubeSearchService._internal();
  factory TubeSearchService() => _instance;
  TubeSearchService._internal();

  final TubeYoutubeExplodePool _ytPool = TubeYoutubeExplodePool.instance;
  final http.Client _httpClient = http.Client();
  final TubeMemoryCache<TubeSearchResults> _searchCache =
      TubeMemoryCache(defaultTtl: const Duration(minutes: 5));

  static const String _innertubeBaseUrl = 'https://www.youtube.com/youtubei/v1';
  static const Map<String, String> _headers = {
    'Content-Type': 'application/json',
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
  };

  static const Map<String, dynamic> _clientContext = {
    'client': {
      'clientName': 'WEB',
      'clientVersion': '2.20240101.00.00',
      'hl': 'en',
      'gl': 'US',
    }
  };

  /// Parses arbitrary user input to determine if it is a URL or search text.
  TubeParsedInput parseInput(String input) {
    final trimmed = input.trim();

    // 1. Direct 11-char Video ID
    if (trimmed.length == 11 && RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(trimmed)) {
      return TubeParsedInput(type: TubeInputType.videoUrl, rawInput: trimmed, extractedId: trimmed);
    }

    // 2. Shorts URL
    final shortsMatch = RegExp(r'youtube\.com/shorts/([a-zA-Z0-9_-]{11})').firstMatch(trimmed);
    if (shortsMatch != null) {
      return TubeParsedInput(type: TubeInputType.shortsUrl, rawInput: trimmed, extractedId: shortsMatch.group(1));
    }

    // 3. Video Watch URL or youtu.be
    final vMatch = RegExp(r'(?:youtube\.com/watch\?v=|youtu\.be/)([a-zA-Z0-9_-]{11})').firstMatch(trimmed);
    if (vMatch != null) {
      return TubeParsedInput(type: TubeInputType.videoUrl, rawInput: trimmed, extractedId: vMatch.group(1));
    }

    // 4. Playlist URL
    final plMatch = RegExp(r'[?&]list=([a-zA-Z0-9_-]+)').firstMatch(trimmed);
    if (plMatch != null) {
      return TubeParsedInput(type: TubeInputType.playlistUrl, rawInput: trimmed, extractedId: plMatch.group(1));
    }

    // 5. Channel URL (@handle or /channel/)
    final chMatch = RegExp(r'youtube\.com/(?:@|channel/|c/)([a-zA-Z0-9_.-]+)').firstMatch(trimmed);
    if (chMatch != null) {
      return TubeParsedInput(type: TubeInputType.channelUrl, rawInput: trimmed, extractedId: chMatch.group(1));
    }

    // Default: Normal text search
    return TubeParsedInput(type: TubeInputType.textQuery, rawInput: trimmed);
  }

  /// Fetches real-time search suggestions as the user types.
  Future<List<String>> getSuggestions(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return [];

    try {
      final url = Uri.parse(
          'https://suggestqueries-clients6.youtube.com/complete/search?client=firefox&ds=yt&q=${Uri.encodeComponent(trimmed)}');
      final res = await _httpClient.get(url).timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data is List && data.length > 1 && data[1] is List) {
          return (data[1] as List).map((s) => s.toString()).take(10).toList();
        }
      }
    } catch (e) {
      debugPrint('[TubeSearchService] Suggestions network error: $e');
    }

    // Fallback: YoutubeExplode suggestions
    try {
      final suggestions = await _ytPool.yt.search.getQuerySuggestions(trimmed);
      return suggestions.take(10).toList();
    } catch (_) {
      return [];
    }
  }

  /// Performs initial search for public content across videos, channels, and playlists.
  Future<TubeSearchResults> search(
    String query, {
    String filter = 'All',
    TubeSearchFilters? filters,
    bool forceRefresh = false,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const TubeSearchResults();

    final cacheKey = '${trimmed}_${filter}_${filters?.sortBy}_${filters?.uploadDate}_${filters?.duration}';
    if (!forceRefresh) {
      final cached = _searchCache.get(cacheKey);
      if (cached != null) return cached;
    }

    TubeUserProfileService().recordSearchQuery(trimmed);

    final searchQuery = filter == 'Shorts' ? '$trimmed #shorts' : trimmed;
    final params = filters?.toInnertubeParams();
    debugPrint('[TubeSearchService] Searching: "$searchQuery" (filter: $filter, params: $params)');

    try {
      final url = Uri.parse('$_innertubeBaseUrl/search?prettyPrint=false');
      final bodyMap = <String, dynamic>{
        'context': _clientContext,
        'query': searchQuery,
      };
      if (params != null && params.isNotEmpty) {
        bodyMap['params'] = params;
      }

      final res = await _httpClient.post(
        url,
        headers: _headers,
        body: jsonEncode(bodyMap),
      ).timeout(const Duration(seconds: 8));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final List<TubeVideoItem> videos = [];
        final List<TubeChannelInfo> channels = [];
        final List<TubeLocalPlaylist> playlists = [];
        String? nextContinuation;

        final sectionList = data['contents']?['twoColumnSearchResultsRenderer']?['primaryContents']?['sectionListRenderer']?['contents'] as List?;
        if (sectionList != null) {
          for (final section in sectionList) {
            if (section is Map<String, dynamic>) {
              final contToken = section['continuationItemRenderer']?['continuationEndpoint']?['continuationCommand']?['token'] as String?;
              if (contToken != null && contToken.isNotEmpty) {
                nextContinuation = contToken;
              }

              final itemSection = section['itemSectionRenderer']?['contents'] as List?;
              if (itemSection != null) {
                _parseItems(itemSection, filter, videos, channels, playlists, (token) {
                  nextContinuation = token;
                });
              }
            }
          }

          final results = TubeSearchResults(
            videos: videos,
            channels: channels,
            playlists: playlists,
            continuationToken: nextContinuation,
          );
          _searchCache.set(cacheKey, results);
          return results;
        }
      }
    } catch (e) {
      debugPrint('[TubeSearchService] Search error: $e');
    }

    return const TubeSearchResults();
  }

  /// Fetches next page of search results using a continuation token.
  Future<TubeSearchResults> searchNextPage(
    String continuationToken, {
    String filter = 'All',
  }) async {
    if (continuationToken.isEmpty) return const TubeSearchResults();
    debugPrint('[TubeSearchService] Fetching continuation page...');

    try {
      final url = Uri.parse('$_innertubeBaseUrl/search?prettyPrint=false');
      final res = await _httpClient.post(
        url,
        headers: _headers,
        body: jsonEncode({
          'context': _clientContext,
          'continuation': continuationToken,
        }),
      ).timeout(const Duration(seconds: 8));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final List<TubeVideoItem> videos = [];
        final List<TubeChannelInfo> channels = [];
        final List<TubeLocalPlaylist> playlists = [];
        String? nextContinuation;

        final commands = data['onResponseReceivedCommands'] as List?;
        if (commands != null) {
          for (final cmd in commands) {
            final appendAction = cmd['appendContinuationItemsAction'] as Map<String, dynamic>?;
            if (appendAction != null) {
              final items = appendAction['continuationItems'] as List?;
              if (items != null) {
                _parseItems(items, filter, videos, channels, playlists, (token) {
                  nextContinuation = token;
                });
              }
            }
          }
        }

        return TubeSearchResults(
          videos: videos,
          channels: channels,
          playlists: playlists,
          continuationToken: nextContinuation,
        );
      }
    } catch (e) {
      debugPrint('[TubeSearchService] Continuation error: $e');
    }

    return const TubeSearchResults();
  }

  void _parseItems(
    List items,
    String filter,
    List<TubeVideoItem> videos,
    List<TubeChannelInfo> channels,
    List<TubeLocalPlaylist> playlists,
    void Function(String token) onContinuationFound,
  ) {
    for (final item in items) {
      if (item is! Map<String, dynamic>) continue;

      // Continuation token item
      if (item.containsKey('continuationItemRenderer')) {
        final token = item['continuationItemRenderer']?['continuationEndpoint']?['continuationCommand']?['token'] as String?;
        if (token != null && token.isNotEmpty) {
          onContinuationFound(token);
        }
      }

      // Video renderer
      if (item.containsKey('videoRenderer')) {
        final vr = item['videoRenderer'] as Map<String, dynamic>;
        final videoId = vr['videoId'] as String?;
        if (videoId == null || videoId.isEmpty) continue;

        // Title
        String title = '';
        final titleRuns = vr['title']?['runs'] as List?;
        if (titleRuns != null && titleRuns.isNotEmpty) {
          title = titleRuns.map((r) => r['text'] ?? '').join();
        } else {
          title = vr['title']?['simpleText']?.toString() ?? '';
        }

        // Channel
        String channelTitle = '';
        String channelId = '';
        final ownerRuns = (vr['ownerText']?['runs'] ?? vr['shortBylineText']?['runs']) as List?;
        if (ownerRuns != null && ownerRuns.isNotEmpty) {
          channelTitle = ownerRuns.map((r) => r['text'] ?? '').join();
          final endpoint = ownerRuns[0]?['navigationEndpoint']?['browseEndpoint'];
          channelId = endpoint?['browseId']?.toString() ?? '';
        }

        // Thumbnail
        String thumb = 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg';
        final thumbList = vr['thumbnail']?['thumbnails'] as List?;
        if (thumbList != null && thumbList.isNotEmpty) {
          thumb = thumbList.last?['url']?.toString() ?? thumb;
        }

        // Duration
        int durationSeconds = 0;
        final lenText = vr['lengthText']?['simpleText'] as String?;
        if (lenText != null) {
          final parts = lenText.split(':').map((p) => int.tryParse(p) ?? 0).toList();
          if (parts.length == 2) {
            durationSeconds = parts[0] * 60 + parts[1];
          } else if (parts.length == 3) {
            durationSeconds = parts[0] * 3600 + parts[1] * 60 + parts[2];
          }
        }

        // Channel Avatar
        String channelAvatarUrl = '';
        final avatarThumbs = vr['channelThumbnailSupportedRenderers']
            ?['channelThumbnailWithLinkRenderer']?['thumbnail']?['thumbnails'] as List?;
        if (avatarThumbs != null && avatarThumbs.isNotEmpty) {
          channelAvatarUrl = avatarThumbs.last?['url']?.toString() ?? '';
        }

        // Views
        String? viewCountText;
        final vText = (vr['shortViewCountText']?['simpleText'] ?? vr['viewCountText']?['simpleText']) as String?;
        if (vText != null && vText.isNotEmpty) {
          viewCountText = vText;
        } else {
          final vRuns = (vr['shortViewCountText']?['runs'] ?? vr['viewCountText']?['runs']) as List?;
          if (vRuns != null && vRuns.isNotEmpty) {
            viewCountText = vRuns.map((r) => r['text'] ?? '').join();
          }
        }
        final views = TubeVideoItem.parseViewCount(viewCountText);

        // Upload Time
        String? publishedTimeText;
        final pText = vr['publishedTimeText']?['simpleText'] as String?;
        if (pText != null && pText.isNotEmpty) {
          publishedTimeText = pText;
        } else {
          final pRuns = vr['publishedTimeText']?['runs'] as List?;
          if (pRuns != null && pRuns.isNotEmpty) {
            publishedTimeText = pRuns.map((r) => r['text'] ?? '').join();
          }
        }
        final uploadDate = TubeVideoItem.parseRelativeTime(publishedTimeText);

        final isShort = (durationSeconds > 0 && durationSeconds <= 60) || filter == 'Shorts';
        if (filter == 'Videos' && durationSeconds > 0 && durationSeconds <= 60) continue;

        videos.add(TubeVideoItem(
          id: videoId,
          title: title,
          channelTitle: channelTitle,
          channelId: channelId,
          channelAvatarUrl: channelAvatarUrl,
          thumbnailUrl: thumb,
          durationSeconds: durationSeconds,
          viewCount: views,
          viewCountText: viewCountText,
          uploadDate: uploadDate,
          publishedTimeText: publishedTimeText,
          isShort: isShort,
        ));
      }

      // Channel renderer
      if (item.containsKey('channelRenderer') && (filter == 'All' || filter == 'Channels')) {
        final cr = item['channelRenderer'] as Map<String, dynamic>;
        final channelId = cr['channelId']?.toString() ?? '';
        final title = cr['title']?['simpleText']?.toString() ?? '';
        String avatar = (cr['thumbnail']?['thumbnails'] as List?)?.last?['url']?.toString() ?? '';
        if (avatar.startsWith('//')) {
          avatar = 'https:$avatar';
        }
        final subs = cr['subscriberCountText']?['simpleText']?.toString() ?? '';

        if (channelId.isNotEmpty && title.isNotEmpty) {
          channels.add(TubeChannelInfo(
            id: channelId,
            title: title,
            avatarUrl: avatar,
            subscriberCountText: subs,
          ));
        }
      }

      // Playlist renderer
      if (item.containsKey('playlistRenderer') && (filter == 'All' || filter == 'Playlists')) {
        final pr = item['playlistRenderer'] as Map<String, dynamic>;
        final playlistId = pr['playlistId']?.toString() ?? '';
        final title = pr['title']?['simpleText']?.toString() ??
            (pr['title']?['runs'] as List?)?.map((r) => r['text'] ?? '').join() ?? '';
        if (playlistId.isNotEmpty && title.isNotEmpty) {
          playlists.add(TubeLocalPlaylist(
            id: playlistId,
            title: title,
            createdAt: DateTime.now(),
            videos: const [],
          ));
        }
      }
    }
  }

  void dispose() {
    _httpClient.close();
  }
}
