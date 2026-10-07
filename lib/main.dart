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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
  final GlobalKey<NavigatorState> _watchNavigatorKey = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ShreyX Tube',
      debugShowCheckedModeBanner: false,
      theme: TubeTheme.buildThemeData(),
      builder: (context, child) {
        return Consumer<TubePlayerProvider>(
          builder: (context, provider, _) {
            return PopScope(
              canPop: !provider.isExpanded,
              onPopInvokedWithResult: (didPop, _) {
                if (didPop) return;
                if (_watchNavigatorKey.currentState?.canPop() ?? false) {
                  _watchNavigatorKey.currentState?.pop();
                  return;
                }
                if (provider.isExpanded) {
                  provider.collapsePlayer();
                }
              },
              child: Stack(
                children: [
                  child ?? const SizedBox(),
                  // Animated Sliding Full Watch Page Overlay
                  if (provider.isPlayerVisible)
                    AnimatedSlide(
                      offset: provider.isExpanded ? Offset.zero : const Offset(0, 1),
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOutCubic,
                      child: provider.isExpanded
                          ? Positioned.fill(
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
                    ),
                ],
              ),
            );
          },
        );
      },
      home: const TubeMainShell(),
    );
  }
}
