# Sloucher — Inspector Panel: Developer Handoff

Implementation-ready spec for §9 of `SPEC.md` (the live inspector). The interactive mockup is the source of truth for look & behavior; this doc fixes the numbers. **All mockup CSS px map 1:1 to macOS points.**

---

## Overview

Clicking the Sloucher menu-bar icon opens the inspector: a live webcam preview with a pose-skeleton overlay, the raw computed figures (with thresholds), a derived 0–100 score, and a neck-distance sparkline. Purpose is transparency + tuning. The score is **display-only**; the nudge trigger stays on the `SPEC.md §3` state machine.

**Surface:** `NSPopover` (transient, `.applicationDefined` behavior) anchored to the `NSStatusItem` button — or `MenuBarExtra(..., style: .window) { InspectorView() }` (macOS 13+). Content size **fixed 680 × ~600 pt**, not resizable for MVP. (If you prefer a standalone window, swap the host; the view is identical.)

---

## Layout

Single root with `padding: 14`. Inner content width = 652 pt.

```
┌────────────────────────────────────────────── 680 ──────────────────────────────────────────────┐
│ [◎ icon] Sloucher  — live view                              [ state badge ]   [ ⟳ score ring 56 ] │  header, mb 12
│ ┌───────────────── left 1.2fr ─────────────────┐ ┌──────────── right 1fr ───────────┐            │
│ │  WEBCAM PREVIEW   (canvas, h 250)             │ │ Neck distance  ……  0.62  −12%    │            │
│ │   • corner brackets  • faint grid             │ │ [▰▰▰▰▰▱▱]  base△  thr△            │            │
│ │   • skeleton + dashed "calibrated head line"  │ │ Lean / closeness ……  1.00×       │            │
│ │   • banner (top, slouch only)                 │ │ [▰▰▰▱▱▱▱]  base△  thr△            │  grid gap 12│
│ │   • nudge chips (bottom-right)                │ │ ┌Conf┐┌Shldr┐                    │            │
│ │                                               │ │ ┌Smpl┐┌InPos┐  (2×2, gap 8)      │            │
│ └───────────────────────────────────────────────┘ └──────────────────────────────────┘            │
│ ┌ sparkline card (h 70 canvas, pad 8×10) ─ "neck distance vs slouch threshold" ── "last 12 s" ──┐  │  mt 12
│ [ Calibrate ]   Sensitivity  [────●────]  Normal · drop 10%                                        │  mt 12
└───────────────────────────────────────────────────────────────────────────────────────────────────┘
```

Grid: `columns 1.2fr / 1fr`, `gap 12` → left ≈ 349 pt, right ≈ 291 pt. No responsive breakpoints (fixed popover). The "Header states (reference)" strip in the mockup is documentation only — **not** shipped in the product.

---

## Design tokens

Brand colors are **fixed hex** (identical in light/dark — they sit on the dark video or as semantic accents). Chrome uses system materials so it adapts automatically.

