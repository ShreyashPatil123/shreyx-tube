import 'package:flutter/foundation.dart';
import '../models/tube_models.dart';
import 'tube_content_service.dart';
import 'tube_storage_service.dart';

/// Local Following Feed Aggregator ("My Channels" / "Following").
/// Aggregates public video uploads from locally followed channels with bounded concurrency.
/// Merges, deduplicates, and sorts uploads chronologically without modifying any YouTube account.
class TubeFollowingService {
  static final TubeFollowingService _instance = TubeFollowingService._internal();
  factory TubeFollowingService() => _instance;
  TubeFollowingService._internal();

  final TubeStorageService _storage = TubeStorageService();
  final TubeContentService _content = TubeContentService();

  /// Fetches latest public uploads from all locally followed channels.
  /// Uses bounded concurrency (max 3 concurrent channel requests) to prevent rate limits.
  Future<List<TubeVideoItem>> getFollowingFeed() async {
    final followed = _storage.getFollowedChannels();
    if (followed.isEmpty) return [];

    debugPrint('[TubeFollowingService] Aggregating feed for ${followed.length} locally followed channels');

    final List<TubeVideoItem> allVideos = [];
    const int maxConcurrency = 3;
    final batches = <List<TubeChannelInfo>>[];

    for (var i = 0; i < followed.length; i += maxConcurrency) {
      batches.add(followed.sublist(i, (i + maxConcurrency).clamp(0, followed.length)));
    }

    for (final batch in batches) {
      final futures = batch.map((ch) => _content.getChannelUploads(ch.id, limit: 10));
      final results = await Future.wait(futures);
      for (final list in results) {
        allVideos.addAll(list);
      }
    }

    // De-duplicate by video ID
    final seen = <String>{};
    final uniqueVideos = allVideos.where((v) => seen.add(v.id)).toList();

    // Sort chronologically (newest first)
    uniqueVideos.sort((a, b) {
      if (a.uploadDate != null && b.uploadDate != null) {
        return b.uploadDate!.compareTo(a.uploadDate!);
      }
      return 0;
    });

    debugPrint('[TubeFollowingService] Aggregated ${uniqueVideos.length} unique videos from followed channels');
    return uniqueVideos;
  }
}
