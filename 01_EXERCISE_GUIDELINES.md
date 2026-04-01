# FiTrack — Exercise & Testing Guidelines

> **Purpose:** Practical reference for implementation and data collection.  
> All thresholds here must match `app/lib/core/constants.dart` and `.agent_brain/SKILLS.md`.  
> For academic biomechanical grounding, see `01_RESEARCH_Biometrics_Refinement.md`.

---

## 1. Biceps Curl

### What Counts as One Rep
A single rep is defined by a full 4-state FSM cycle:

```
IDLE ──[θ < 150°]──► CONCENTRIC ──[θ ≤ 40°]──► PEAK
  ▲                                                │
  │                                                │ [θ > 50°]
  └───────────[θ ≥ 160°, rep++]───── ECCENTRIC ◄──┘
```

| Transition | Trigger | Constant |
|---|---|---|
| IDLE → CONCENTRIC | Elbow angle drops below 150° | `kCurlStartAngle` |
| CONCENTRIC → PEAK | Elbow angle reaches ≤ 40° (full flexion) | `kCurlPeakAngle` |
| PEAK → ECCENTRIC | Elbow angle rises above 50° | `kCurlPeakExitAngle` |
| ECCENTRIC → IDLE | Elbow angle returns to ≥ 160° → rep++ | `kCurlEndAngle` |

Elbow angle θ is calculated as:
```
θ = arccos((BA · BC) / (|BA| * |BC|))
where BA = shoulder_pos − elbow_pos
      BC = wrist_pos − elbow_pos
```

### Preferred Side / View
- **Camera view:** Sagittal (side profile)
- **Side:** Either side is acceptable; near-side arm is used when far-side confidence < 0.4
- **Subject orientation:** Standing, arm hanging naturally, curling toward the camera's view plane

### Camera Placement
| Parameter | Specification |
|---|---|
| Distance from subject | 1.5 – 2.0 m |
| Camera height | 0.8 – 1.0 m (approximately waist level) |
| Horizontal angle | 90° perpendicular to the curl plane (true sagittal) |
| Subject position in frame | Center 60% of frame width (avoids radial lens distortion) |
| Orientation | Portrait mode (locked) |

### Required Landmarks
| Landmark | ML Kit Index | Role |
|---|---|---|
| Left Shoulder | 11 | Angle vertex A, swing detection |
| Right Shoulder | 12 | Angle vertex A (fallback side) |
| Left Elbow | 13 | Angle vertex B (joint center) |
| Right Elbow | 14 | Angle vertex B (fallback side) |
| Left Wrist | 15 | Angle vertex C |
| Right Wrist | 16 | Angle vertex C (fallback side) |
| Left Hip | 23 | Torso length normalization |
| Right Hip | 24 | Torso length normalization |

**Minimum confidence:** `kMinLandmarkConfidence = 0.4`. Frames below this threshold are skipped.

### Failure Cases
| Failure | Detection | Threshold | Feedback Cue |
|---|---|---|---|
| Torso swing (momentum cheat) | `ΔX_shoulder / L_torso > kSwingThreshold` | 0.15 | "Don't swing" |
| Elbow drift (isolation loss) | `ΔX_elbow / L_torso > kDriftThreshold` | 0.10 | "Keep your elbow still" |
| Partial ROM | Rep counted without θ ever reaching ≤ 40° | — | "Full range of motion" |
| Far-side occlusion | Far-side landmark confidence < 0.4 | — | Use near-side arm as proxy |
| Poor lighting / clothing | Confidence < 0.4 on all relevant landmarks | — | Frame skipped silently |

---

## 2. Squat

### What Counts as One Rep
A single rep is defined by a full 4-state FSM cycle:

```
IDLE ──[Hip Y rising, θ_knee < 160°]──► DESCENDING ──[θ_knee < 90°]──► BOTTOM
  ▲                                                                          │
  │                                                                          │ [Hip Y falling]
  └───────────────[θ_knee > 160°, rep++]────────── ASCENDING ◄──────────────┘
```

| Transition | Trigger |
|---|---|
| IDLE → DESCENDING | Hip Y-coordinate increases (descent begins), knee θ drops below 160° |
| DESCENDING → BOTTOM | Hip-Knee-Ankle angle < 90° (thighs at or below parallel) |
| BOTTOM → ASCENDING | Hip Y-coordinate decreases (ascent begins) |
| ASCENDING → IDLE | Knee angle returns to > 160° → rep++ |

