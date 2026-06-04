# Mac App Store Release

This is the App Store path for Sloucher. It is separate from the direct-download Developer ID path because Mac App Store submissions require App Sandbox.

## Apple Requirements Covered

- App Sandbox is enabled for App Store archives with `Sloucher/AppStore.entitlements`.
- Camera access is declared with `com.apple.security.device.camera`.
- The existing generated Info.plist includes `NSCameraUsageDescription`.
- The bundled privacy manifest declares app-private `UserDefaults` access with required reason `CA92.1`.
- Release builds keep forensic camera-frame capture out of the binary path used by shipped builds.

## One-time Setup

1. Apple Developer Program enrollment is complete.
2. Apple ID is available to Xcode for signing/upload.
3. App Store Connect app record exists with bundle ID `app.sloucher.Sloucher`.
4. Confirm the target's category is Healthcare & Fitness.
5. Prepare a public privacy policy URL. The local summary is in `PRIVACY.md`, but App Store Connect expects a URL.

Optional command-line authentication:

```bash
rtk xcodebuild -help
```

Use the `-authenticationKeyPath`, `-authenticationKeyID`, and `-authenticationKeyIssuerID` options if you prefer App Store Connect API-key based uploads.

## Build and Export

Manual Xcode path:

- Select scheme `Sloucher AppStore`.
- Archive with Product > Archive.
- Distribute through Organizer.

Export without upload:

```bash
DEVELOPMENT_TEAM="9MXC88C783" \
rtk scripts/release_app_store.sh
```

Export and upload to App Store Connect:

```bash
DEVELOPMENT_TEAM="9MXC88C783" \
APP_STORE_DESTINATION=upload \
rtk scripts/release_app_store.sh
```

With an App Store Connect API key:

```bash
DEVELOPMENT_TEAM="9MXC88C783" \
APP_STORE_DESTINATION=upload \
AUTHENTICATION_KEY_PATH="/path/to/AuthKey_KEYID.p8" \
AUTHENTICATION_KEY_ID="KEYID" \
AUTHENTICATION_KEY_ISSUER_ID="ISSUERID" \
rtk scripts/release_app_store.sh
```

## App Store Connect Metadata Draft

Name: Sloucher

Subtitle: Menu-bar posture nudges

Category: Healthcare & Fitness

Description:

Sloucher is a quiet macOS menu-bar posture coach. Calibrate once while sitting upright, then Sloucher watches for posture changes from your own baseline and nudges you when you start to slump.

The app runs on-device, uses the Mac camera only for local posture measurement, and does not upload camera frames or posture data.

Keywords:

posture, ergonomics, desk, menu bar, health, focus, reminder

Privacy summary:

Sloucher processes camera frames locally with Apple's Vision framework. It stores local settings and calibration values on this Mac. It does not collect, upload, sell, or track user data.

## Review Notes Draft

Sloucher is a menu-bar-only app with no Dock icon. On first launch, the `Set Up Sloucher` window appears if camera access is missing. Click `Enable Camera`, grant camera access, then click the `Sloucher` menu-bar item, sit upright with head and shoulders visible, and click `Calibrate`. Notifications are optional; use `Enable Notifications` or `Test nudge` to request notification banners. `Test nudge` also verifies sound and screen glow without needing to slouch.

## Screenshots

Generated screenshots live in `docs/app-store/screenshots/`:

- `01-good-posture.png`
- `02-calibrate-baseline.png`
- `03-nudge-when-slouching.png`
- `04-private-on-device.png`

Regenerate them with:

```bash
rtk swift scripts/generate_app_store_screenshots.swift
```

## QA Checklist

- Build and export with `scripts/release_app_store.sh`.
- If using Xcode manually, archive with scheme `Sloucher AppStore`, not `Sloucher`.
- Confirm the archived app is sandboxed and has the camera entitlement.
- Launch a locally exported build if Xcode provides one for validation.
- Confirm first-run `Set Up Sloucher`, required camera permission, optional notification permission, calibration, `Test nudge`, Pause, Snooze, Launch at Login, and Quit.
- Confirm no static UI labels are truncated.
- Upload the generated macOS screenshots from `docs/app-store/screenshots/`.
- Complete App Privacy Details in App Store Connect to match `PRIVACY.md` and `PrivacyInfo.xcprivacy`.

## Current State

The sandboxed package uploaded successfully with `scripts/release_app_store.sh`. Wait for App Store Connect build processing, then attach the build to the app version and complete listing metadata/privacy/submission.
