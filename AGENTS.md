@/Users/sks/.codex/RTK.md

# Sloucher Handoff

Native macOS menu-bar posture coach from `SPEC.md`.

## Current State
- Xcode project exists at `Sloucher.xcodeproj`.
- App code is under `Sloucher/App`, `Sloucher/Models`, and `Sloucher/Services`.
- Build/run target is Apple Silicon macOS 13+.
- Use an AppKit `NSStatusItem`; visible menu-bar label is text: `Sloucher`.
- Clicking the menu-bar label opens the main SwiftUI view in a regular `NSWindow`, not an auto-dismissing popover/menu window.
- Current running/debug app path usually:
  `DerivedData/Build/Products/Debug/Sloucher.app`.

## Verification Commands
- Build: `rtk xcodebuild -project Sloucher.xcodeproj -scheme Sloucher -configuration Debug -derivedDataPath DerivedData build`
- Analyze: `rtk xcodebuild -project Sloucher.xcodeproj -scheme Sloucher -configuration Debug -derivedDataPath DerivedData analyze`
- Launch: `rtk open -n DerivedData/Build/Products/Debug/Sloucher.app`
- Runtime state: `rtk defaults read app.sloucher.Sloucher`
- Process: `rtk pgrep -fl Sloucher`

## Important Runtime Context
- Camera permissions are already in play; user saw camera light on.
- Notification permission may still need System Settings if alerts do not appear.
- Diagnostics are written to `UserDefaults` under `runtime.*` keys.

## Collaboration Guardrails
- Before changing detector, calibration, posture-decision, or other product logic, first state the observed evidence, the suspected bug, and the proposed code change, then wait for user confirmation.
- When making logical code changes, add concise inline comments explaining why the logic exists, especially where the behavior is non-obvious or based on prior debugging.
- Proactively log important decisions without waiting to be asked: state the evidence, the decision, the reason, and any rejected alternative that matters for future debugging.
- Always test changes before handing them back. Build/analyze is the floor; for GUI or runtime behavior changes, also launch the built app and verify the changed behavior directly when the local environment allows it.
- For macOS windowing, permission, app-activation, Dock/menu-bar, or lifecycle changes, do not implement until the expected state machine and acceptance criteria are written down. Cover launch, click menu-bar item, focus loss, close/reopen, permission missing/denied/granted, and quit behavior.
- Do not treat a narrow runtime check as sufficient. Before handing back GUI/lifecycle work, run a path-based test matrix that covers the user's normal path, recovery paths, and failure paths. State exactly which paths were tested and what was observed.
- Preserve the product contract unless the user explicitly changes it: Sloucher is menu-bar-first, should not show a Dock icon during normal monitoring, and every blocking permission state must have a visible way to recover.
- Prefer managed ownership over scattered windows. If a secondary window is needed, define who owns it, when it opens, when it closes, how it is reopened, and how it interacts with the main window before coding.

## Detector Notes
- Original body-pose-only detector failed in laptop-camera framing.
- Body baselines with shoulder width `< 0.12` are invalid because Vision can hallucinate shoulders nearly on top of each other.

## UX Notes
- User is not a macOS/physio expert; answer in product terms.
- Do not ship truncated static UI text. Size or wrap the layout around the full labels, and add hover help/tooltips for any control or readout that could become width-constrained.
- If alerts fail, first separate detector vs nudge with menu item `Test nudge`.
- If calibration fails, check whether `runtime.status` is stuck at `calibrating`; timeout logic should recover now.
