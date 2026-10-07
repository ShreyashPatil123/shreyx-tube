import 'package:flutter/material.dart';
import '../models/tube_models.dart';
import '../services/tube_following_service.dart';
import '../services/tube_storage_service.dart';
import '../theme/tube_theme.dart';
import '../widgets/tube_skeleton.dart';
import '../widgets/tube_video_card.dart';
import 'tube_channel_screen.dart';

/// YouTube Subscriptions screen displaying followed channel uploads.
/// Features:
/// - Horizontal avatar strip of all subscribed channels
/// - Infinite chronological feed of videos from followed channels
/// - Shimmer loading skeleton
class TubeFollowingScreen extends StatefulWidget {
  const TubeFollowingScreen({super.key});

  @override
  State<TubeFollowingScreen> createState() => _TubeFollowingScreenState();
}

class _TubeFollowingScreenState extends State<TubeFollowingScreen> {
  final TubeFollowingService _followingService = TubeFollowingService();
  final TubeStorageService _storageService = TubeStorageService();

  List<TubeChannelInfo> _followedChannels = [];
  List<TubeVideoItem> _feed = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final channels = _storageService.getFollowedChannels();
    setState(() {
      _followedChannels = channels;
      _isLoading = channels.isNotEmpty;
    });

    if (channels.isNotEmpty) {
      final feed = await _followingService.getFollowingFeed();
      if (mounted) {
        setState(() {
          _feed = feed;
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TubeTheme.background,
      appBar: AppBar(
        backgroundColor: TubeTheme.background,
        elevation: 0,
        title: const Text('Subscriptions', style: TubeTheme.appBarTitle),
      ),
      body: _followedChannels.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.subscriptions_outlined, size: 64, color: TubeTheme.textTertiary),
                    SizedBox(height: 16),
                    Text(
                      'Don\'t miss new videos',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: TubeTheme.textPrimary),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Follow your favorite channels to see their latest public uploads here. All subscriptions are stored locally and privately on your device.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, color: TubeTheme.textSecondary, height: 1.4),
                    ),
                  ],
                ),
              ),
            )
          : RefreshIndicator(
              color: TubeTheme.progressRed,
              backgroundColor: TubeTheme.surfaceVariant,
              onRefresh: _loadData,
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  // 1. Channel Avatars Horizontal Strip
                  SizedBox(
                    height: 98,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      itemCount: _followedChannels.length,
                      itemBuilder: (context, idx) {
                        final ch = _followedChannels[idx];
                        return GestureDetector(
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => TubeChannelScreen(channelId: ch.id, channelTitle: ch.title),
                              ),
                            ).then((_) => _loadData());
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8.0),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CircleAvatar(
                                  radius: 28,
                                  backgroundColor: TubeTheme.surfaceVariant,
                                  backgroundImage: ch.avatarUrl.isNotEmpty ? NetworkImage(ch.avatarUrl) : null,
                                  child: ch.avatarUrl.isEmpty
                                      ? Text(
                                          ch.title.isNotEmpty ? ch.title[0].toUpperCase() : 'C',
                                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                        )
                                      : null,
                                ),
                                const SizedBox(height: 4),
                                SizedBox(
                                  width: 64,
                                  child: Text(
                                    ch.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(fontSize: 11, color: TubeTheme.textSecondary),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),

                  const Divider(color: TubeTheme.divider, height: 1),

                  // 2. Feed of Uploads
                  if (_isLoading)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: TubeShimmerWrapper(
                        child: Column(
                          children: [
                            TubeVideoCardSkeleton(),
                            SizedBox(height: 16),
                            TubeVideoCardSkeleton(),
                          ],
                        ),
                      ),
                    )
                  else if (_feed.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(32.0),
                      child: Center(
                        child: Text(
                          'No recent uploads found from your followed channels.',
                          style: TextStyle(color: TubeTheme.textTertiary),
                        ),
                      ),
                    )
                  else
                    ..._feed.map((v) => TubeVideoCard(video: v)),
                ],
              ),
            ),
    );
  }
}
