import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/tube_models.dart';

class TubeInnertubeClient {
  static final TubeInnertubeClient instance = TubeInnertubeClient._internal();
  factory TubeInnertubeClient() => instance;
  TubeInnertubeClient._internal();

  final http.Client _httpClient = http.Client();

  static const String baseUrl = 'https://www.youtube.com/youtubei/v1';
  static const Map<String, String> headers = {
    'Content-Type': 'application/json',
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
  };

  static const Map<String, dynamic> clientContext = {
    'client': {
      'clientName': 'WEB',
      'clientVersion': '2.20240101.00.00',
      'hl': 'en',
      'gl': 'US',
    }
  };

  Future<({List<TubeVideoItem> items, String? continuationToken})> searchVideos(
    String query, {
    String? continuation,
  }) async {
    try {
      final response = await search(query, continuation: continuation);
      if (response.statusCode != 200) return (items: <TubeVideoItem>[], continuationToken: null);
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final List<TubeVideoItem> items = [];
      String? nextToken;

      if (continuation != null) {
        final commands = data['onResponseReceivedCommands'] as List?;
        if (commands != null) {
          for (final cmd in commands) {
            final appendAction = cmd['appendContinuationItemsAction'] as Map<String, dynamic>?;
            if (appendAction != null) {
              final contItems = appendAction['continuationItems'] as List?;
              if (contItems != null) {
                for (final ci in contItems) {
                  if (ci is Map<String, dynamic>) {
                    if (ci.containsKey('itemSectionRenderer')) {
                      final contents = ci['itemSectionRenderer']['contents'] as List?;
                      if (contents != null) {
                        for (final c in contents) {
                          if (c is Map<String, dynamic> && c.containsKey('videoRenderer')) {
                            final parsed = parseVideoRenderer(c['videoRenderer'] as Map<String, dynamic>);
                            if (parsed != null) items.add(parsed);
                          }
                        }
                      }
                    } else if (ci.containsKey('continuationItemRenderer')) {
                      nextToken = ci['continuationItemRenderer']?['continuationEndpoint']?['continuationCommand']?['token'] as String?;
                    }
                  }
                }
              }
            }
          }
        }
      } else {
        final sectionList = data['contents']?['twoColumnSearchResultsRenderer']?['primaryContents']?['sectionListRenderer']?['contents'] as List?;
        if (sectionList != null) {
          for (final section in sectionList) {
            if (section is Map<String, dynamic>) {
              final contToken = section['continuationItemRenderer']?['continuationEndpoint']?['continuationCommand']?['token'] as String?;
              if (contToken != null && contToken.isNotEmpty) {
                nextToken = contToken;
              }

              final itemSection = section['itemSectionRenderer']?['contents'] as List?;
              if (itemSection == null) continue;

              for (final item in itemSection) {
                if (item is Map<String, dynamic>) {
                  if (item.containsKey('continuationItemRenderer')) {
                    final tok = item['continuationItemRenderer']?['continuationEndpoint']?['continuationCommand']?['token'] as String?;
                    if (tok != null && tok.isNotEmpty) nextToken = tok;
                  } else if (item.containsKey('videoRenderer')) {
                    final parsed = parseVideoRenderer(item['videoRenderer'] as Map<String, dynamic>);
                    if (parsed != null) items.add(parsed);
                  } else if (item.containsKey('gridShelfViewModel')) {
                    final gsvm = item['gridShelfViewModel'] as Map<String, dynamic>;
                    final shelfContents = gsvm['contents'] as List?;
                    if (shelfContents != null) {
                      for (final c in shelfContents) {
                        if (c is Map<String, dynamic> && c.containsKey('shortsLockupViewModel')) {
                          final parsedShort = parseShortsLockupViewModel(c['shortsLockupViewModel'] as Map<String, dynamic>);
                          if (parsedShort != null) items.add(parsedShort);
                        }
                      }
                    }
                  } else if (item.containsKey('reelShelfRenderer')) {
                    final shelf = item['reelShelfRenderer'] as Map<String, dynamic>;
                    final reelItems = shelf['items'] as List?;
                    if (reelItems != null) {
                      for (final ri in reelItems) {
                        if (ri is Map<String, dynamic> && ri.containsKey('reelItemRenderer')) {
                          final parsedShort = parseReelItemRenderer(ri['reelItemRenderer'] as Map<String, dynamic>);
                          if (parsedShort != null) items.add(parsedShort);
                        }
                      }
                    }
                  } else if (item.containsKey('reelItemRenderer')) {
                    final parsedShort = parseReelItemRenderer(item['reelItemRenderer'] as Map<String, dynamic>);
                    if (parsedShort != null) items.add(parsedShort);
                  }
                }
              }
            }
          }
        }
      }
      return (items: items, continuationToken: nextToken);
    } catch (_) {
      return (items: <TubeVideoItem>[], continuationToken: null);
    }
  }