> **Long-femur adjustment:** BOTTOM threshold relaxed to 100° for subjects with proportionally long femurs.

### Preferred Side / View
- **Camera view:** Sagittal (side profile) — mandatory for trunk-tibia parallelism check
- **Side:** Either side; choose the side where knee and ankle are unobstructed
- **Subject orientation:** Feet roughly shoulder-width apart, toes slightly outward (≤ 30°)

### Camera Placement
| Parameter | Specification |
|---|---|
| Distance from subject | 2.0 – 3.0 m (full body must fit in frame at squat depth) |
| Camera height | 0.8 – 1.0 m (mid-torso level when subject is standing) |
| Horizontal angle | 90° perpendicular to the movement plane |
| Subject position in frame | Center of frame; ankles must remain visible at full depth |
| Orientation | Portrait mode |

### Required Landmarks
| Landmark | ML Kit Index | Role |
|---|---|---|
| Left/Right Shoulder | 11, 12 | Trunk angle calculation |
| Left/Right Hip | 23, 24 | Primary rep driver (Y-velocity), trunk angle |
| Left/Right Knee | 25, 26 | FSM depth trigger, valgus check |
| Left/Right Ankle | 27, 28 | Full-body alignment, depth confirmation |

**All landmarks must remain visible throughout the full descent.** If ankles drop below frame, the rep cannot be validated.

### Failure Cases
| Failure | Detection | Threshold | Feedback Cue |
|---|---|---|---|
| Trunk-tibia divergence | `\|θ_trunk − θ_tibia\| > 15°` | 15° | "Keep chest up" |
| Insufficient depth | BOTTOM state never reached (knee θ stays > 90°) | — | "Squat lower" |
| Knee valgus | Knee X-position drifts medially from toe line | — | "Knees out" |
| Lumbar rounding | Trunk θ deviation from neutral spine | — | "Keep back straight" |
| Heel lift | Ankle Y-coordinate rises during descent | — | "Heels down" |
| Ankle occlusion | Ankle confidence < 0.4 | — | Frame skipped; rep unverifiable |
| Side angle issues | Subject rotated > 15° off sagittal plane | — | Foreshortening error; prompt repositioning |

---

## 3. Push-up

### What Counts as One Rep
A single rep is defined by a full 4-state FSM cycle:

```
IDLE ──[θ_elbow < 160°]──► DESCENDING ──[θ_elbow < 90°]──► BOTTOM
  ▲                                                              │
  │                                                              │ [θ_elbow rising]
  └──────────────[θ_elbow > 160°, rep++]────── ASCENDING ◄──────┘
```

| Transition | Trigger |
|---|---|
| IDLE → DESCENDING | Elbow angle drops below 160° (controlled descent begins) |
| DESCENDING → BOTTOM | Elbow angle < 90° (chest near floor) |
| BOTTOM → ASCENDING | Elbow angle begins increasing |
| ASCENDING → IDLE | Elbow angle returns to > 160° → rep++ |

**Form requirement:** Throughout all phases, shoulder-hip-ankle collinearity deviation must stay < 15° (rigid plank check).

### Preferred Side / View
- **Camera view:** Sagittal (side profile) — essential for the collinearity/plank check
- **Camera position:** Low to ground (floor level or low tripod) — must capture the full body from head to ankle
- **Subject orientation:** Standard push-up position, perpendicular to camera

### Camera Placement
| Parameter | Specification |
|---|---|
| Distance from subject | 2.0 – 3.0 m (entire body length must fit in frame) |
| Camera height | 0.1 – 0.3 m (near floor level; captures the plank line accurately) |
| Horizontal angle | 90° perpendicular to body axis |
| Subject position in frame | Center horizontally; head and feet must both be visible |
| Orientation | Landscape mode preferred for push-ups (wider body line) |

### Required Landmarks
| Landmark | ML Kit Index | Role |
|---|---|---|
| Left/Right Shoulder | 11, 12 | Elbow angle vertex A; plank collinearity |
| Left/Right Elbow | 13, 14 | Angle vertex B (rep driver) |
| Left/Right Wrist | 15, 16 | Angle vertex C |
| Left/Right Hip | 23, 24 | Plank midpoint — hip sag detection |
| Left/Right Ankle | 27, 28 | Plank endpoint — collinearity check |

