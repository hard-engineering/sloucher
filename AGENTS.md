@/Users/sks/.codex/RTK.md

# Sloucher Handoff

Native macOS menu-bar posture coach from `SPEC.md`.

## Current State
- Xcode project exists at `Sloucher.xcodeproj`.
- App code is under `Sloucher/App`, `Sloucher/Models`, and `Sloucher/Services`.
- Build/run target is Apple Silicon macOS 13+.
- Use `MenuBarExtra`; visible menu-bar label is text: `Sloucher`.
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

## Detector Notes
- Original body-pose-only detector failed in laptop-camera framing.
- Body baselines with shoulder width `< 0.12` are invalid because Vision can hallucinate shoulders nearly on top of each other.

## UX Notes
- User is not a macOS/physio expert; answer in product terms.
- Do not ship truncated static UI text. Size or wrap the layout around the full labels, and add hover help/tooltips for any control or readout that could become width-constrained.
- If alerts fail, first separate detector vs nudge with menu item `Test nudge`.
- If calibration fails, check whether `runtime.status` is stuck at `calibrating`; timeout logic should recover now.