| Token | Light | Dark | Usage |
|---|---|---|---|
| `panel.bg` | popover material | popover material | root background (don't custom-fill) |
| `card.fill` | `Color(nsColor:.controlBackgroundColor)` | same | stat cards, sparkline card |
| `bar.track` | `Color.secondary.opacity(0.15)` | same | metric bar background |
| `text.primary/secondary/tertiary` | `.primary/.secondary/.tertiary` | same | labels, values |
| `good` (teal) | `#1D9E75` fill · `#0F6E56` text | same | good state, in-threshold bar fill, score ≥80 |
| `slouch` (coral) | `#D85A30` fill · `#993C1D` text | same | slouch state, over-threshold fill, score <60, banner |
| `warn` (amber) | `#EF9F27` fill · `#854F0B` text | same | score 60–79 ring band |
| `info` (blue) | `#378ADD` fill · `#185FA5` text | same | calibrating badge |
| `neutral` (gray) | `.secondary` | same | "can't see you" badge |
| `video.bg` | `#15171A` | `#15171A` | webcam canvas backdrop |
| `skeleton.good / .bad` | `#5DCAA5` / `#F0997B` | same | pose overlay stroke |
| `overlay.baseline` | `white @ 35%` | same | dashed calibrated head line |
| `overlay.grid` | `white @ 5%` | same | preview grid |
| `overlay.bracket` | `white @ 45%` (→ coral when slouch) | same | viewfinder corners |

**Spacing:** root pad 14 · section gaps 12 · stat-card grid gap 8 · card inner pad 8×10 · radius: cards/preview 10, bars 6, badge pill 999, app-icon tile 7.

**Typography (SF / system):** title 15/medium · score number 16/medium **monospaced digits** · metric values 13–14/medium **monospaced digits** · labels 12/regular secondary · banner 12/regular. Sentence case throughout. Never < 11 pt.

---

## Components

| Component | Props / inputs | Notes |
|---|---|---|
| `ScoreRing` | `score: Int?` (nil while calibrating), `band: Color` | 56 pt Ø, 6 pt stroke, track + arc, `strokeLinecap .round`, start at top (−90°). Center label = number or "—". Arc length = `score/100`. |
| `StateBadge` | `state: PostureState` | pill, icon + text. See state matrix. |
| `WebcamPreview` | `frame: CVPixelBuffer`, `pose: PoseFrame`, `baselineHeadY`, `state` | mirrored horizontally. Hosts overlays below. |
| ↳ `SkeletonOverlay` | joints (nose, eyes, shoulders) | nodes + neck line + shoulder line; stroke = good/bad color. |
| ↳ `BaselineLine` | `baselineHeadY` | full-width dashed line at the calibrated nose height + label "calibrated head line" (11 pt). |
| ↳ `CornerBrackets` | `slouching: Bool` | 4 L-marks, 22 pt arms, 10 pt inset; white→coral. |
| ↳ `Banner` | `text` | top inset 8, coral bg, white text; visible only when `state == .slouching`. |
| ↳ `NudgeIndicators` | `firing: Bool`, enabled set {notif, sound, overlay} | 3 chips 28×28; light coral when firing. |
| `MetricBar` | `value, baseline, threshold, domain, invert` | fill width = `pos(value)`; baseline tick (secondary), threshold tick (coral); fill teal if inside / coral if over. neckDistance: domain `[D0·0.7, D0·1.06]`, slouch when `< threshold` (left). lean: domain `[0.9, 1.3]`, slouch when `> threshold` (right). |
| `StatCard` | `label, value` | confidence, shoulder width (px), sampling, in-posture time. |
| `Sparkline` | `samples:[(t,value)]`, `threshold`, `baseline` | window 12 s; baseline gridline; dashed coral threshold line; trace teal/coral per-sample; shade region under threshold. Redraw per frame. |
| `CalibrateButton` | action | triggers 2 s capture. |
| `SensitivitySlider` | `binding: dropThresh` | 3 discrete stops. |

---

## States & interactions

| Element | State / trigger | Behavior |
|---|---|---|
| `StateBadge` | Good | `good` colors, `checkmark.circle.fill`, "Good posture" |
| | Slouching | `slouch` colors, `exclamationmark.triangle.fill`, "Slouching" + banner + nudges |
| | Calibrating | `info` colors, spinner (`ProgressView`/`arrow.triangle.2.circlepath`), "Calibrating…", ring shows "—" |
| | Can't see you | `neutral`, `eye.slash`, no nudges, metrics dimmed (opacity 0.4) |
| `ScoreRing` | value change | arc + center number animate to new score (see motion) |
| `MetricBar` (neck) | `neckDistance < D0·(1−dropThresh)` | fill → coral; `% vs baseline` label → coral |
| `MetricBar` (lean) | `closeness > 1.18` | fill → coral |
| `CalibrateButton` | click | disable button; set `state=.calibrating`; capture ~30 frames / 2 s; store median `D0,W0`; clear sparkline; re-enable; `state=.good` |
| `SensitivitySlider` | drag | Strict 0.06 · Normal 0.10 · Relaxed 0.14 → updates `dropThresh`, moves threshold tick + sparkline line live; persist to `Settings` |
| `WebcamPreview` | every sample | mirror; redraw skeleton/baseline; banner per state |
| `NudgeIndicators` | slouch onset | enabled chips light coral; clear on recovery |

**Derived score (display-only)** — restated from `SPEC.md §9`:
```
dropFrac = max(0, (D0 − neckDistance) / D0)
leanFrac = max(0, closeness − 1)
penalty  = 100 · max(dropFrac / 0.30, 0.6 · leanFrac / 0.25)
scoreRaw = clamp(0, 100, 100 − penalty)
scoreDisplayed += α · (scoreRaw − scoreDisplayed)      // EMA, α = 1 − exp(−dt/τ), τ = 0.4 s
band: ≥80 good · 60–79 warn · <60 slouch
```

---

## Animation / motion

| Element | Trigger | Animation | Duration | Easing |
|---|---|---|---|---|
| Score ring arc + number | score change | arc sweep + number tween | 200 ms | ease-out |
| Metric bar fill | value change | width | 120 ms | linear |
| State badge | state change | color crossfade | 200 ms | ease-in-out |
| Skeleton stroke | good↔slouch | color | 200 ms | ease-in-out |
| Banner | slouch on/off | slide+fade from top | 150 ms | ease-out |
| Nudge chips | firing on/off | bg/border | 200 ms | ease-in-out |
| Sparkline | per sample | none (immediate redraw) | — | — |

Honor **Reduce Motion**: skip arc sweep / banner slide; snap to final state.

---

## Edge cases

- **Camera permission not granted / no camera:** preview replaced by a centered message + "Open System Settings" button (`AVCaptureDevice.requestAccess`). Metrics blank, score hidden.
- **Not yet calibrated (first run):** preview + skeleton show, but bars/score show a "Calibrate to start" placeholder; no nudges until `D0` exists.
- **Low joint confidence > 3 s** (left desk, dark, shoulders cropped): `state = .cantSeeYou`; ring "—"; metrics dim; no nudges.
- **Multiple people in frame:** pick the torso with highest summed joint confidence (most-centered/closest); ignore others.
- **Calibrating while slouched:** allowed (user-controlled). Show one-line hint "Sit upright, then Calibrate" above the button.
- **In-posture time ≥ 60 s:** format `m:ss`.
- **Long localized labels:** labels may wrap to 2 lines; cards grow vertically — don't truncate values.
- **Dark/light mode:** all chrome via system colors; video area stays dark by design.

---

## Accessibility

- Focus order: Calibrate → Sensitivity slider → (close). Both keyboard-operable; slider arrow keys step the 3 stops.
- VoiceOver: ScoreRing label "Posture score 82 of 100, good"; StateBadge announces on change (`NSAccessibility.post(... .announcementRequested)`); WebcamPreview labeled "Live posture preview"; bars expose value + threshold as accessibility value.
- Never color-only: every state has icon + text; bars carry numeric value + ticks.
- Respect Reduce Motion and Increase Contrast.

---

## Data bindings

`@Observable final class PostureAnalyzer` publishes — inspector is a pure subscriber, no new inference:

| Property | Type | Source |
|---|---|---|
| `neckDistance` | Double | §3 primary metric |
| `closeness` | Double | §3 secondary |
| `shoulderWidthPx` | Int | scale unit |
| `confidence` | Double | min(nose, shoulder) joint conf |
| `state` | enum `good/slouching/calibrating/cantSeeYou` | §3 state machine |
| `baselineD0`, `baselineW0` | Double | Calibrator → UserDefaults |
| `dropThresh` | Double | Settings (slider) |
| `score` | Int | derived (formula above) |
| `inStateSeconds` | Double | timer since last transition |
| `latestFrame` | CVPixelBuffer | capture (preview only while panel visible) |
| `pose` | joints | Vision request output |

**Power (ties to `SPEC.md §5`):** raise capture/preview to 15–30 fps only while the popover is visible (`NSPopover` did-show / will-close, or `scenePhase`); on close, revert to 1.5 s sampling and apply all idle/sleep stop logic. No always-on preview.

---

## SwiftUI structure (skeleton)

```swift
struct InspectorView: View {
  @Bindable var analyzer: PostureAnalyzer
  var body: some View {
    VStack(spacing: 12) {
      Header(score: analyzer.score, state: analyzer.state)        // title • badge • ScoreRing(56)
      HStack(alignment: .top, spacing: 12) {
        WebcamPreview(frame: analyzer.latestFrame, pose: analyzer.pose,
                      baselineHeadY: analyzer.baselineHeadY, state: analyzer.state)
          .frame(height: 250).clipShape(.rect(cornerRadius: 10))
        VStack(spacing: 14) {
          MetricBar(.neckDistance, value: analyzer.neckDistance,
                    baseline: analyzer.baselineD0, threshold: analyzer.slouchThreshold)
          MetricBar(.lean, value: analyzer.closeness, baseline: 1.0, threshold: 1.18)
          StatGrid(analyzer)                                        // 2×2 StatCards
        }
      }
      SparklineCard(samples: analyzer.history, threshold: analyzer.slouchThreshold,
                    baseline: analyzer.baselineD0).frame(height: 70)
      HStack(spacing: 12) {
        Button("Calibrate", systemImage: "scope") { analyzer.calibrate() }
        Text("Sensitivity").foregroundStyle(.secondary)
        Slider(value: $analyzer.sensitivityStop, in: 0...2, step: 1)
        Text(analyzer.sensitivityLabel).monospacedDigit()
      }
    }
    .padding(14).frame(width: 680)
  }
}
```

**SF Symbols:** good `checkmark.circle.fill` · slouch `exclamationmark.triangle.fill` · calibrating `arrow.triangle.2.circlepath` (or `ProgressView`) · can't-see `eye.slash` · nudges `bell.fill` / `speaker.wave.2.fill` / `rectangle.dashed` · Calibrate `scope` · app/menu-bar glyph `figure.seated.side`.
