import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'providers/tube_player_provider.dart';
import 'providers/tube_shorts_controller.dart';
import 'screens/tube_main_shell.dart';
import 'screens/tube_watch_screen.dart';
import 'services/tube_database_service.dart';
import 'services/tube_download_service.dart';
import 'services/tube_storage_service.dart';
import 'services/tube_user_profile_service.dart';
import 'theme/tube_theme.dart';
import 'widgets/tube_player_back_observer.dart';
import 'widgets/tube_watch_navigation_boundary.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  PaintingBinding.instance.imageCache.maximumSize = 120;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 96 * 1024 * 1024;

  // Configure edge-to-edge transparent system UI
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Colors.black,
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  // Initialize 100% on-device local services & database
  await TubeDatabaseService.instance.init();
  await TubeStorageService().init();
  await TubeUserProfileService().init();
  await TubeDownloadService().init();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => TubePlayerProvider()),
        ChangeNotifierProvider(create: (_) => TubeShortsController()),
      ],
      child: const ShreyXTubeApp(),
    ),
  );
}

class ShreyXTubeApp extends StatefulWidget {
  const ShreyXTubeApp({super.key});

  @override
  State<ShreyXTubeApp> createState() => _ShreyXTubeAppState();
}

class _ShreyXTubeAppState extends State<ShreyXTubeApp> {
  final GlobalKey<NavigatorState> _watchNavigatorKey =
      GlobalKey<NavigatorState>();
  late final TubePlayerBackObserver _backObserver;

  @override
  void initState() {
    super.initState();
    _backObserver = TubePlayerBackObserver(onPlayerBack: () {
      if (_watchNavigatorKey.currentState?.canPop() ?? false) {
        _watchNavigatorKey.currentState?.pop();
        return;
      }
      final player = context.read<TubePlayerProvider>();
      if (player.isFullscreen) {
        player.toggleFullscreen();
      } else {
        player.collapsePlayer();
      }
    });
  }

  @override
  void dispose() {
    _backObserver.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ShreyX Tube',
      debugShowCheckedModeBanner: false,
      navigatorObservers: [_backObserver],
      theme: TubeTheme.buildThemeData(),
      builder: (context, child) {
        return Selector<TubePlayerProvider, (bool, bool)>(
          selector: (_, p) => (p.isPlayerVisible, p.isExpanded),
          builder: (context, visibility, _) {
            final provider = context.read<TubePlayerProvider>();
            _backObserver.expanded = provider.isExpanded;
            return Stack(
              children: [
                child ?? const SizedBox(),
                // Animated Sliding Full Watch Page Overlay
                if (provider.isPlayerVisible)
                  Positioned.fill(
                      child: AnimatedSlide(
                    offset:
                        provider.isExpanded ? Offset.zero : const Offset(0, 1),
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOutCubic,
                    child: provider.isExpanded
                        ? TubeWatchNavigationBoundary(
                            child: Navigator(
                              key: _watchNavigatorKey,
                              onGenerateRoute: (settings) => MaterialPageRoute(
                                builder: (watchContext) => TubeWatchScreen(
                                  onCollapse: () => provider.collapsePlayer(),
                                ),
                              ),
                            ),
                          )
                        : const SizedBox.shrink(),
                  )),
              ],
            );
          },
        );
      },
      home: const TubeMainShell(),
    );
  }
}
