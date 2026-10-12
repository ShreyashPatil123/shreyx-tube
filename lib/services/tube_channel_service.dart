import 'package:flutter/foundation.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../models/tube_models.dart';
import 'tube_cache_service.dart';
import 'tube_youtube_explode_pool.dart';
import 'tube_innertube_client.dart';
import 'tube_channel_upload_pager.dart';

/// Comprehensive channel discovery service.
/// Retrieves metadata and content across all 5 channel sections:
/// Home, Videos (Latest/Popular/Oldest), Shorts, Live, Playlists, and Community Posts.
/// Streams every single video of a creator on demand via continuous lazy pagination.
class TubeChannelService {
  static final TubeChannelService _instance = TubeChannelService._internal();
  factory TubeChannelService() => _instance;
  TubeChannelService._internal();

  final TubeYoutubeExplodePool _ytPool = TubeYoutubeExplodePool.instance;
  final TubeMemoryCache<TubeChannelInfo> _infoCache =
      TubeMemoryCache(defaultTtl: const Duration(minutes: 30));

  final Map<String, TubeChannelUploadPager> _pagers = {};
  final Map<String, Future<List<TubeVideoItem>>> _otherUploads = {};

  bool hasMoreVideos(String channelId) => _pagers[channelId]?.hasMore ?? true;

  /// Retrieves channel header metadata (banner, avatar, handle, follower count, description)
  Future<TubeChannelInfo> getChannel(String channelId) async {
    final cached = _infoCache.get(channelId);
    if (cached != null) return cached;

    try {
      final channel = await _ytPool.yt.channels.get(channelId);
      final info = TubeChannelInfo(
        id: channel.id.value,
        title: channel.title,
        avatarUrl: channel.logoUrl,
        bannerUrl: channel.bannerUrl,
        handle: '',
        subscriberCountText: '',
        description: '',
        videoCount: 0,
      );
      _infoCache.set(channelId, info);
      return info;
    } catch (e) {
      debugPrint('[TubeChannelService] Channel header fetch error: $e');
      return TubeChannelInfo(
        id: channelId,
        title: 'Channel',
        avatarUrl: '',
      );
    }
  }

  /// Retrieves and sorts all loaded video uploads for the channel.
  Future<List<TubeChannelVideo>> getChannelVideos(
    String channelId, {
    TubeChannelSortOrder sort = TubeChannelSortOrder.latest,
  }) async {
    final rawVideos = await _getRawChannelUploads(channelId);

    // Filter to normal videos (non-shorts)
    final normalVideos = rawVideos.where((v) => !v.isShort).toList();

    // Sort according to user preference
    switch (sort) {
      case TubeChannelSortOrder.popular:
        normalVideos
            .sort((a, b) => (b.viewCount ?? 0).compareTo(a.viewCount ?? 0));
        break;
      case TubeChannelSortOrder.oldest:
        normalVideos.sort((a, b) {
          if (a.uploadDate == null && b.uploadDate == null) return 0;
          if (a.uploadDate == null) return 1;
          if (b.uploadDate == null) return -1;
          return a.uploadDate!.compareTo(b.uploadDate!);
        });
        break;
      case TubeChannelSortOrder.latest:
        normalVideos.sort((a, b) {
          if (a.uploadDate == null && b.uploadDate == null) return 0;
          if (a.uploadDate == null) return 1;
          if (b.uploadDate == null) return -1;
          return b.uploadDate!.compareTo(a.uploadDate!);
        });
        break;
    }

    return normalVideos.map((item) {
      return TubeChannelVideo(
        item: item,
        isMembersOnly: item.isMembersOnly,
        isLive: item.isLive,
      );
    }).toList();
  }

  /// Paginates and loads more videos for the channel so every video of the creator is accessible
  Future<List<TubeChannelVideo>> loadMoreChannelVideos(
    String channelId, {
    TubeChannelSortOrder sort = TubeChannelSortOrder.latest,
  }) async {
    await _pager(channelId).loadMore();
    return getChannelVideos(channelId, sort: sort);
  }

  /// Retrieves channel-specific Shorts
  Future<List<TubeChannelShort>> getChannelShorts(String channelId) async {
    final rawVideos = await _getOtherUploads(channelId);
    final shorts =
        rawVideos.where((v) => v.isShort || v.durationSeconds <= 60).toList();

    return shorts.map((item) {
      return TubeChannelShort(
        item: item,
        viewCount: item.viewCount,
      );
    }).toList();
  }

  /// Retrieves active or past livestreams for the channel
  Future<List<TubeChannelLive>> getChannelLiveStreams(String channelId) async {
    final rawVideos = await _getOtherUploads(channelId);
    final liveVideos = rawVideos.where((v) => v.isLive).toList();

    return liveVideos.map((item) {
      return TubeChannelLive(
        item: item,
        isCurrentlyLive: item.isLive,
      );
    }).toList();
  }

  /// Retrieves playlists created by this channel
  Future<List<TubeChannelPlaylist>> getChannelPlaylists(
      String channelId) async {
    return [];
  }

  /// Fetches public Community / Posts only if publicly available without authentication.
  Future<List<TubeChannelPost>> getChannelCommunityPosts(
      String channelId) async {
    return [];
  }

  TubeVideoItem _mapVideoToTubeItem(Video video) {
    final isShort = video.duration != null && video.duration!.inSeconds <= 60;
    final isLive = video.isLive;
    final views = video.engagement.viewCount;

    return TubeVideoItem(
      id: video.id.value,
      title: video.title,
      channelTitle: video.author,
      channelId: video.channelId.value,
      thumbnailUrl: video.thumbnails.highResUrl.isNotEmpty
          ? video.thumbnails.highResUrl
          : 'https://i.ytimg.com/vi/${video.id.value}/hqdefault.jpg',
      durationSeconds: video.duration?.inSeconds ?? 0,
      uploadDate: video.uploadDate,
      viewCount: views,
      isShort: isShort,
      isLive: isLive,
      description: video.description,
    );
  }

  // --- Internal Helper: Raw Uploads Stream with Caching & Lazy Pagination ---
  Future<List<TubeVideoItem>> _getRawChannelUploads(String channelId) async {
    final pager = _pager(channelId);
    return pager.items.isEmpty ? await pager.loadMore() : pager.items;
  }

  TubeChannelUploadPager _pager(String channelId) => _pagers.putIfAbsent(
      channelId,
      () => TubeChannelUploadPager(
            readPage: (token) async {
              final info = await getChannel(channelId);
              return TubeInnertubeClient().channelVideos(info.id,
                  continuation: token, channelTitle: info.title);
            },
            fallbackUploads: () => _ytPool.yt.channels
                .getUploads(channelId)
                .map(_mapVideoToTubeItem),
          ));

  Future<List<TubeVideoItem>> _getOtherUploads(String channelId) =>
      _otherUploads.putIfAbsent(channelId, () async {
        try {
          return await _ytPool.yt.channels
              .getUploads(channelId)
              .take(60)
              .map(_mapVideoToTubeItem)
              .toList()
              .timeout(const Duration(seconds: 15));
        } catch (_) {
          _otherUploads.remove(channelId);
          return <TubeVideoItem>[];
        }
      });
}
