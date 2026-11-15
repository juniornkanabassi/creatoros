# CreatorOS Companion (iPhone)

A small iPhone app and one large Home Screen widget for CreatorOS Socials, YouTube only for now. It shows only figures the YouTube API returns, read through the `social-stats` Worker (`docs/SOCIALS-API.md`). It is personal and undistributed: built and installed by hand on Junior's own iPhone, never on the App Store or TestFlight.

- App `CreatorOS` (`com.juniornkanabassi.CreatorOS.Companion`): set-up screen (privacy note, Worker address, pairing code), then a Today view with pull to refresh, account status, "Clear data on this iPhone" and "Remove this iPhone". YouTube itself is connected from the Mac.
- Widget `SocialsWidget` (`...Companion.SocialsWidget`): `.systemLarge` only. Reloads about every 30 minutes (iOS decides the real time; no maximum delay is promised) and has a refresh button.
- `Shared/` is compiled into the app, the widget and the tests. `../Sources/SocialsCore/SocialsCore.swift` is compiled into each target directly, so Sparkle never resolves for iOS.

## Regenerate the project

```sh
cd Companion
xcodegen
```

`CreatorOSCompanion.xcodeproj` and the plists and entitlements are generated from `project.yml` and committed. Edit `project.yml`, never the project.

## Check

```sh
xcodebuild build -project CreatorOSCompanion.xcodeproj -scheme CreatorOS -destination 'generic/platform=iOS Simulator'
xcodebuild build -project CreatorOSCompanion.xcodeproj -scheme CreatorOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
xcodebuild test  -project CreatorOSCompanion.xcodeproj -scheme CreatorOS -destination 'platform=iOS Simulator,name=<an iOS 27.2 iPhone>'
```

The tests check the display-state choice (not set up, loading, expired, not connected, needs reconnecting, waiting, normal) and render the widget view for each state to PNG, headless. They write to `/private/tmp/socials/evidence/iphone/`, or to `EVIDENCE_DIR` when set.

## Install on the iPhone

Turn on Developer Mode on the iPhone (Settings, Privacy & Security, Developer Mode) and trust this Mac. Then either:

- open `CreatorOSCompanion.xcodeproj` in Xcode, choose the iPhone and press Run (team `M6L2VW4W5Z`, automatic signing); or
- build for the device and install with `xcrun devicectl device install app --device <id> <path to CreatorOS.app>`.

First launch: enter the Worker address (defaults to `https://social-stats.junior-nkana-bassi.workers.dev`) and the pairing code from the Mac's Accounts sheet. Add the widget from the Home Screen gallery (Socials, large).

A free-tier or personal-team profile expires after 7 days. With a paid developer team it lasts a year; reinstall when it lapses.

## App Group and Keychain group

Both targets carry the same two entitlements, set in `project.yml`:

- App Group `group.com.juniornkanabassi.creatoros`: holds `socials-cache.json` (`SocialsCache`) and the Worker address (`UserDefaults(suiteName:)`).
- Keychain access group `$(AppIdentifierPrefix)com.juniornkanabassi.creatoros.shared`, which resolves to `M6L2VW4W5Z.com.juniornkanabassi.creatoros.shared`. The app stores the device token there so the widget can read it.

Automatic signing registers both capabilities for the two bundle ids on first build. If the widget shows "Open CreatorOS to set up" after set-up, the groups are not matching; check both targets' Signing & Capabilities.

## Rules it follows

- No derived metrics: no weekly or percentage change, no combined totals, no net subscribers. Gained and lost are separate figures; the 28-day window is labelled with the dates YouTube returned and tagged "partial" when it is.
- Seven days without contact shows "Offline, data expired" and no figures; thirty days deletes the cache. A `401` wipes the token and cache; a `deletions` entry from the Worker clears the YouTube cache.
