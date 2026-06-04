# Sloucher Publishing Handoff

Date: 2026-06-02

## Goal

Ship Sloucher as a legitimate macOS app:

- Direct download now: signed, notarized, stapled `.dmg`.
- Mac App Store later: sandboxed archive/upload through App Store Connect.

## Current Release

Direct-download release is ready.

Shippable artifact:

- `dist/Sloucher-0.1.0.dmg`

Also available:

- `dist/Sloucher-0.1.0+1.app.zip`

Signing/notarization state:

- Apple team ID: `9MXC88C783`
- Developer ID identity: `Developer ID Application: Nitin Sangwan (9MXC88C783)`
- Notary profile: `sloucher-notary`
- DMG notary submission: `2ac7a51e-de07-4d3e-acc9-bc44f89a7ac8`
- App notary submission: `ba97b395-e9ef-45b0-ab3a-a44c0d0427e2`

Important: do not use `TC2S48VYN6` as the team ID. It appears in the Apple Development certificate display name, but the release team ID is `9MXC88C783`.

## Direct Download Files

Key files:

- `scripts/release_direct_download.sh`
- `scripts/release_direct_xcode_managed.sh`
- `docs/DIRECT_DISTRIBUTION.md`
- `PRIVACY.md`
- `Sloucher/Assets.xcassets/`

Project changes:

- App icon asset catalog added and wired into Xcode.
- Release hardened runtime enabled.
- Release base entitlement injection disabled so local Release builds do not carry debug `get-task-allow`.
- `dist/` ignored in `.gitignore`.
- Release builds keep forensic camera frame/raw-plane capture out of shipped code via `#if DEBUG`.

Preferred future release command now that the local Developer ID identity and notary profile exist:

```bash
DEVELOPER_ID_APPLICATION="Developer ID Application: Nitin Sangwan (9MXC88C783)" \
DEVELOPMENT_TEAM="9MXC88C783" \
NOTARY_PROFILE="sloucher-notary" \
rtk scripts/release_direct_download.sh
```

Fallback Xcode-managed command if local Developer ID signing is unavailable:

```bash
DEVELOPMENT_TEAM="9MXC88C783" \
rtk scripts/release_direct_xcode_managed.sh
```

## Direct Verification

These passed on `dist/Sloucher-0.1.0.dmg`:

```bash
rtk codesign --verify --verbose=2 dist/Sloucher-0.1.0.dmg
rtk xcrun stapler validate dist/Sloucher-0.1.0.dmg
rtk spctl --assess --type open --context context:primary-signature --verbose=4 dist/Sloucher-0.1.0.dmg
```

Result of the final Gatekeeper check:

```text
dist/Sloucher-0.1.0.dmg: accepted
source=Notarized Developer ID
```

Mounted-app verification also passed:

```bash
rtk xcrun stapler validate /Volumes/Sloucher/Sloucher.app
rtk spctl --assess --type execute --verbose=4 /Volumes/Sloucher/Sloucher.app
```

## Direct QA Still Needed

Install from `dist/Sloucher-0.1.0.dmg` and verify as a user:

- Drag `Sloucher.app` into `/Applications`.
- Launch from `/Applications`, not Xcode or DerivedData.
- Confirm macOS opens it without Gatekeeper warnings.
- Confirm the menu-bar item appears as `Sloucher` and no Dock icon appears.
- On a clean first run, confirm the `Set Up Sloucher` window appears when camera access is missing.
- Click `Enable Camera`, allow camera access, and confirm the setup window closes after camera access is granted.
- Confirm notification permission is optional: no notification prompt appears until `Enable Notifications` or `Test nudge` is clicked.
- Calibrate while sitting upright.
- Confirm `Test nudge` works for notification, sound, and screen glow. If notifications were denied, confirm sound and screen glow still work and the UI offers Settings.
- Confirm Pause, Snooze, Launch at Login, and Quit.
- Confirm no static UI labels are truncated in the menu-bar window.

## Mac App Store State

App Store package upload succeeded. The uploaded build is processing in App Store Connect.

Key files:

- `scripts/release_app_store.sh`
- `docs/APP_STORE.md`
- `Sloucher/AppStore.entitlements`
- `Sloucher/PrivacyInfo.xcprivacy`

Project changes:

- Privacy manifest is bundled as a resource.
- App Store entitlements file declares:
  - `com.apple.security.app-sandbox`
  - `com.apple.security.device.camera`
