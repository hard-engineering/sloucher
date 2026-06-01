# Sloucher — Product → Implementation Spec

A personal, always-on, power-efficient posture coach for macOS. Inspired by SuperShrimp, stripped to the one job that solves *your* problem.

**Constraints that shaped this spec (your answers):**
- **Target: Apple Silicon, macOS 13+** (newer is fine). No Intel, no older-macOS support burden.
- **Always-on + power-efficient** → native macOS, not browser/Electron. Detection is hardware-accelerated (Neural Engine / GPU) via the Vision framework, sampled slowly.
- **MVP = "just alert me when I slouch."** No score, no analytics, no gamification, no payments, no cross-platform.
- **Nudge = desktop notification + sound + on-screen overlay.**
- **No browser prototype** — a webcam page won't behave like the native Vision pipeline (different model, coords, power profile), so it wouldn't transfer. Build native directly.

---

## 1. Product definition

**Problem.** You slouch while working and don't notice until your back/neck complains. You want a quiet background watcher that taps you on the shoulder the moment you slump, and otherwise stays out of the way and off your battery.

**The one job.** Detect when your sitting posture degrades from your own calibrated baseline, and nudge you to correct it — immediately, then occasionally if you ignore it.

**Definition of done (MVP).** You launch it, calibrate once sitting upright, minimize it, and forget it's there. When you slouch for more than a few seconds, you get a notification + chime + a red glow at the screen edge. When you sit up, the glow clears. It costs negligible battery and never sends a pixel off your machine.

