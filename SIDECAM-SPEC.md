# Sloucher — Side-Camera Mode Spec

Extends `SPEC.md` and `DESIGN.md`. Promotes the lateral-view approach (previously "optional Pro," §3) to the **primary** detection mode after front-camera detection proved unreliable for recline / forward-head slouches.

**Why side view.** Forward-head and recline slouches are sagittal-plane motions — they happen along a front camera's depth axis, which it barely sees (confirmed in testing; consistent with `SPEC.md §3` Evidence). A camera to your side sees those motions directly as **angles**: the neck tips forward and the torso reclines. This is the clinical craniovertebral-angle axis. [1][2][4]

**Decisions (this turn):**
- **Camera = device-agnostic.** Auto-detect all connected cameras; user picks which one is to their side. Works with a USB webcam, Continuity Camera, or anything else.
- **Both modes, switchable.** Side is primary/default; front (`SPEC.md §3`) stays as a selectable fallback (travel, no side surface). Each mode keeps its own calibration baseline.
- Inherits everything else from `SPEC.md`: Apple Silicon, macOS 13+, on-device Vision, always-on + power-efficient, nudge = notification + sound + overlay.

---

## 1. Scope & modes

| Mode | Camera | Signal | Status |
|---|---|---|---|
| **Side** (default) | any camera placed laterally | neck + torso inclination angles | primary |
| **Front** (fallback) | built-in FaceTime cam | `neckDistance` ratio (`SPEC.md §3`) | kept, selectable |

`Settings.detectionMode ∈ {side, front}`. Baselines, sensitivity, and the selected camera are stored **per mode** so switching never forces a recalibration. Default for a fresh install = **side**, with the setup wizard (§6).

---

## 2. Hardware & placement

Any camera that yields a roughly lateral view of your upper body works. Guidance, not a hard requirement (alignment is measured live, §6):

- **Angle:** as close to 90° to your side as the desk allows. The method degrades gracefully down to ~60°; below that, accuracy drops and the app warns.
- **Height:** roughly shoulder height, lens level (not looking steeply up/down).
- **Distance:** ~0.5–1.2 m, framing **ear down to hip** in profile.
- **Orientation:** landscape.
- **Stability:** fixed mount. If the camera moves after calibration, the baseline is invalid (handled in §9).

**Practical note (always-on):** a cheap dedicated USB webcam clamped to the side is the most practical all-day option. Continuity Camera (iPhone) gives great quality and is fully supported via device auto-detection, but ties up the phone — better for spot-checks than 8-hour monitoring. The app treats them identically.

---

## 3. Camera selection & mode switching

- **Discovery:** `AVCaptureDevice.DiscoverySession` over `[.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera]`, video. List by `localizedName`; persist the chosen device by `uniqueID` per mode.
- **Picker:** Settings → "Side camera" dropdown of detected cameras + a live preview thumbnail so the user confirms the right one. Same for the front-mode camera.
- **Hot-plug:** observe `.AVCaptureDeviceWasConnected/Disconnected`. If the selected side camera disconnects (e.g., Continuity Camera leaves with the phone) → state `cameraLost`, pause detection, surface "Side camera disconnected — reconnect or switch mode."
- **Mode switch:** menu-bar item + Settings toggle (Side / Front). Switching loads that mode's camera + baseline; if the mode has no baseline yet, route to calibration.

---

## 4. Detection — signals

Lateral view. Use Vision body-pose joints on the **camera-facing side** (the side with higher mean confidence across ear+shoulder+hip): `ear`, `shoulder`, `hip` (plus `nose` for drawing). All angles are scale-invariant, so distance to camera doesn't matter.

| Metric | Definition | Catches | Reliability |
|---|---|---|---|
| `neckInclination` | angle of shoulder→ear line from vertical | forward-head / chin poke | high |
| `torsoInclination` | angle of hip→shoulder line from vertical | reclining / slumping back | high |
| `alignmentScore` | how lateral the view is (see below) | bad camera angle / user turned | gate |

**Angle math** (degrees, from vertical through the lower joint):
```
neckInclination  = atan2( |ear.x − shoulder.x|, |shoulder.y − ear.y| ) · 180/π
torsoInclination = atan2( |shoulder.x − hip.x|, |hip.y − shoulder.y| ) · 180/π
```
*(Vision normalized coords are origin-bottom-left, y-up; verify sign so "leaning toward the screen" increases the angle.)*