- App Store archives use the `AppStore` build configuration and `Sloucher AppStore` scheme so manual Xcode archives and script uploads both include sandbox entitlements.

Remaining App Store tasks:

- Provide public privacy policy URL.
- Complete App Store Connect privacy details to match `PRIVACY.md` and `Sloucher/PrivacyInfo.xcprivacy`.
- Upload screenshots from `docs/app-store/screenshots/`.
- Provide reviewer notes from `docs/APP_STORE.md`.
- Wait for the uploaded build to finish App Store Connect processing, then attach it to the app version.

Upload attempts on 2026-06-02:

- Command: `DEVELOPMENT_TEAM=9MXC88C783 APP_STORE_DESTINATION=upload rtk scripts/release_app_store.sh`
- First archive result: succeeded.
- Entitlements confirmed in archive: `com.apple.security.app-sandbox` and `com.apple.security.device.camera`.
- First export/upload result: failed at `IDEDistributionFetchAppRecordStep` because App Store Connect had no app record for `app.sloucher.Sloucher`.
- Later Xcode Organizer distribute attempt failed with Apple error `90296` because the manual archive did not include `com.apple.security.app-sandbox`.
- Fix: added `AppStore` build configuration and shared `Sloucher AppStore` scheme. Its Archive action uses the `AppStore` configuration, which sets `CODE_SIGN_ENTITLEMENTS=Sloucher/AppStore.entitlements`.
- Verification: archive from `Sloucher AppStore` contains `com.apple.security.app-sandbox=true` and `com.apple.security.device.camera=true`.
- Final upload command: `DEVELOPMENT_TEAM=9MXC88C783 APP_STORE_DESTINATION=upload rtk scripts/release_app_store.sh`.
- Final upload result: `Uploaded Sloucher AppStore`, `EXPORT SUCCEEDED`; package is processing in App Store Connect.

App Store export command:

```bash
DEVELOPMENT_TEAM="9MXC88C783" \
rtk scripts/release_app_store.sh
```

App Store upload command after the App Store Connect app exists:

```bash
DEVELOPMENT_TEAM="9MXC88C783" \
APP_STORE_DESTINATION=upload \
rtk scripts/release_app_store.sh
```

Manual Xcode archive path:

- Select scheme `Sloucher AppStore`, not `Sloucher`.
- Product > Archive.
- Distribute through Organizer after the archive completes.

## App Store Screenshots

Screenshots are generated, not captured from the real camera, so no private room or webcam imagery is included.

Key files:

- `scripts/generate_app_store_screenshots.swift`
- `docs/app-store/screenshots/01-good-posture.png`
- `docs/app-store/screenshots/02-calibrate-baseline.png`
- `docs/app-store/screenshots/03-nudge-when-slouching.png`
- `docs/app-store/screenshots/04-private-on-device.png`

Current screenshot size:

- `2560 x 1600`

Regenerate:

```bash
rtk swift scripts/generate_app_store_screenshots.swift
```

Verify:

```bash
rtk sips -g pixelWidth -g pixelHeight docs/app-store/screenshots/*.png
rtk file docs/app-store/screenshots/*.png
```

## Build Verification

These passed during publishing prep:

```bash
rtk xcodebuild -project Sloucher.xcodeproj -scheme Sloucher -configuration Debug -derivedDataPath DerivedData build
rtk xcodebuild -project Sloucher.xcodeproj -scheme Sloucher -configuration Debug -derivedDataPath DerivedData analyze
rtk xcodebuild -project Sloucher.xcodeproj -scheme Sloucher -configuration Release -derivedDataPath DerivedData/Release CODE_SIGNING_ALLOWED=NO build
```

App Store-style local build with sandbox entitlements also passed:

```bash
rtk xcodebuild -project Sloucher.xcodeproj -scheme Sloucher -configuration Release -derivedDataPath DerivedData/AppStoreLocal build CODE_SIGN_ENTITLEMENTS=Sloucher/AppStore.entitlements CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO ENABLE_HARDENED_RUNTIME=YES
```

Confirmed on the App Store-style local artifact:

- Sandbox entitlement present.
- Camera entitlement present.
- No debug `get-task-allow`.
- `PrivacyInfo.xcprivacy` bundled.

## Product Logic Note

No detector, calibration, posture-decision, or nudge product logic was intentionally changed for publishing, except that forensic camera frame/raw-plane capture is gated to debug builds only for shipped privacy.
