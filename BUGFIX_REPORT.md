# ShreyX Tube 1.0.1 — playback and discovery fixes

12 October 2026. Android arm64 release APK: `build/app/outputs/flutter-apk/app-release.apk`.

| Report | Change | Verification / limit |
| --- | --- | --- |
| Shorts in Home | Classify using YouTube's Shorts endpoint/overlay, including longer Shorts. Exclude them from Home. Shorts discovery no longer relabels ordinary search videos. | Regression fixtures cover 2:30 Shorts and 0:45 regular videos, filtering, deduplication and continuation. |
| Incorrect channel name | Empty owner metadata falls through to the real byline. Modern cards read channel metadata and avatars. Playback also retains extracted uploader IDs and avatars. | Parser regressions; full creator names visible on the phone's Home feed. |
| Slow video loading | Start Auto at 720p when available; reduce initial buffer to 750 ms; share concurrent extraction; load recommendations and fallback captions independently. Expired-stream recovery forces fresh extraction. | A normal 720p video reached READY about 2.9 seconds after extraction began on the S24. Network conditions still affect startup and buffering. |
| Missing suggestions after results | Refocus/tap requests and displays suggestions for the existing query. | Widget regression and phone check: tapping `music` after results showed suggestions again. |
| YouTube recommendations | Read public Home / Up Next and retain returned order. Follow real cursors instead of fabricated page searches. | Phone Up Next returned 20 videos. A fresh accountless Home can be empty; fallback uses public Up Next from local history, then public discovery. Signed-in YouTube recommendations cannot be reproduced without that session. Shorts remain public search-based discovery. |
| Live videos fail to play | Detect actual live streams, select HLS/DASH manifests, expose LIVE action to seek toward the available live edge, recover after falling behind the live window, and hide live downloads. Live Auto is capped at 720p to reduce bandwidth stalls. | Republic TV live played on the phone with 20 Up Next items. The player targets 3 seconds, but measured source offsets were approximately 6–12 seconds. A forced startup seek did not improve the offset and caused extra buffering, so it was removed. The available HLS window and network constrain latency; the requested strict few-second delay remains unmet. |
| Repeated crashes / unexpected exits | Android crash logs identified a foreground-service startup deadline. Publish the service notification immediately, including paused/buffering restarts. Guard late extraction and disposed-provider callbacks; make PiP aspect ratios valid. Back handling now belongs to actual navigation routes. Isolate the watch navigator's Hero controller and back notifications. | Four pre-fix foreground-service crashes were recorded. Release playback continued past the deadline. Repeated navigation exposed a separate Hero-controller exception after closing the player; the new regression reproduces that error without the isolation and passes with it. Tests also cover late extraction and Back on Search. This is not a guarantee against every future crash. |
| Rough experience | Limit image decoding/cache memory; avoid rebuilding the whole shell for progress events; enforce audio focus; make Shorts activation idempotent; hide player controls automatically. | Release build, normal/live/Shorts playback checks. |
| YouTube design | Full-width search cards, filled search field, All/Live discovery chips, dark surfaces, channel avatars, live controls and automatic control hiding. | Closer mobile layout and behavior; the entire app is not a pixel-identical copy of every YouTube screen. |

## Automated checks

- `flutter analyze --no-pub`: no issues.
- `flutter test --no-pub`: 62 passing tests, including 16 playback/feed regressions added in this fix pass.
- Four focused pre-fix contracts failed against a saved source copy: Shorts classification, empty-owner channel fallback, upcoming/live distinction, and suggestion refocus.
- A fifth regression fails when the watch navigator shares the root Hero controller; the corrected navigation boundary preserves both root Search and Android Back handling.
- `flutter build apk --release --target-platform android-arm64 --no-pub`: successful, approximately 27 MB.
- `git diff --check`: clean.

## Device

Galaxy S24 SM-S921E, Android 16, wireless ADB. Installed as an update with existing app data retained. Native Media3 logs confirmed normal 720p, live HLS and Shorts reaching READY with playback active. Existing Android exit records also distinguish package updates, user task removal and background low-memory termination from the original service crashes.

Physical checks also confirmed Back minimizing to the mini-player, repeated expand/minimize transitions, Search opening afterward, suggestions reappearing after results, and live URL playback with channel metadata and 20 public Up Next videos. The final navigation regression explicitly verifies the Android back-handling flag and that closing the nested watch navigator preserves root Search.

The APK uses the project's existing debug signing configuration for local installation. Desktop plugin declarations and the future Kotlin/Gradle migration warning are unchanged.