**Clinical grounding.** `neckInclination` is monotonic with forward-head severity and ≈ complementary to the craniovertebral angle (CVA = tragus→C7 vs horizontal; FHP flagged < ~50°). Calibration handles the absolute offset, so we trigger on *deviation from your upright baseline*, not a fixed clinical cutoff. [1][2][4]

**Side selection.** Each frame, compute mean confidence of `{ear, shoulder, hip}` for left vs right; use the higher (camera-facing) side. Hysteresis on the choice to avoid fl/flop.

**Alignment gate.** In a true lateral view the two shoulders nearly overlap horizontally. Define `alignmentScore = 1 − clamp(|leftShoulder.x − rightShoulder.x| / torsoHeight, 0, 1)` (≈1 lateral, →0 frontal). Detection runs only when `alignmentScore ≥ 0.7`; otherwise state `fixAngle` (no nudges) with a "turn the camera to your side" hint.

---

## 5. Calibration & trigger logic

**Calibration (per mode).** Sit how you *want* to sit; confirm alignment OK; capture ~30 frames / 2 s; store the **median** baseline `N0` (`neckInclination`) and `T0` (`torsoInclination`) in `UserDefaults`.

**Decision (state machine, hysteresis):**
```
SLOUCH when, sustained ≥ holdSeconds (5 s):
    neckInclination  > N0 + neckDelta
    OR torsoInclination > T0 + torsoDelta

RECOVER (→ GOOD) when, sustained ≥ recoverSeconds (3 s):
    neckInclination  ≤ N0 + neckDelta·0.5
    AND torsoInclination ≤ T0 + torsoDelta·0.5
```

**Defaults (tune in testing):** `neckDelta = 10°`, `torsoDelta = 6°`, `holdSeconds = 5`, `recoverSeconds = 3`.

**Sensitivity slider** maps the deltas:

| Level | neckDelta | torsoDelta |
|---|---|---|
| Strict | 7° | 4° |
| Normal | 10° | 6° |
| Relaxed | 14° | 9° |

**Gates:** require `ear` + `shoulder` confidence > 0.3 (hip optional — see §9); require `alignmentScore ≥ 0.7`. Failing either → no nudge, set `cantSeeYou` / `fixAngle`.

This directly fixes the front-mode failure: a recline raises `torsoInclination`; a forward-head raises `neckInclination`. Either crosses its threshold regardless of how far/high the head sits in frame.

---

## 6. Setup & alignment UX

First run (or on choosing Side mode) → a 3-step wizard:

1. **Pick the camera** — dropdown of detected cameras + live preview; "use the one to your side."
2. **Align** — live `alignmentScore` meter (Good / Turn camera / Move back) + the detected skeleton drawn on the preview, so the user positions the camera until alignment is Good. Needs ear→hip in frame.
3. **Calibrate** — "Sit upright the way you want to, then Calibrate." Captures `N0/T0`. Done.

A persistent thin **alignment indicator** appears in the inspector; if `alignmentScore` drops below tolerance for >3 s during use, show a non-nagging "camera angle off" hint and pause nudges until fixed.

---

## 7. Inspector integration

Reuse `DESIGN.md` layout and tokens; in side mode the preview + readouts change:

- **Overlay:** draw `ear`, `shoulder`, `hip` nodes; the **neck line** (shoulder→ear) and **torso line** (hip→shoulder); a faint vertical reference at each pivot; and an **angle arc** at shoulder and hip showing the live inclination. Color good/slouch as in `DESIGN.md`. Replace the front-mode "calibrated head line" with **baseline angle ghosts** (dashed lines at `N0`/`T0`).
- **Readouts:** two gauges replace the front bars — `neckInclination` (value °, baseline tick `N0`, threshold tick `N0+neckDelta`) and `torsoInclination` (°, `T0`, `T0+torsoDelta`); coral past threshold. Plus stat cards: confidence, **alignment %**, sampling, time-in-posture. Sparkline plots the dominant angle vs its threshold.
- **Score (display-only):** `overshoot = max((neckInclination−N0)/neckDelta, (torsoInclination−T0)/torsoDelta)`; `score = clamp(0,100, 100 − 100·overshoot)`, 2 s EMA, bands green ≥80 / amber 60–79 / coral <60. Trigger still owned by §5.
- **Mode + camera controls:** mode toggle (Side/Front) and camera picker live in Settings; inspector header shows current mode + alignment status.

