# Sloucher

Native macOS menu-bar posture coach built from `SPEC.md`.

## Run

Open `Sloucher.xcodeproj` in Xcode, select the `Sloucher` scheme, and run it. The app has no Dock icon; it appears in the menu bar.

On first launch, allow camera and notification permissions, then click **Calibrate** while sitting upright.

## Direct Download Release

Direct-download distribution uses a signed, notarized `.dmg`. See `docs/DIRECT_DISTRIBUTION.md` for the Developer ID, notarization, packaging, and QA steps.

Sloucher processes camera frames on-device. See `PRIVACY.md` for the privacy summary.

## Mac App Store Release

The Mac App Store path uses a sandboxed archive with camera entitlement and a bundled privacy manifest. See `docs/APP_STORE.md`.
