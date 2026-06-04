# Direct Download Release

Sloucher ships as a signed and notarized disk image for direct download.

## One-time setup

1. Join the Apple Developer Program.
2. Confirm the Apple team ID. For this project, use `9MXC88C783`.
3. Install a `Developer ID Application` certificate in Keychain Access, or use Xcode-managed automatic Developer ID signing.
4. Create a notarization keychain profile if you want the shell script to notarize both the app and `.dmg`:

```bash
rtk xcrun notarytool store-credentials sloucher-notary --apple-id nitin.sngwn@gmail.com --team-id 9MXC88C783
```

Confirm the signing identity is installed:

```bash
rtk security find-identity -v -p codesigning
```

## Build, Sign, Notarize

If a local `Developer ID Application` private key and `notarytool` profile are installed, run from the repository root:

```bash
DEVELOPER_ID_APPLICATION="Developer ID Application: Nitin Sangwan (9MXC88C783)" \
DEVELOPMENT_TEAM="9MXC88C783" \
NOTARY_PROFILE="sloucher-notary" \
rtk scripts/release_direct_download.sh
```

The script creates a Release archive, exports a Developer ID signed app, notarizes and staples the app, builds a `.dmg`, signs/notarizes/staples the `.dmg`, and writes the final artifact to `dist/`.

If the Developer ID private key is Xcode-managed rather than visible in `rtk security find-identity -v -p codesigning`, use the Xcode-managed script instead:

```bash
DEVELOPMENT_TEAM="9MXC88C783" \
rtk scripts/release_direct_xcode_managed.sh
```

That script archives with automatic signing, exports a Developer ID app, uploads the archive to Apple notarization through Xcode account services, polls `stapler` until the app ticket is available, and writes a stapled app `.zip` plus a convenience `.dmg` to `dist/`.

For the current Xcode-managed release, `dist/Sloucher-0.1.0.dmg` is the verified shippable artifact. It is signed, notarized, stapled, and passes Gatekeeper assessment with `--context context:primary-signature`. The app inside also passes stapler validation and `spctl --type execute`.

Current manual poll command for an already uploaded Xcode-managed archive:

```bash
rtk xcrun stapler staple build/auto-developer-id-team9/export-auto/Sloucher.app
```

## QA Checklist

- Install from the final `.dmg` by dragging `Sloucher.app` into `/Applications`.
- Launch from `/Applications`, not from Xcode or DerivedData.
- Confirm macOS opens it without Gatekeeper warnings.
- Confirm the menu-bar item appears as `Sloucher` and no Dock icon appears.
- On a clean first run, confirm the `Set Up Sloucher` window appears when camera access is missing.
- Click `Enable Camera`, allow camera access, and confirm the setup window closes after camera access is granted.
- Confirm notification permission is optional: no notification prompt appears until `Enable Notifications` or `Test nudge` is clicked.
- Calibrate while sitting upright.
- Confirm `Test nudge` works for notification, sound, and screen glow. If notifications were denied, confirm sound and screen glow still work and the UI offers Settings.
- Confirm Pause, Snooze, Launch at Login, and Quit.
- Confirm no static UI labels are truncated in the menu-bar window.
- Confirm `rtk spctl --assess --type open --context context:primary-signature --verbose=4 dist/Sloucher-*.dmg` passes.

## Notes

- Release builds enable hardened runtime.
- Direct-download releases require a `Developer ID Application` identity; an `Apple Development` identity is not enough for public distribution.
- `TC2S48VYN6` is not the team ID for release commands; use `9MXC88C783`.
- Keep Sparkle or another updater as a later milestone. The first release can be a normal notarized `.dmg`.