  Future<http.Response> search(String query, {String? continuation}) async {
    final url = Uri.parse('$baseUrl/search?prettyPrint=false');
    final body = {
      'context': clientContext,
      if (continuation == null) 'query': query else 'continuation': continuation,
    };
    return _httpClient.post(url, headers: headers, body: jsonEncode(body)).timeout(const Duration(seconds: 8));
  }

  Future<http.Response> next(String videoId) async {
    final url = Uri.parse('$baseUrl/next?prettyPrint=false');
    final body = {
      'context': clientContext,
      'videoId': videoId,
    };
    return _httpClient.post(url, headers: headers, body: jsonEncode(body)).timeout(const Duration(seconds: 8));
  }

  Future<http.Response> browse(String browseId, {Map<String, dynamic>? params}) async {
    final url = Uri.parse('$baseUrl/browse?prettyPrint=false');
    final body = {
      'context': clientContext,
      'browseId': browseId,
      if (params != null) ...params,
    };
    return _httpClient.post(url, headers: headers, body: jsonEncode(body)).timeout(const Duration(seconds: 8));
  }

  TubeVideoItem? parseVideoRenderer(Map<String, dynamic> vr) {
    final videoId = vr['videoId'] as String?;
    if (videoId == null || videoId.isEmpty) return null;

    // Fix title truncation bug by joining all runs
    String title = '';
    final titleRuns = vr['title']?['runs'] as List?;
    if (titleRuns != null && titleRuns.isNotEmpty) {
      title = titleRuns.map((r) => r['text'] ?? '').join();
    } else {
      title = vr['title']?['simpleText']?.toString() ?? 'Video';
    }

    String channelTitle = '';
    String channelId = '';
    final ownerRuns = (vr['ownerText']?['runs'] ?? vr['shortBylineText']?['runs'] ?? vr['longBylineText']?['runs']) as List?;
    if (ownerRuns != null && ownerRuns.isNotEmpty) {
      channelTitle = ownerRuns.map((r) => r['text'] ?? '').join();
      final endpoint = ownerRuns[0]?['navigationEndpoint']?['browseEndpoint'];
      channelId = endpoint?['browseId']?.toString() ?? '';
    }

    String thumbnailUrl = 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg';
    final thumbList = vr['thumbnail']?['thumbnails'] as List?;
    if (thumbList != null && thumbList.isNotEmpty) {
      thumbnailUrl = thumbList.last?['url']?.toString() ?? thumbnailUrl;
    }

    String channelAvatarUrl = '';
    final avatarThumbs = vr['channelThumbnailSupportedRenderers']
        ?['channelThumbnailWithLinkRenderer']?['thumbnail']?['thumbnails'] as List?;
    if (avatarThumbs != null && avatarThumbs.isNotEmpty) {
      channelAvatarUrl = avatarThumbs.last?['url']?.toString() ?? '';
    }

    int durationSeconds = 0;
    final lengthText = vr['lengthText']?['simpleText'] as String?;
    if (lengthText != null) {
      final parts = lengthText.split(':').map((p) => int.tryParse(p) ?? 0).toList();
      if (parts.length == 2) {
        durationSeconds = parts[0] * 60 + parts[1];
      } else if (parts.length == 3) {
        durationSeconds = parts[0] * 3600 + parts[1] * 60 + parts[2];
      }
    }

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
    final viewCount = TubeVideoItem.parseViewCount(viewCountText);

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

    String? description;
    final descRuns = (vr['detailedMetadataSnippets']?[0]?['snippetText']?['runs'] ?? vr['descriptionSnippet']?['runs']) as List?;
    if (descRuns != null) {
      description = descRuns.map((r) => r['text'] ?? '').join();
    }

    final isShort = durationSeconds > 0 && durationSeconds <= 60;
    final isLive = vr['badges']?.toString().toLowerCase().contains('live') ?? false;

    return TubeVideoItem(
      id: videoId,
      title: title,
      channelTitle: channelTitle,
      channelId: channelId,
      channelAvatarUrl: channelAvatarUrl,
      thumbnailUrl: thumbnailUrl,
      durationSeconds: durationSeconds,
      viewCount: viewCount,
      viewCountText: viewCountText,
      uploadDate: uploadDate,
      publishedTimeText: publishedTimeText,
      isLive: isLive,
      isShort: isShort,
      description: description ?? '',
    );
  }

