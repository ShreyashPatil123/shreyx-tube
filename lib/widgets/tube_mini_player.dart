import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/tube_player_provider.dart';
import '../theme/tube_theme.dart';
import 'tube_image.dart';

/// Modern YouTube-style floating / docked mini-player (64dp height).
/// Docks persistently above bottom navigation and preserves playback across all screens.
class TubeMiniPlayer extends StatelessWidget {
  final VoidCallback onExpand;

  const TubeMiniPlayer({super.key, required this.onExpand});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TubePlayerProvider>();

    if (!provider.isPlayerVisible) {
      return const SizedBox.shrink();
    }

    final video = provider.currentVideoItem;
    final resolved = provider.resolvedVideo;
    final title = resolved?.title ?? video?.title ?? 'Playing Video';
    final channel = resolved?.uploader ?? video?.channelTitle ?? 'Channel';
    final thumb = resolved?.thumbnailUrl.isNotEmpty == true
        ? resolved!.thumbnailUrl
        : (video?.thumbnailUrl ?? '');

    final progressRatio = provider.duration.inMilliseconds > 0
        ? (provider.position.inMilliseconds / provider.duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return Dismissible(
      key: ValueKey('mini_player_${video?.id ?? "active"}'),
      direction: DismissDirection.down,
      onDismissed: (_) {
        provider.dismissPlayer();
      },
      child: GestureDetector(
        onVerticalDragEnd: (details) {
          if (details.primaryVelocity != null && details.primaryVelocity! < -200) {
            onExpand();
          } else if (details.primaryVelocity != null && details.primaryVelocity! > 200) {
            provider.dismissPlayer();
          }
        },
        child: Container(
          height: TubeTheme.miniPlayerHeight,
          decoration: BoxDecoration(
            color: TubeTheme.surfaceVariant,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 10,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Column(
              children: [
                // 1. YouTube-style Slim Red Progress Indicator
                LinearProgressIndicator(
                  value: progressRatio,
                  backgroundColor: Colors.white.withValues(alpha: 0.1),
                  valueColor: const AlwaysStoppedAnimation(TubeTheme.progressRed),
                  minHeight: 2,
                ),

                // 2. Mini-Player Content Row
                Expanded(
                  child: InkWell(
                    onTap: onExpand,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8.0),
                      child: Row(
                        children: [
                          // Thumbnail Preview (16:9 ratio)
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: SizedBox(
                              width: 80,
                              height: 48,
                              child: thumb.isNotEmpty
                                  ? TubeNetworkImage(imageUrl: thumb, fit: BoxFit.cover)
                                  : Container(
                                      color: TubeTheme.surface,
                                      child: const Icon(Icons.play_circle_outline, color: TubeTheme.textTertiary),
                                    ),
                            ),
                          ),
                          const SizedBox(width: 10),

                          // Title & Channel
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TubeTheme.titleMedium.copyWith(fontSize: 13),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  channel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TubeTheme.bodySmall.copyWith(fontSize: 11),
                                ),
                              ],
                            ),
                          ),

                          // Transport Controls
                          IconButton(
                            icon: Icon(
                              provider.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                              color: TubeTheme.textPrimary,
                              size: 26,
                            ),
                            onPressed: () => provider.togglePlayPause(),
                            tooltip: 'Play/Pause',
                          ),
                          IconButton(
                            icon: const Icon(Icons.close_rounded, color: TubeTheme.textSecondary, size: 20),
                            onPressed: () => provider.dismissPlayer(),
                            tooltip: 'Close Player',
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