---

## 8. Power (ties to `SPEC.md §5`)

Identical budget, on whichever camera: sample 1 frame / 1.5 s; motion-gate; stop the session on display sleep / lock / idle > 60 s; battery-aware 3 s cadence; high FPS (15–30) only while the inspector panel is visible. One small Vision request per sample. A dedicated side webcam idles at ~0 power when the session is stopped.

---

## 9. Edge cases

- **Not lateral enough** (both shoulders wide / `alignmentScore` low): `fixAngle` state, hint to turn the camera, no nudges.
- **Camera moved after calibration:** detect a sustained shift in `alignmentScore` or a large baseline jump → prompt "recalibrate (camera moved?)."
- **Hip out of frame / occluded by desk** (low hip confidence): fall back to **neck-only** detection; mark torso "unavailable"; still catches forward-head.
- **Continuity Camera disconnect:** `cameraLost` → pause + prompt reconnect or switch mode.
- **Multiple people:** pick the profile with highest summed joint confidence.
- **Facing left vs right:** auto-selected per §4; no user setting needed.
- **Not calibrated for the active mode:** route to wizard; no nudges until baseline exists.
- **Low light / cropped:** `cantSeeYou` (confidence gate), no nudges, metrics dim.

---

## 10. Implementation notes

- **Capture:** `AVCaptureSession` bound to the selected device; `AVCaptureVideoDataOutput` delegate, throttled to the sample interval (drop intermediate frames). Re-bind on mode/camera change.
- **Pose:** `VNDetectHumanBodyPoseRequest` per sampled frame (`recognizedPoint(.rightEar)` etc.). Hardware-accelerated on Apple Silicon. No new model vs front mode — same request, different joints/derivation.
- **Analyzer:** extend `PostureAnalyzer` (`DESIGN.md`) with `neckInclination`, `torsoInclination`, `alignmentScore`, `N0/T0`, `detectionMode`; the state machine branches on mode. Inspector binds the same way.
- **Settings:** `detectionMode`, `sideCameraUniqueID`, `frontCameraUniqueID`, per-mode baselines + sensitivity. Persist to `UserDefaults`.
- **Device hot-plug:** `AVCaptureDevice` connect/disconnect notifications → update picker + handle `cameraLost`.
- **SwiftUI:** mode-aware `InspectorView`; side overlay = `Canvas`/`CAShapeLayer` drawing nodes + two lines + two angle arcs; angle gauges as labeled arcs or reuse the bar component in degrees.

---

## 11. Milestones (replaces front as primary)

| # | Milestone | Output |
|---|---|---|
| **S0** | Camera discovery + picker | enumerate/select/persist any camera; live preview |
| **S1** | Side pose + angles | neck/torso inclination from chosen side; live log |
| **S2** | Alignment + wizard | `alignmentScore`, 3-step setup, live meter |
| **S3** | Calibrate + trigger | per-mode `N0/T0`; §5 state machine + hysteresis |
| **S4** | Nudges | reuse `SPEC.md §M5` (notification + sound + overlay) |
| **S5** | Inspector (side) | overlay + angle gauges + score + alignment status |
| **S6** | Mode switch + power | Side/Front toggle, per-mode state; §5 power logic |

Front mode (`SPEC.md` M0–M5) is retained behind the mode switch; no new detection model is introduced.

---

## References
1. Spine-Health — *Forward Head Posture / CVA* (side-view measurement, thresholds). https://www.spine-health.com/conditions/neck-pain/how-measure-and-fix-forward-head-posture
2. Physiopedia — *Craniovertebral angle*. https://www.physio-pedia.com/Craniovertebral_angle
3. IJPHY — *Photogrammetric FHP quantification is side-dependent*. https://ijphy.com/index.php/journal/article/view/245
4. LearnOpenCV — *Body Posture Analysis with MediaPipe* — side-view neck/torso inclination (neck < 40°, torso < 10°) + shoulder-overlap alignment check. https://learnopencv.com/building-a-body-posture-analysis-system-using-mediapipe/
