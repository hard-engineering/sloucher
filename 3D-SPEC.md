# Sloucher — 3D Pose Mode Spec

Extends `SPEC.md`, `DESIGN.md`, and the current 2D implementation (`PostureAnalyzer`/`AppState`). Product spec only — no code. Threshold values are concrete **starting points**; the observability below exists precisely so you can tune them from what you see on screen.

## Decisions baked in
- **Camera stays the front built-in** (zero setup = adoption). 3D recovers the sagittal/depth axis a front camera otherwise can't see.
- **Minimum OS = macOS 14** (drop 13). Single code path; `VNDetectHumanBodyPose3DRequest` always available.
- **Three modes, user-toggleable from the UI: 2D / 3D / Hybrid** — kept as a **live comparison harness** (see §1). Hybrid runs both per sample and fuses.
- **Calibration = single-pose (upright only)** — fixed per-signal deltas off your upright baseline. (You kept 1-pose; it avoids the exaggerated demo-slouch pitfall. Separation is verified *live* via §6, not at calibration.)
- **Observability = on-screen readouts + real-time logging**, persisted to a **rolling on-disk log (numbers only)** plus **one-tap copy** (§6).

---

## 1. Modes & the toggle

A segmented control **2D · 3D · Hybrid** in the inspector controls row (next to Sensitivity).

| Mode | Runs per sample | Decides from | Role in the harness |
|---|---|---|---|
| **2D** | `VNDetectHumanBodyPoseRequest` (+ face) | existing `neckDistance` / `closeness` | known baseline — works partly, lowest power |
| **3D** | `VNDetectHumanBodyPose3DRequest` | sagittal angles + forward-head depth (§3) | depth-aware candidate — catches forward-head / recline |
| **Hybrid** | both requests | fused 2D + 3D decision (§5) | both fused — highest reliability, highest power |

**Why three modes (not one auto-picked).** They are a live A/B harness for *your* setup. 2D is the baseline you already have, 3D is the depth-aware candidate, Hybrid is both fused. You keep all three so you can run each against your real desk and use the observability (§6) to see which actually separates your slouch — rather than the app choosing blindly. Once one proves out it becomes the daily driver; the others stay for re-checking after a setup change.

**Shadow-compare (judge without toggling).** Comparing by flipping the toggle is unfair — your posture and the lighting change between flips. So while the inspector is open, it computes and shows what **all three modes would decide this instant**, side by side, regardless of which one is active (nudging). This costs the same as Hybrid (both Vision requests every sample) and is a diagnostic view, on only while the inspector is open. This is the honest way to answer "which is performing well right now."

Behavior:
- Switching the active mode loads that mode's **own calibration baseline** (2D and 3D baselines are different quantities, stored separately; switching never silently reuses the wrong one).
- If the active mode has no baseline yet → route to calibration before it can nudge.
- Active mode shown in the header at all times.
- Shared, unchanged timers: hold 5 s to enter slouch, recover 3 s to exit, 8 s unmeasurable → "can't see."

---

## 2. 3D input (front camera)

`VNHumanBodyPose3DObservation` — 17 joints, positions in **meters**, origin at `root` (hips). Joints used: `centerHead`/`topHead`, `centerShoulder`, `leftShoulder`, `rightShoulder`, `spine`, `root`, `leftHip`, `rightHip`. Each has a confidence and a 2D projection.

Two conventions (sign-check at implementation, as with the 2D `neckDistance`):
- **Sagittal plane = vertical (y) × depth (z).** The front camera faces the user, so forward/back is the depth axis; left/right (x) is ignored for these signals.
- **Scale normalizer = torso length `L`** = 3D distance `centerShoulder ↔ hipMid`, measured from the skeleton. Prefer this over the observation's `bodyHeight`, which extrapolates the legs — unreliable for a seated user with legs under the desk.

---

## 3. 3D signals & thresholds