**All landmarks from shoulder to ankle must remain in frame at all times.** Hip sag cannot be detected if hips leave the frame.

### Failure Cases
| Failure | Detection | Threshold | Feedback Cue |
|---|---|---|---|
| Hip sag (core failure) | Shoulder-Hip-Ankle collinearity deviation > 15° | 15° | "Keep hips up" |
| Insufficient depth | BOTTOM state never reached (elbow θ stays > 90°) | — | "Go lower" |
| Scapular winging | Shoulder blade protrusion (shoulder Y vs. torso plane) | — | "Squeeze shoulder blades" |
| Tempo bounce | BOTTOM → ASCENDING transition < 200 ms | — | "Control the descent" |
| Ankle occlusion | Ankle confidence < 0.4 | — | Frame skipped; plank unverifiable |
| Camera too high | Hip-to-ankle line appears as a point (foreshortening) | — | Prompt to lower camera |

---

## 4. General Testing Assumptions

### Environment
| Factor | Requirement |
|---|---|
| Lighting | Well-lit indoor space; avoid backlit windows or harsh shadows |
| Background | Uncluttered, high contrast with subject clothing |
| Clothing | Form-fitting preferred; loose/baggy clothing occludes joint positions |
| Floor surface | Flat, stable (no mats that compress unpredictably under feet) |

### Camera / Device
| Factor | Requirement |
|---|---|
| Minimum FPS | 15 FPS (`kTargetFPS`) |
| Max frame-to-feedback latency | 200 ms (`kMaxEndToEndLatency`) |
| Subject in-frame zone | Center 60% of frame width (avoid radial lens distortion at edges) |
| Portrait vs. landscape | Portrait for standing exercises; landscape for push-ups |
| Phone stability | Use a tripod or stable surface — handheld introduces jitter |

### Confidence & Filtering
| Constant | Value | Meaning |
|---|---|---|
| `kMinLandmarkConfidence` | 0.4 | Frames below this are skipped |
| `kFarSideConfidenceGate` | 0.4 | Use near-side as proxy if far-side drops below this |
| `kStateDebounce` | 500 ms | Lockout after each FSM transition (prevents double-counting) |
| `kStuckStateLimit` | 5.0 s | Auto-reset to IDLE if stuck (zombie user detection) |
| `kFeedbackCooldownSec` | 3.0 s | Minimum interval between consecutive audio cues |

---

## 5. Failure Case Summary

| Failure Mode | Exercises Affected | Detection Method | Cue |
|---|---|---|---|
| Torso swing | Biceps Curl | `ΔX_shoulder / L_torso > 0.15` | "Don't swing" |
| Elbow drift | Biceps Curl | `ΔX_elbow / L_torso > 0.10` | "Keep elbow still" |
| Partial ROM | All 3 | FSM never reaches BOTTOM/PEAK state | "Full range of motion" |
| Hip sag | Push-up | Shoulder-Hip-Ankle deviation > 15° | "Keep hips up" |
| Trunk-tibia divergence | Squat | `\|θ_trunk − θ_tibia\| > 15°` | "Keep chest up" |
| Knee valgus | Squat | Knee X drifts medially from toe line | "Knees out" |
| Insufficient depth | Squat, Push-up | BOTTOM state not reached | "Go lower" / "Squat lower" |
| Heel lift | Squat | Ankle Y rises during descent | "Heels down" |
| Low confidence | All 3 | Any key landmark < 0.4 | Frame skipped |
| Landmark occlusion | All 3 | Landmark visibility = 0 | Near-side proxy or skip |
| Poor lighting | All 3 | Global confidence drop < 0.4 | Frame skipped |
| Subject off-sagittal | All 3 | Rotation > 15° from camera plane | Prompt repositioning |
| Camera too high (push-up) | Push-up | Hip foreshortening | Prompt to lower phone |

---

## 6. Data Collection Checklist

Use this checklist before every recording session:

- [ ] Subject standing/positioned in center 60% of frame
- [ ] All required landmarks visible and confidence > 0.4 (check skeleton overlay)
- [ ] Camera at specified height on a stable tripod
- [ ] Adequate lighting — no backlighting, even illumination
- [ ] Subject wearing form-fitting clothing
- [ ] Background is uncluttered
- [ ] Phone in correct orientation (portrait for curl/squat, landscape for push-up)
- [ ] At least 2 m clearance around subject
- [ ] Record both correct form AND common mistakes (swing, sag, shallow depth)
