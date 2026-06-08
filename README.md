# Sloucher

Native macOS menu-bar posture coach built from `SPEC.md`. On the Mac App Store it's listed as **Sloucher - Fix your Hump**.

## Run

Open `Sloucher.xcodeproj` in Xcode, select the `Sloucher` scheme, and run it. The app has no Dock icon; it appears in the menu bar.

On first launch, the **Set Up Sloucher** window asks for camera access (required for posture detection). Grant it, then click the `Sloucher` menu-bar item and press **Calibrate** while sitting upright. Notifications are optional - if they're off, nudges still work via sound and a soft screen glow.

## Releases

- **Mac App Store** - sandboxed archive with the camera entitlement and a bundled privacy manifest. v0.1.0 has been submitted for review. Build and upload steps are in `docs/APP_STORE.md`.
- **Direct download** - signed, notarized `.dmg` via Developer ID. Steps in `docs/DIRECT_DISTRIBUTION.md`.

## Privacy

Sloucher processes camera frames on-device with Apple's Vision framework and uploads nothing. See `PRIVACY.md` for the summary, or the public policy at https://hard-engineering.github.io/sloucher-site/privacy.html.
