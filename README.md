# ShreyX Tube 📺

**Autonomous High-Performance, Privacy-Focused YouTube Client for Android**

ShreyX Tube is a modern, lightweight YouTube video streaming client built with Flutter and native AndroidX Media3 / ExoPlayer hardware decoding. Designed from the ground up for zero account tracking, zero ads, and direct on-device stream multiplexing without restrictive web wrappers or third-party proxy relays.

---

## Key Highlights

- **Direct Native Media3 Surface**: Video streams are decoded directly using native AndroidX Media3 (ExoPlayer 1.4.1) hardware decoders rather than wrapping YouTube in sluggish WebViews or iframe sandboxes.
- **Adaptive 1080p, 1440p & 4K Stream Merging**: Leverages ExoPlayer's `MergingMediaSource` to pair standalone high-resolution video streams with high-bitrate Opus/AAC audio in real time with zero disk remuxing.
- **Accountless & Ad-Free**: Enjoy video streaming without Google login, tracking cookies, or banner/pre-roll interruptions.
- **Dynamic Ephemeral URL Recovery**: Media URLs are treated as strictly ephemeral. On HTTP 403/410 expiration, playback position is captured, the stream is re-resolved on-device, and playback resumes automatically.
- **Hardware Gesture HUD**: Intuitive swipe controls for brightness and volume on player surfaces, plus double-tap seeking.
- **Persistent Floating Mini-Player**: Video continues decoding smoothly across tab transitions (Home, Shorts, Subscriptions, Library).
- **Dedicated Shorts Engine**: High-framerate vertical swipe player (`TubeShortsScreen`) powered by dedicated decoder bridges.
- **Local SQLite Database**: Watch history, subscriptions, and offline caches reside purely on device storage via `sqflite`.

---

## Architecture & Tech Stack

- **UI & Framework**: Flutter 3 (Dart `>=3.0.0 <4.0.0`)
- **Native Video Decoder**: AndroidX Media3 / ExoPlayer 1.4.1 (`media3-exoplayer`, `media3-ui`, `media3-datasource`, `media3-session`)
- **Native Android Bridge**: Kotlin Coroutines (`TubePlayerBridge.kt`, `TubeShortsPlayerBridge.kt`, `TubePlaybackService.kt`)
- **On-Device Stream Resolution**: `youtube_explode_dart: ^3.1.0` & `NewPipeExtractor: v0.26.5`
- **State Management**: `provider: ^6.1.1`
- **Local Persistence**: `sqflite: ^2.3.0`, `shared_preferences: ^2.2.2`, `path_provider: ^2.1.2`
- **Image Caching & Shimmer**: `cached_network_image: ^3.3.0`, `shimmer: ^3.0.0`
- **Target Platform**: Android (Tested on Samsung Galaxy S24, Snapdragon 8 Gen 3)

---

## Project Structure

```
shreyx-tube/
├── android/
│   └── app/src/main/kotlin/com/shreyx/tube/
│       ├── MainActivity.kt
│       ├── TubePlayerBridge.kt
│       ├── TubeShortsPlayerBridge.kt
│       └── TubePlaybackService.kt
├── lib/
│   ├── main.dart
│   ├── models/            # Video, stream, and download models
│   ├── providers/         # Player, quality, queue, and watch history providers
│   ├── screens/           # Watch, home, search, shorts, channel, library screens
│   ├── services/          # Media3 resolver, SQLite DB, cache, recommendation engine
│   ├── theme/             # AMOLED-optimized Material Design 3 theme
│   └── widgets/           # Gesture HUD, native player views, video cards
└── pubspec.yaml
```

---

## Building Locally

Ensure Flutter and the Android SDK (API 34+) are installed:

```bash
# Get dependencies
flutter pub get

# Run on connected Android device
flutter run

# Build standalone preview APK
flutter build apk --debug
```

---

## License

Developed independently by **Shreyash Patil** under **ShreyX Studio**.