  TubeVideoItem? parseShortsLockupViewModel(Map<String, dynamic> slvm) {
    String? videoId = slvm['onTap']?['innertubeCommand']?['reelWatchEndpoint']?['videoId'] as String?;
    if (videoId == null || videoId.isEmpty) {
      final entityId = slvm['entityId'] as String?;
      if (entityId != null && entityId.startsWith('shorts-shelf-item-')) {
        videoId = entityId.replaceFirst('shorts-shelf-item-', '');
      }
    }
    if (videoId == null || videoId.isEmpty) return null;

    String title = slvm['overlayMetadata']?['primaryText']?['content']?.toString() ?? '';
    if (title.isEmpty) {
      title = slvm['accessibilityText']?.toString() ?? 'Short';
    }

    final viewCountText = slvm['overlayMetadata']?['secondaryText']?['content']?.toString();
    final viewCount = TubeVideoItem.parseViewCount(viewCountText);

    String thumbnailUrl = 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg';
    final sources = slvm['thumbnailViewModel']?['thumbnailViewModel']?['image']?['sources'] as List?;
    if (sources != null && sources.isNotEmpty) {
      thumbnailUrl = sources.last?['url']?.toString() ?? thumbnailUrl;
    }

    return TubeVideoItem(
      id: videoId,
      title: title,
      channelTitle: '',
      channelId: '',
      thumbnailUrl: thumbnailUrl,
      durationSeconds: 30,
      viewCount: viewCount,
      viewCountText: viewCountText,
      isShort: true,
      description: title,
    );
  }

  TubeVideoItem? parseReelItemRenderer(Map<String, dynamic> rir) {
    final videoId = rir['videoId'] as String? ??
        rir['navigationEndpoint']?['reelWatchEndpoint']?['videoId'] as String?;
    if (videoId == null || videoId.isEmpty) return null;

    String title = '';
    final headline = rir['headline'];
    if (headline is Map) {
      final runs = headline['runs'] as List?;
      if (runs != null && runs.isNotEmpty) {
        title = runs.map((r) => r['text'] ?? '').join();
      } else {
        title = headline['simpleText']?.toString() ?? '';
      }
    }

    String channelTitle = '';
    final channelRuns = (rir['channelTitleText']?['runs'] ?? rir['ownerText']?['runs']) as List?;
    if (channelRuns != null && channelRuns.isNotEmpty) {
      channelTitle = channelRuns.map((r) => r['text'] ?? '').join();
    }

    String thumbnailUrl = 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg';
    final thumbList = (rir['thumbnail']?['thumbnails'] ?? rir['thumbnail']?['image']?['sources']) as List?;
    if (thumbList != null && thumbList.isNotEmpty) {
      thumbnailUrl = thumbList.last?['url']?.toString() ?? thumbnailUrl;
    }

    final viewCountText = rir['viewCountText']?['simpleText']?.toString();
    final viewCount = TubeVideoItem.parseViewCount(viewCountText);

    return TubeVideoItem(
      id: videoId,
      title: title.isNotEmpty ? title : 'Short',
      channelTitle: channelTitle,
      channelId: '',
      thumbnailUrl: thumbnailUrl,
      durationSeconds: 30,
      viewCount: viewCount,
      viewCountText: viewCountText,
      isShort: true,
    );
  }

  TubeChannelInfo? parseChannelRenderer(Map<String, dynamic> cr) {
    final channelId = cr['channelId'] as String?;
    if (channelId == null || channelId.isEmpty) return null;

    String title = '';
    final titleRuns = cr['title']?['simpleText'] ?? cr['title']?['runs'] as List?;
    if (titleRuns is List) {
      title = titleRuns.map((r) => r['text'] ?? '').join();
    } else if (titleRuns is String) {
      title = titleRuns;
    }

    String avatarUrl = '';
    final thumbList = cr['thumbnail']?['thumbnails'] as List?;
    if (thumbList != null && thumbList.isNotEmpty) {
      avatarUrl = thumbList.last?['url']?.toString() ?? '';
    }

    String subscriberCountText = cr['subscriberCountText']?['simpleText']?.toString() ?? '';

    return TubeChannelInfo(
      id: channelId,
      title: title,
      avatarUrl: avatarUrl,
      bannerUrl: '', // Channel renderer rarely has banner, usually header renderer does
      subscriberCountText: subscriberCountText,
    );
  }

  void dispose() {
    _httpClient.close();
  }
}