All thresholds are **fixed deviations from your calibrated upright** (single-pose). Forward-head and recline both *increase* their angle — the motion class a 2D front view can't resolve.

| Signal | Definition (conceptual) | Increases when | Reliability |
|---|---|---|---|
| `neckSagittalAngle` (NSA) | angle of `centerShoulder → centerHead` from vertical, y–z plane | head pokes forward / looks down | high |
| `trunkSagittalAngle` (TSA) | angle of `root → spine` from vertical, y–z plane | reclining / slumping back | high |
| `forwardHeadDepth` (FHD) | `(shoulder.z − head.z) / L` (head forward of shoulders, normalized) | forward-head translation | medium (depth-noise sensitive) |
| `slumpHeight` (SH) *(secondary)* | head-to-hip vertical distance / `L` | — decreases as you sink | medium |
| `depthStability` (gate) | rolling 1 s std-dev of head `z / L` | — | jitter monitor |

**Trigger (3D mode), sustained ≥ 5 s:** slouch if **any** primary signal exceeds `upright + Δ`:

```
NSA ≥ NSA_upright + Δ_NSA
TSA ≥ TSA_upright + Δ_TSA
FHD ≥ FHD_upright + Δ_FHD
```

**Recover (→ good), sustained ≥ 3 s:** all primary signals back within `upright + 0.6·Δ` (hysteresis).