**Non-goals (explicitly out for v1).**
- Standalone posture-score UI, analytics, trends, history. *(§9's inspector shows a live **derived** score while open — but nothing is logged, stored, or trended.)*
- Gamification (XP, levels, leaderboard).
- Windows/Linux, multi-device licensing, payments, accounts.
- Cloud anything. 100% on-device, offline.
- Auto-pause during video calls, stand/stretch reminders, standing-desk profiles. *(v2 candidates.)*

---

## 2. Core UX loop

```
 ┌─────────────┐   sit upright,    ┌────────────┐   slouch > N sec    ┌──────────┐
 │  CALIBRATE  │ ──── click ────▶  │  MONITOR   │ ─────────────────▶  │  NUDGE   │
 │ (once, 2 s) │                   │ (silent,   │                     │ notif +  │
 └─────────────┘                   │  low-power)│ ◀───── sit up ───── │ sound +  │
        ▲                          └────────────┘    (clears glow)    │ overlay  │
        │ "Recalibrate" anytime          ▲                            └──────────┘
        └────────────────────────────────┘  pause when away / asleep / on call (manual)
```

- **Menu-bar only.** A shrimp/spine glyph in the menu bar; no Dock icon, no window. Click → small menu: status line (Good / Slouching / Paused / Can't see you), **Calibrate**, sensitivity slider, nudge toggles, Pause/Snooze, Launch at login, Quit.
- **Calibrate.** "Sit how you *want* to sit, then click Calibrate." Captures a 2-second baseline. Re-run anytime (new chair, new desk height).
- **Monitor.** Runs silently. Status glyph reflects state at a glance.
- **Nudge.** On slouch onset: notification + one chime + persistent edge glow. If still slouching after a few minutes, re-notify (no repeated chimes). On recovery: glow clears silently.
- **Pause/Snooze.** Manual "Snooze 20 min" and "Pause" for calls/meetings.

---

## 3. Slouch-detection algorithm

This is the part that has to *earn* "good enough," so it's evidence-led — see **Evidence & validation** at the end of this section. Camera placement drives accuracy, so two modes:

**Default — built-in front camera (zero setup).** Catches the dominant desk failure mode: sinking/slumping down and leaning toward the screen. Standard consumer-app method (calibrate + deviation). It does *not* reliably catch a pure forward-head "chin poke" with no vertical drop — that motion runs along the camera's depth axis, which a single front camera barely sees.

**Optional Pro — side-placed camera** (Continuity Camera / iPhone on a stand to your side). Enables the clinical-style neck-inclination angle that approximates the gold-standard craniovertebral angle. Most accurate; needs a camera to your side. Documented here, not required for MVP.

### Front-camera signals (default mode)
Joints (Vision body pose): `nose`/`leftEye`/`rightEye`, `leftShoulder`/`rightShoulder`. Normalized by shoulder width so distance-to-camera and resolution don't matter.

| Metric | Formula | Catches | Reliability |
|---|---|---|---|
| `shoulderWidth` (scale unit) | dist(L_shoulder, R_shoulder) | normalizer + lean proxy | high |
| `neckDistance` *(primary)* | (shoulderMidY − noseY) / shoulderWidth | head sinking toward shoulders (the slump) | high |
| `closeness` *(secondary)* | shoulderWidth / W0 | leaning in / forward translation | low — noisy depth proxy |
| `shoulderTilt` *(optional)* | shoulder-line angle vs horizontal | uneven/rounded shoulders | medium |

`neckDistance` is the workhorse — the exact signal shipping front-cam detectors use (nose-to-shoulder vertical distance vs baseline). `closeness` is the only front-cam handle on forward translation, so it's deliberately a weak supporting signal, never a sole trigger.

*(Vision normalized coords are origin-bottom-left, y-up — sign-check `neckDistance` in implementation.)*

### Optional Pro signals (side mode)
| Metric | Formula | Good threshold |
|---|---|---|
| `neckInclination` | angle(shoulder→ear) from vertical | < ~40° (tune from baseline) |
| `torsoInclination` | angle(hip→shoulder) from vertical | < ~10° |
| `alignmentOffset` | horizontal dist(L_shoulder, R_shoulder) | small ⇒ camera correctly side-on |

Mirrors the most robust open-source webcam method and directly approximates the craniovertebral angle.

### Calibration (both modes)
Sit how you *want* to sit, click **Calibrate**. Capture ~30 frames over 2 s, drop low-confidence frames, store the **median** baseline (front: `neckDistance` `D0`, `shoulderWidth` `W0`; side: `neckInclination` `N0`) in `UserDefaults`. Median-over-window is the standard calibration trick and rejects transient outliers.

### Decision (front mode — state machine with hysteresis)
```
SLOUCH when, sustained ≥ holdSeconds (default 5s):
    neckDistance < D0 * (1 − dropThresh)      // head sank toward shoulders
    OR closeness > closenessThresh            // leaned in (weak signal)

RECOVER (→ GOOD) when, sustained ≥ recoverSeconds (default 3s):
    neckDistance ≥ D0 * (1 − dropThresh*0.6)  // back inside hysteresis band
    AND closeness ≤ closenessThresh*0.97
```

**Defaults (evidence-aligned starting points, tune in testing):** `dropThresh = 0.10`, `closenessThresh = 1.18`, `holdSeconds = 5`, `recoverSeconds = 3`.
**Sensitivity slider** maps to `dropThresh`: Strict 0.06 · Normal 0.10 · Relaxed 0.14. (A shipping detector uses 0.05/0.08/0.12 on the same signal; we run slightly tighter because shoulder-width normalization + the sustained-duration gate already cut false positives.)

**Guards against false positives:**
- Ignore frames where nose/shoulder joint confidence < 0.3.
- `holdSeconds` sustained requirement absorbs reaching for coffee, turning to talk, stretching.
- If joints unreliable for > a few seconds (left desk, too dark) → **"Can't see you"** state, no nudges.

### Evidence & validation
- **Clinical gold standard = craniovertebral angle (CVA):** angle from C7 to the ear's tragus vs horizontal; forward-head posture is commonly flagged below ~50° (literature cutoffs span 44–55°). Measured photogrammetrically from a **lateral (side)** photo. [1][2]
- **A single front camera is the weak axis** for forward-head posture, which is primarily a *sagittal-plane* deformation — even one-sided clinical photogrammetry is side-dependent, and a front camera can't directly observe forward translation. This is the honest limitation of the default mode. [3]
- **The default front-cam method is the de-facto consumer standard and good enough for *nudging*:** shipping detectors track nose-to-shoulder vertical distance vs a median-calibrated baseline with an adjustable threshold — the design used here. [4][5]
- **The robust upgrade is a side camera + neck-inclination angle**, which approximates CVA (a widely-cited implementation uses neck < 40° / torso < 10° from a side view, with a shoulder-overlap alignment check). Hence the optional Pro mode, on the same Vision pipeline. [5]
- **Heavier ML posture systems report 91–98% accuracy** but typically rely on side view, trained multi-class models, or depth sensors — more than a nudge-me MVP needs, and worse on power. [6][7]

**Verdict:** the front-cam MVP is standard practice and reliably catches slumping and leaning. It is *not* clinical-grade and has a known chin-poke blind spot. For gold-standard accuracy, add the optional side-camera mode — cheap on this pipeline since Vision already exposes the `ear` and `shoulder` joints it needs.

---

## 4. Architecture (native macOS)

**Stack:** Swift + SwiftUI, `AVFoundation` (capture), `Vision` (`VNDetectHumanBodyPoseRequest`, hardware-accelerated on Apple Silicon's Neural Engine/GPU), `UserNotifications`, `AppKit` (overlay window), `ServiceManagement` (launch at login). **Target: Apple Silicon, macOS 13+.**

```
SloucherApp (MenuBarExtra, .accessory activation → no Dock icon)
│
├── CameraController     AVCaptureSession, device pick, start/STOP, low preset, frame delegate
├── PostureAnalyzer      runs Vision request, extracts joints, computes metrics, state machine
├── Calibrator           2s baseline capture → UserDefaults (D0, W0)
├── Nudger               UNUserNotificationCenter + AVAudioPlayer + OverlayWindowController
├── OverlayWindowController  borderless transparent NSWindow per screen, click-through red glow
├── PowerManager         sleep/lock/idle observers → toggle capture + sample cadence
└── Settings (UserDefaults)  sensitivity, interval, nudge toggles, launch-at-login
```

**Permissions:** `NSCameraUsageDescription` (Info.plist) + `AVCaptureDevice.requestAccess`; `UNUserNotificationCenter.requestAuthorization`; launch-at-login via `SMAppService.mainApp.register()`.

---

## 5. Power-efficiency design (the defining constraint)

The whole reason to go native. Five levers, in order of impact:

1. **Sample slowly.** 1 frame every **1.5 s** (~0.67 Hz), not 30fps. Set a low capture preset; in the frame delegate, drop everything except the first frame past each interval. ~45× less inference than realtime.
2. **Hardware-accelerated Vision.** `VNDetectHumanBodyPoseRequest` runs on Apple Silicon's Neural Engine / GPU — far lower power than the WebGL/CPU inference a browser would use. One small request per sample.
3. **Motion-gate.** Keep a 32×24 grayscale thumbnail of the last processed frame; if mean abs-diff vs the new frame is below ε, **skip inference** (you're sitting still → most of the time). Detection still fires because *becoming* still in a slouch produced a change first.
4. **Fully stop the camera when not needed.** On display sleep, screen lock, or **idle > 60 s** (no input → you left the desk), call `session.stopRunning()` — drops to ~0 power and turns off the green light. Restart on wake/activity. Observers: `NSWorkspace` sleep/wake, `com.apple.screenIsLocked`, `CGEventSource.secondsSinceLastEventType`.
5. **Battery-aware cadence.** On battery or Low Power Mode, stretch interval to **3 s**.

Net effect: a couple of small ANE inferences every few seconds while you're actively at the desk, and *nothing* when you're not. Negligible battery, no fan.

---

## 6. Implementation milestones

| # | Milestone | Output |
|---|---|---|
| **M0** | Scaffold | Xcode project, `MenuBarExtra`, `.accessory` policy (no Dock icon), shrimp glyph. Runs. |
| **M1** | Capture | `AVCaptureSession`, device pick, low preset, throttled frame delegate, camera-permission flow. |
| **M2** | Detection | Feed frames to Vision; extract joints; compute `neckDistance`/`closeness`; log live values. |
| **M3** | Calibrate | "Calibrate" → 2s median baseline → `UserDefaults`. |
| **M4** | Slouch logic | Threshold + `holdSeconds` + hysteresis state machine. Menu status reflects GOOD/SLOUCH. |
| **M5** | Nudges | Notification + chime on onset; per-screen click-through red glow during slouch; clear on recovery. |
| **M6** | Power tuning | Motion gating, sleep/lock/idle pause (stop session), battery-aware cadence, sensitivity slider. |
| **M7** | Polish | Launch-at-login, Snooze/Pause, "Can't see you" state, settings persistence. |

**Threshold tuning happens in M2–M4**, against live on-screen metric values in the real native build — adjust `dropThresh` until SLOUCH fires exactly when *you* actually slump. (No browser prototype: a webcam page uses a different model, coordinate system, and power profile, so its tuning wouldn't transfer.)

---

## 7. Open decisions & risks

- **Distribution.** For personal use, **build & run from Xcode** (most stable camera-permission behavior) or archive an unsigned `.app` and right-click→Open. No Apple Developer account / notarization needed. *Decision: run from Xcode for MVP.*
- **Shoulders not in frame** (camera high/close). Body pose needs shoulders for the scale unit. Mitigation: if shoulders missing, fall back to face-only metric (eye-level + face size) or show "Can't see you." *Decision: require shoulders for MVP; add face fallback in v2 if it bites.*
- **Multi-monitor overlay.** Draw glow on all screens (cheap). *Decision: all screens.*
- **Camera contention with Zoom/Meet.** macOS allows multi-client capture, but you're usually upright on calls. *Decision: manual Pause for MVP; auto-pause-on-call in v2.*
- **Apple Silicon, macOS 13+** confirmed — Neural Engine gives the lowest-power path, and no Intel / older-OS code paths to carry.
- **Front-cam reliability** depends on lighting and consistent seating, and has a chin-poke blind spot (see §3 Evidence). Calibration + sustained-duration handle the common cases; the optional side-camera mode is the fix if accuracy matters. *Decision: ship front-cam MVP; add side mode only if the blind spot bites.*

---

## 8. v2 backlog (not now)
Posture score · daily/weekly trends · gamification · auto-pause on calls · stand/stretch timer · multiple calibration profiles · side-camera Pro mode (neck-inclination ≈ CVA) · Windows/Linux.

---

## 9. Live inspector panel (feature addendum)

**Purpose.** Click Sloucher in the menu bar → a live view showing the **webcam feed plus the exact figures being computed**, so you can see *why* it fires and tune it. Primary emphasis is the raw figures (transparent/diagnostic); a **derived 0–100 posture score** sits on top for an at-a-glance read. The score is **presentation-only — it never drives the nudge decision**, which stays on the §3 state machine. Borrows SuperShrimp's clean live-view conventions (webcam canvas, viewfinder corner brackets, faint grid, top coaching banner) and adds a transparent metrics layer on top.

**Layout** (see the interactive mockup built alongside this spec):
- **Header:** a **0–100 posture score** (large, color-banded: green ≥80 · amber 60–79 · coral <60) + state badge (Good / Slouching / Calibrating / Can't see you) + the three nudge icons (notification, sound, overlay) that light up when a nudge fires.
- **Webcam preview** (mirrored): pose skeleton overlay (nose, eyes, shoulders, neck line) + a **dashed "calibrated head line"** so the gap between your current head and the baseline is physically visible; corner brackets; faint grid; coaching banner ("Sit up — head dropped N%") when slouching.
- **Readouts:** `neckDistance` bar with current value, **baseline tick**, **threshold tick**, and "% vs baseline" (coral below threshold); `closeness`/lean bar vs 1.0 baseline + threshold tick; stat cards for joint confidence, shoulder width (px scale), sampling rate, and time-in-current-posture.
- **Sparkline:** `neckDistance` over the last ~12 s with the threshold line drawn and slouch regions shaded.
- **Controls:** Calibrate (re-capture baseline), sensitivity slider (Strict/Normal/Relaxed) that **visibly moves the threshold marker**, nudge toggles.

**Why this design.** The skeleton + dashed baseline makes the abstract `neckDistance` number concrete — you watch the head sink past the line. Threshold ticks (bars) and the threshold line (sparkline) make "how close am I to triggering" obvious and show exactly what the sensitivity slider changes. Surfacing confidence + a "Can't see you" state explains false negatives (poor light, shoulders out of frame).

**Implementation notes (native).**
- Reuse the **same `VNDetectHumanBodyPoseRequest` output** already feeding detection — the panel is a visualization layer, no new model.
- Render frames via `AVCaptureVideoPreviewLayer` (or draw the `CVPixelBuffer`); overlay skeleton + baseline with a `CAShapeLayer` / SwiftUI `Canvas`; mirror horizontally.
- Bars/sparkline = SwiftUI shapes bound to the live `PostureAnalyzer` state (`@Observable`/Combine). Calibrate calls the existing `Calibrator`; the slider writes `dropThresh` to `Settings`.
- **Derived score (display-only):** `dropFrac = max(0, (D0−neckDistance)/D0)`; `leanFrac = max(0, closeness−1)`; `penalty = 100 · max(dropFrac/0.30, 0.6·leanFrac/0.25)`; `score = clamp(0, 100, 100−penalty)`, smoothed with a ~2 s EMA to stop jitter. Bands: green ≥80 · amber 60–79 · coral <60. By construction it enters amber/coral around the §3 slouch threshold, but the actual trigger stays the §3 hysteresis state machine — the score only visualizes it.

**Power note (ties to §5).** While the panel is open the user is actively looking, so raise the preview/sample rate to **15–30 fps** for smooth feedback. The instant the panel closes, drop back to the **1.5 s idle sampling** — the high rate is scoped to "panel visible" only, so it doesn't break the always-on power budget. All §5 pause/stop logic (panel closed + idle/asleep → stop session) still applies. *Decision: locked — high FPS only while the panel is visible; no always-on preview.*

**Milestone.** Slots in after M5 as **M5.5 (visualization)**, reusing M2–M4 outputs.

---

## References
1. Spine-Health — *How to Measure and Fix Forward Head Posture* (CVA definition, thresholds). https://www.spine-health.com/conditions/neck-pain/how-measure-and-fix-forward-head-posture
2. Physiopedia — *Craniovertebral angle*. https://www.physio-pedia.com/Craniovertebral_angle · CVA standing vs sitting study (PMC): https://pmc.ncbi.nlm.nih.gov/articles/PMC11042887/
3. ScienceDirect — *Validity of a qualitative visual method for diagnosing forward head posture*: https://www.sciencedirect.com/science/article/abs/pii/S246878122500030X · IJPHY — *Photogrammetric quantification of FHP is side-dependent*: https://ijphy.com/index.php/journal/article/view/245
4. `aaronhubhachen/slouch-detector` (GitHub) — front-cam nose-to-shoulder distance + median calibration + adjustable threshold (0.05/0.08/0.12). https://github.com/aaronhubhachen/slouch-detector
5. LearnOpenCV — *Building a Body Posture Analysis System Using MediaPipe* — side-view neck/torso inclination (neck < 40°, torso < 10°) + camera-alignment check. https://learnopencv.com/building-a-body-posture-analysis-system-using-mediapipe/
6. MDPI *Applied Sciences* — *Sitting Posture Recognition Systems: Comprehensive Literature Review*. https://www.mdpi.com/2076-3417/14/18/8557
7. *SitPose: Real-Time Detection of Sitting Posture …* (arXiv). https://arxiv.org/abs/2412.12216
