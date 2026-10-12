# Discovery and membership update

Verified on 12 October 2026. This supplements the pasted v2 handover.

## Search

- Explicit submissions, filter changes and pull-to-refresh bypass the five-minute memory cache.
- The filter sheet exposes Relevance, Upload Date (Latest), Popularity and upload periods including Last Hour.
- Filters compose rather than overwriting each other; the cache key includes content type.
- Latest defaults to Today, requests that upload period, and orders returned timestamps locally. The selected period is visible in the sheet. Older periods remain available.
- Search generations prevent old requests or old continuation pages from replacing newer results. Final continuation tokens can be cleared.

The live API did not reliably honor the legacy upload-date sort field on its own. The recent-period request and local ordering are intentional. They order the candidates YouTube returns; they cannot force YouTube to index an upload or return every matching video.

## Channel uploads

- The correct Videos-tab parameter is `EgZ2aWRlb3PyBgQKAjoA`. The handover's `Egl2aWRlb3PyBgQKAjoA` selected Home in live checks.
- Browse continuation pages have no application-imposed catalog limit. The parser supports classic video renderers and modern video lockups and reads only the selected Videos tab.
- An unexpected Home response triggers fallback instead of falsely marking the uploads complete.
- A lazy youtube_explode uploads stream supplies fallback items after a browse error. The browse cursor remains retryable; IDs are deduplicated and overlapping load requests share one operation.
- Existing uploads survive errors, with a visible retry action and a manual Load more action for short lists.
- Popular and Oldest continue to sort the loaded uploads. Channel Shorts/Live discovery retains its existing bounded upload scan; this change does not add full pagination to those tabs.

## Members-only content

- Membership comes from actual badge metadata, including modern cards, rather than title keywords.
- Home and compact cards show a gold MEMBERS ONLY badge.
- Opening a known restricted video pauses native audio, stops Shorts, skips extraction, and shows a thumbnail-backed notice with Copy Link. Download and PiP actions are hidden for that notice.
- Recognizable membership failures from extraction also open the notice. Stale native callbacks do not replace the restricted state.
- Metadata can only be shown when YouTube exposes it publicly. Playback still requires an eligible authenticated membership through YouTube; the app remains accountless and communicates directly with YouTube.

## Verification

- `flutter analyze --no-pub`: zero issues.
- `flutter test --no-pub`: 46 passing tests, including 18 new regression tests.
- Regression coverage includes a simulated 2,400-upload catalog, fallback/retry, duplicate pages, concurrent loads, filter composition, request races, empty-result refresh, badges and restricted playback.
- Three regression contracts failed as expected against an isolated archive of the original Git snapshot: combined filters, clearing an exhausted cursor and parsing membership badges.
- Live checks through gstack browse returned 30 Videos-tab uploads followed by 30 different uploads, with another continuation token. Last Hour search returned uploads aged minutes; Today returned uploads aged hours.
- The Android debug build was rebuilt after these changes. APK: `build/app/outputs/flutter-apk/app-debug.apk`.

- Installed the debug APK as an update over wireless ADB on a Galaxy S24 (SM-S921E), running Android 16. Installation and cold launch succeeded, existing app data remained available, and the home feed loaded with thumbnails. The startup log check found no matching fatal or unhandled app errors. Screenshot: `build/s24-installed-smoke.png`.

This describes the earlier discovery build. The subsequent 1.0.1 release fixes and physical-device playback checks are recorded in [BUGFIX_REPORT.md](BUGFIX_REPORT.md). Existing desktop plugin and Kotlin migration warnings remain outside this Android feature update.