**Sensitivity → per-signal delta `Δ`** (the 3D analog of today's 2D `drop` map, but in physically meaningful units):

| Level | Δ_NSA | Δ_TSA | Δ_FHD |
|---|---|---|---|
| Strict | 6° | 4° | 0.045·L |
| Normal | 8° | 6° | 0.060·L |
| Relaxed | 11° | 9° | 0.085·L |

Degrees and normalized depth are easier to reason about than a neck-distance ratio, which helps when you're reading the live margins to tune.

**Gates:**
- 3D joint confidence ≥ 0.30 for every joint a signal uses; else that signal is "unavailable" (not "good").
- `depthStability` > 0.04 (normalized) for >1 s → **depth unstable**: widen active thresholds ×1.5 and hold the last decision rather than flip. Surfaced live (§6).
- Hips/`spine` low-confidence (seated, occluded) → TSA unavailable → fall back to **NSA + FHD only**, with a live message.

**Display score** (generalizes today's): `penalty = 100 · max over active signals of (current − upright) / Δ`, clamped, EMA τ 0.4 s; bands green ≥80 / amber 60–79 / coral <60. Display-only; the trigger stays the state machine above.

---

## 4. Calibration (single-pose, upright)

Per mode. Recalibrate is the existing one-step flow — no change from today:

- **Upright** — "Sit how you want to sit." 2 s, ≥6 valid samples, median → `*_upright` per signal (and `L`). Thresholds = `upright + Δ` (§3).

You chose 1-pose over capturing a deliberate slouch because a performed "worst slouch" is ill-defined and tends to be exaggerated, setting thresholds too lax (you slump less in real life and never trigger). One clean, repeatable anchor is more reliable.

The trade-off: 1-pose can't *measure* your gap at calibration, so it can't tell you up front whether a view separates your slouch. **That check moves to runtime** — the live margin readouts and shadow-compare (§6) let you watch, within seconds of slouching, whether NSA/TSA/FHD actually cross and by how much. If they barely move, that's your cue to adjust sensitivity or switch modes. Observability replaces the calibration-time gap measurement.

Stored per mode: `*_upright`, `L`, sensitivity, calibratedAt.

---

## 5. Fusion (Hybrid mode)

Each sample, compute the 2D decision (existing) and the 3D decision (§3) independently, each with its own confidence:

- **Both confident:** enter slouch if **2D OR 3D** fires (sensitive to enter — they catch different failures); exit only when **both** have recovered (sticky to exit — avoids flicker). The asymmetry is deliberate for a nudge app.
- **One low-confidence:** decide from the confident one alone.
- **Both low-confidence:** `cannotSee`.
- Always record which signal fired and whether 2D and 3D **agree** (§6) — disagreement is the richest tuning clue.

---

## 6. Diagnostic observability — the primary lever

Fixing thresholds means *seeing* why the system fired or didn't, in real time. Much of this is already computed and dumped to `UserDefaults` (`runtime.*`: raw per-joint confidences, reject-reason histogram, 60-frame tracking window) but never shown — surface it.

**Per-signal live readouts** (all signals the active mode uses): current value · upright baseline · threshold · **margin to threshold** (signed — how close to firing). Margin is the single most useful tuning number — it shows instantly whether a threshold is too tight or too loose for the posture you're in.

**Confidence & stability strip:**
- per-joint 3D confidence for head, both shoulders, spine, both hips (today's single `Conf 51%` becomes per-joint, so you see *which* joint is the weak link);
- **depth-stability / z-jitter** light (green/amber/red) — the #1 monocular-3D risk; you must be able to watch it;
- sampling rate (existing `Smpl`); in Hybrid, a **fusion-agreement** indicator.

**Shadow-compare panel:** live verdicts for 2D, 3D, and Hybrid side by side (Good/Slouch + each one's closest-signal margin), so you can read which mode is tracking your real posture without toggling.

**Real-time message line** (the "why," not guesswork):
- "Not firing — neck +4° of +8° needed"
- "Depth unstable — hold still"
- "Slouch barely moves the signal in this view — try Hybrid or reposition"
- "Can't see hips — trunk angle off, using neck + depth"
- "2D says good, 3D says slouch"
- "Slouch entered (trunk +7°, neck +9°)" / "Recovered"

### Expanded logging (your priority)
- **Full per-frame decision trace** (active mode, every sample): each signal's value, baseline, threshold, margin, and the exact clause that decided — e.g. `TSA 14.2° ≥ 13.0° → slouch-candidate; hold 2.1/5 s`. Turns "it didn't fire" into a readable line.
- **Shadow verdict log:** 2D / 3D / Hybrid verdicts + agreement each sample, so you can scan a stretch and see which mode told the truth.
- **Threshold-crossing counters (session):** per signal, how often it crossed and total time over threshold — surfaces a hair-trigger or a never-fires signal at a glance.
- **Per-joint raw dump (on demand):** 3D joint positions (m), confidences, `L`, `depthStability` — so a weird reading traces to the joint causing it. Reuses the existing `runtime.*` fields.
- **Calibration record:** upright values + `L` + per-joint confidence captured, shown after calibrating — so you can tell a bad baseline from a bad threshold.
- **Event log:** timestamped transitions + the deciding clause, scrollable (last ~50).
- **Diagnostics disclosure:** an expandable inspector section exposing the above; collapsed by default so the everyday view stays clean.

**Persistence.** Logging is live in-memory **plus**:
- **Rolling on-disk log** — append-only JSONL in the app's Application Support container, **numbers only (pose-derived values + confidences, never frames or images)**, so the app's privacy posture holds even though this reverses the earlier "live only." Logged: every accepted sample's compact trace (mode, signals, baselines, thresholds, margins, verdict) + all transitions; full per-joint 3D dump on transitions and on demand. Daily file rotation, default retain **3 days or ~100 MB** (whichever first), auto-pruned. Settings toggle (on while tuning), with **Reveal in Finder** and **Clear logs**. This is what lets you correlate a 3 pm misfire after the fact and tune across sessions.
- **One-tap "Copy diagnostics"** — copies the current frame's full trace (all signals + per-joint 3D positions/confidence + `L` + `depthStability` + active mode + shadow verdicts), the last ~60-sample window summary, the calibration record, and app/OS/camera/version metadata, as text. Numbers only, no image.

---

## 7. UI changes (mapped to the current inspector)

Against the attached layout:
- **Header:** add the active-mode label beside the status pill; score ring unchanged.
- **Controls row:** add the **2D · 3D · Hybrid** segmented control next to Sensitivity. Recalibrate stays one step (upright).
- **Signal area** (active mode):
  - 3D: three bars — `neckSagittalAngle`, `trunkSagittalAngle`, `forwardHeadDepth` — each with baseline tick, threshold tick, numeric **margin**.
  - Hybrid: compact dual readout — 2D (`neckDistance`, `lean`) + 3D (three above) — with the fusion-agreement chip.
  - 2D: unchanged.
- **Shadow-compare strip:** a thin three-cell row (2D / 3D / Hybrid → verdict + margin), always visible while the inspector is open.
- **Stat cards:** keep `Conf`, `Shldr`, `Smpl`, `In pos`; add **`Depth`** (stability) and, in Hybrid, **`Fusion`** (agree/disagree). `Conf` becomes tappable → per-joint confidence.
- **Message line:** one live line under the sparkline (the §6 message); event log + traces in the Diagnostics disclosure.
- **Diagnostics disclosure actions:** Copy diagnostics · Reveal logs in Finder · Clear logs · on-disk logging toggle, alongside the event log and per-frame traces.
- **Sparkline:** plot the active mode's closest-to-firing normalized signal against its threshold (stays meaningful across modes), 12 s window.

---

## 8. Power

macOS 14 baseline. `VNDetectHumanBodyPose3DRequest` is heavier than 2D; Hybrid and the shadow-compare **run both requests** → ~2–3× per-sample cost. Within budget because:
- Cost is **per sample, not per frame** — at idle cadence (~1.5 s) even running both is a couple of inferences every 1.5 s.
- Motion-gate still applies; 15 Hz burst only while the inspector is open (and shadow-compare only runs then).
- Honest trade: 2D remains the explicit **battery-saver**, one toggle away. Hybrid-default is the reliability-for-power trade you chose.

---

## 9. Edge cases
- **Monocular depth (no LiDAR on Macs):** `z` is estimated and noisy — handled by smoothing, the `depthStability` gate, larger FHD deltas, and the live stability light. A depth-capable Continuity Camera improves `z` automatically.
- **Seated, legs/hips occluded:** TSA degrades to unavailable → NSA + FHD carry the decision; message shown.
- **`bodyHeight` unstable seated:** normalize by measured torso length `L`.
- **Mode without baseline:** route to calibration before nudging.
- **2D/3D disagreement (Hybrid):** OR-enter still fires; disagreement logged live.

---

## 10. Threshold summary

| Parameter | Value | Where |
|---|---|---|
| NSA trigger | `upright + Δ_NSA` | §3 |
| TSA trigger | `upright + Δ_TSA` | §3 |
| FHD trigger | `upright + Δ_FHD` | §3 |
| Δ_NSA (Strict/Normal/Relaxed) | 6° / 8° / 11° | §3 |
| Δ_TSA | 4° / 6° / 9° | §3 |
| Δ_FHD | 0.045 / 0.060 / 0.085 ·L | §3 |
| Recovery | `upright + 0.6·Δ` | §3 |
| Hold / recover / cannot-see | 5 s / 3 s / 8 s | reused from 2D |
| Joint confidence gate | ≥ 0.30 | §3 |
| Depth-stability gate | > 0.04 norm. for >1 s → widen ×1.5, hold | §3 |
| Calibration | single-pose (upright), 2 s, ≥6 samples | §4 |
| Default mode | Hybrid (2D = battery-saver) | §1 |
| Logging | live + rolling on-disk JSONL (3 days / ~100 MB, numbers only) + copy-to-clipboard | §6 |

---

## 11. Validate first
Use the new live readouts to settle the harness on your own setup: in Hybrid with shadow-compare on, do 3D's NSA/TSA/FHD **separate** upright from your real slouch with margin, and is `depthStability` green while you hold still? The shadow strip tells you which of 2D/3D/Hybrid tracks your posture truthfully — that's how you pick the daily driver, instead of guessing.
