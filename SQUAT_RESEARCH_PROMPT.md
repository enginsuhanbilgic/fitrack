# Deep Research Prompt: Scientific Squat Exercise Analysis for Mobile Real-Time Pose Detection

**Target:** Gemini Deep Research API

**Goal:** Generate a comprehensive, peer-reviewed biomechanical foundation for real-time squat rep counting and form analysis on mobile devices using 2D/3D pose estimation (ML Kit 33-landmark BlazePose schema).

---

## Research Objective

Design a **data-driven, scientifically grounded squat analyzer** for a mobile fitness app that:
1. Counts squat reps with ≥90% accuracy (MAE ≤ 1.5 reps per session)
2. Detects common form errors with ≥75% precision and ≤25% false-alarm rate
3. Runs in real-time (≥15 FPS) on mid-range Android/iOS devices
4. Operates under **clearly defined camera constraints** (front-view, side-view setups)
5. Derives thresholds from **biomechanical literature + empirical validation**, not hand-tuned constants

---

## Section A: Squat Biomechanics Foundation

### A.1 Kinetic Chain and Anatomical ROM

Research the following peer-reviewed sources and synthesize findings:

**Primary questions:**
- What is the **normal anatomical range of motion (ROM) for the knee joint during a full squat?**
  - Distinguish between: unrestricted squat, ATG (ass-to-grass), parallel (knee = hip), quarter squat
  - Report ROM ranges in degrees (flexion angle, not extension)
  - Cite normative data stratified by sex, age, and training status (NASM, NSCA, ACSM standards)
  
- **Hip flexion ROM during squat descent:**
  - Normal hip flexion angle at bottom position (degrees)
  - How does femur length affect achievable hip flexion? (Long-femur vs short-femur athletes)
  - Relationship between hip ROM and squat depth compensation patterns
  
- **Ankle dorsiflexion requirements:**
  - Minimum dorsiflexion needed for upright torso (degrees)
  - How heel elevation / shoe choice affects joint angles
  - Landmark mobility correlation with depth capability
  
- **Spine/Torso angle during descent:**
  - Forward lean angle (trunk angle from vertical) in Olympic-style vs low-bar vs bodyweight squat
  - Hip-dominant vs knee-dominant squat patterns and how to distinguish them
  - Safe forward-lean limits (spinal compression, disc herniation risk)

**Output format:** Consensus table with ranges (e.g., "Knee flexion at depth: 90–140° depending on squat style")

---

### A.2 Squat Variants and Their Biomechanical Signatures

**Taxonomy to research:**

| Squat Variant | Primary ROM Differences | Key Landmarks | Typical Depth | Form Risk |
|---|---|---|---|---|
| **Olympic/High-bar** | Upright torso, knee-dominant | Knee angle ≈ 120°–140° | Full/ATG | Anterior knee pain if weak quads |
| **Powerlifting/Low-bar** | Forward lean, hip-dominant | Hip dominance (low back load) | Parallel–ATG | Lower back strain, poor depth |
| **Goblet/Bodyweight** | Variable | Depth-dependent | Usually parallel+ | Quad dominance, mobility limited |
| **SSB (Safety Squat Bar)** | Forced upright | Vertical torso | Full/ATG | Quad emphasis |
| **Belt Squat** | No spinal load | Unlimited ROM | Usually ATG | Depth-only, less motor control |

**Questions to answer:**
- For each variant, what is the **canonical joint-angle signature** at: start (IDLE), mid-descent, bottom (BOTTOM), mid-ascent, end (IDLE)?
- How would a **2D camera (front/side view) distinguish** between these variants?
- Which variants are **safe/reasonable targets for a mobile fitness app MVP?** (Recommend 1–2 canonical forms)

---

### A.3 Common Squat Form Errors (Biomechanical & Injury Risk)

**Research the pathomechanics and prevalence of the following errors:**

| Form Error | Biomechanical Cause | Joint Angle Signature | Injury Risk | Detection Method (2D pose) |
|---|---|---|---|---|
| **Incomplete depth (quarter squat)** | Quad weakness, ankle mobility, fear | Knee angle > threshold (e.g., >100°) | Undertraining, missed stimulus | Knee angle at bottom, ROM tracking |
| **Valgus collapse (knees caving inward)** | Weak hip abductors, quad dominance, poor motor control | Knee X-position medial to ankle X-position (front view) | ACL strain, patellar pain | Front-view knee-to-ankle horizontal distance |
| **Forward knee shift (knee goes past toes)** | Ankle dorsiflexion limitation, hip flexibility, shoe choice | Knee X > ankle X (side view) | Anterior knee pain, ACL stress | Side-view knee-to-ankle horizontal offset |
| **Excessive forward lean (butt wink)** | Hip mobility, spinal control, bar position | Trunk angle > safe limit (e.g., >40–50° from vertical), loss of lumbar extension | Lower back disc herniation, facet syndrome | Torso-to-vertical angle, hip-to-shoulder alignment |
| **Heels lifting (loss of ankle stability)** | Ankle dorsiflexion ROM, calf tightness, weight distribution | Heel height change during descent (foot flattening) | Ankle instability, forward weight shift, injury risk | Ankle-to-floor contact loss in side view |
| **Asymmetry (one leg weaker)** | Strength imbalance, motor control, past injury | Depth/angle differ between legs, lateral shift | Risk of chronic imbalance, injury to weak side | Bilateral angle difference (front view) |
| **Knees not tracking over toes** | Hip internal rotation weakness, foot position | Knee angle inward/outward from ankle (front view) | ACL strain, meniscal stress | Knee-to-ankle X-displacement |
| **Chest collapse (rounding lower back, spinal flexion)** | Core weakness, excessive forward lean, posterior chain weakness | Loss of lumbar lordosis, thoracic rounding visible | Disc herniation, facet joint stress | Spine segment angles (derived from shoulder-hip-knee alignment) |

**Synthesis needed:**
- **Prevalence data:** Which errors are most common in untrained lifters? (Survey recent studies)
- **Quantitative thresholds:** For each error, provide a **numeric angle/distance threshold** derived from biomechanical literature or empirical studies (e.g., "valgus collapse defined as knee X displacement > 5–10% of knee-to-ankle distance")
- **Safety hierarchy:** Rank errors by injury risk (ACL/knee > back > shoulder)
- **Trainee feedback priority:** Which errors are most correctable by cuing? (ROM < form breakdown < strength)

---

## Section B: Pose-Estimation-Specific Biomechanics

### B.1 2D vs. 3D Joint Angle Measurement Limitations

**Research question:**
- **Can 2D pose (front/side view) reliably measure squat depth and form errors, or are certain errors invisible to 2D?**

**Specific sub-questions:**
- When measuring **knee flexion angle from 2D landmarks** (hip → knee → ankle), what is the accuracy vs. 3D IMU/optical tracking?
  - Citation: Studies comparing MediaPipe/OpenPose 2D to gold-standard 3D motion capture (VICON, Kinect, etc.)
  - What is the typical **measurement error (degrees)** in controlled conditions? (Usually 5–15° for knee angle)
  
- **Valgus collapse detection from front view:**
  - Is horizontal knee-medial-to-ankle displacement reliably detectable in 2D?
  - How does image parallax, camera angle drift affect detection?
  - What false-positive rate should we expect from 2D cues?
  
- **Forward knee shift (knee-over-toe) from side view:**
  - Research: Can 2D side-view distinguish "excessive forward shift" from normal anatomy? (E.g., long femur naturally places knee forward)
  - How do anthropometric factors (femur length, torso length) affect the threshold?
  - **Normalized measurement:** Should we measure as `(knee_x − ankle_x) / femur_length` or as absolute pixels?
  
- **Trunk-forward-lean from side view:**
  - How reliably can we measure **torso angle from 2D landmarks** (shoulder-hip-knee)?
  - What is the relationship between **measured 2D angle and true spinal flexion**?
  - Can we detect **spinal flex (butt wink) from just hip-sacrum angle,** or do we need shoulder-hip-knee?
  
- **Depth measurement robustness:**
  - When using **hip-Y or knee-Y displacement** to measure descent depth, what are systematic errors?
  - Does camera distance affect depth measurements? (Usually yes — need normalization by torso length)
  - What is a **robust frame-based depth metric** that's scale-invariant?

**Output:** Create a **2D measurement reliability table** showing: measurement, typical 2D error (degrees or %), gold-standard reference, recommended normalization scheme.

---

### B.2 Camera Setup & Viewpoint Constraints

**Research and recommend:**

- **Front view squat analysis:**
  - Optimal camera height (standing eye-level, below/above level?)
  - Camera distance (how far? distance-to-height ratio?)
  - What errors are **detectable from front view?** (Valgus, asymmetry, ROM)
  - What errors are **invisible from front view?** (Forward knee shift, spinal flexion, forward lean)
  
- **Side view squat analysis:**
  - Optimal camera placement (left side, right side, diagonal?)
  - What errors are **detectable from side view?** (Forward lean, knee shift, ROM, spine angle)
  - What errors are **invisible or ambiguous from side?** (Valgus, asymmetry)
  
- **Hybrid (front + side rotation detection):**
  - Can a single camera detect **view rotation mid-set** and switch detection logic?
  - How would this work in practice on a phone?
  - Research: MediaPipe/ML Kit view-change robustness
  
- **Fallback:** If only one camera angle is available (mobile app constraint), which is **most informative for both depth and form?**
  - Answer: Probably **45° diagonal** or **strict side view** (get forward lean + knee shift + depth)

**Output:** Recommend **canonical camera setup(s) for MVP** with explicit constraints (e.g., "side view within 1–2 meters, camera at knee height").

---

## Section C: Rep-Counting FSM (Squat)

### C.1 Finite State Machine Design

**Current FiTrack model (from SKILLS.md):**
```
IDLE (Knee θ > 160°) 
  → DESCENDING (Hip Y increasing) 
  → BOTTOM (HKA θ < 90°*)  [*or 100° for long-femur]
  → ASCENDING (Hip Y decreasing) 
  → IDLE (Knee θ > 160°)
```

**Research questions to refine this:**

- **State transition triggers (angle vs. velocity vs. position):**
  - Should IDLE→DESCENDING be triggered by **knee angle OR hip-Y displacement OR knee-velocity?**
  - Pros/cons of each approach (robustness to jitter, false starts, pauses)
  - **Hysteresis thresholds:** What gap prevents bounce-back false transitions?
  
- **Bottom detection:**
  - Current rule: "Hip-Knee-Ankle angle < 90°" — is this biomechanically sound?
  - Alternative: **Hip-Y position relative to start** (e.g., hip drops > 30 cm)?
  - Alternative: **Knee angle < threshold** (but adjustable for variant)?
  - Research: What is the **canonical definition of "squat depth"** in literature?
    - NSCA: "Thighs parallel to ground" = knee ≈ 90° flexion
    - "ATG" (ass-to-grass) = knee ≈ 120–140° flexion, or hip-below-knee
  - **MVP recommendation:** Choose one canonical target (e.g., "parallel depth") and publish it
  
- **Rep completion:**
  - Should the rep count only when returning to IDLE (full extension)?
  - Or count at BOTTOM (to allow pauses, partial reps)?
  - Research: **Rep-counting best practices** in prior squat-tracking studies (e.g., M3GYM dataset, Pose Trainer, Fitbod benchmarks)

### C.2 Squat Variant Auto-Detection

**Optional extension:**
- Can the FSM **auto-detect squat variant** (high-bar vs. low-bar) from angle signatures?
- If yes, adjust thresholds per variant (e.g., low-bar allows more forward lean)
- If no, require user to specify variant (MVP simplification)

**Output:** Refined FSM with **explicit angle thresholds, hysteresis gaps, and variant rules** (or note "variant auto-detect out of MVP scope").

---

## Section D: Form Error Detection (Thresholds & Metrics)

### D.1 Quantitative Threshold Derivation

For each **common squat form error** identified in §A.3, research and propose:

1. **Mathematical formula** to compute the error metric from 2D pose landmarks
   - E.g., valgus: `valgus_score = max(0, (ankle_x − knee_x) / knee_length) `
   - E.g., forward lean: `lean_angle = arctan((hip_x − shoulder_x) / (hip_y − shoulder_y))`
   
2. **Threshold value** (from literature or empirical studies)
   - E.g., "valgus collapse threshold = 0.08 (knee medial by 8% of knee length)"
   - Cite source: study name, sample size, population
   
3. **Confidence interval** (95% CI if available)
   - Shows how much variability to expect
   
4. **Per-variant adjustments** (if applicable)
   - E.g., "low-bar squat allows +5° more forward lean than high-bar"

**Errors to quantify:**
- Incomplete depth (ROM)
- Valgus collapse (knee X-displacement)
- Forward knee shift (knee-to-ankle offset, side view)
- Forward lean (torso angle, side view)
- Heel lift (foot angle change, side view)
- Asymmetry (bilateral knee/hip angle delta, front view)
- Chest collapse / spinal flexion (torso-hip angle, side view)

**Output format:** Threshold table (one row per error, columns: formula, threshold value, CI, variant adjustments, injury-risk level)

---

### D.2 Feedback Cue Mapping

For each form error, propose:

1. **User-facing cue** (short, actionable, non-medical)
   - E.g., "Keep your knees tracking over your toes" (not "prevent ACL valgus strain")
   
2. **When to trigger:** (per-rep, per-set, cumulative streak?)
   - E.g., valgus collapse: cue if `valgus_score > threshold` for 2 consecutive reps
   
3. **Cooldown policy:** (minimum time between repeats)
   - Prevent spam; research what feels natural (3–5 seconds typical)
   
4. **Modality:** (visual, audio, haptic, highlight which joints)
   - E.g., visual highlight on knees; audio cue "Knees in"

---

### D.3 Quality Scoring (Optional)

Research **rep quality** scoring systems:

- **Per-rep 0–1 scale:** 1.0 = perfect, deductions per form error
- **How much each error detracts?** (E.g., incomplete depth = −0.30, asymmetry = −0.10)
- **Proportional vs. binary:** Should deduction scale with **magnitude** of error, or threshold-only?
- **Session quality:** Average of per-rep scores, shown on Summary screen

**Research sources:**
- Fitbod's rep quality model (if published)
- NASM-PES rep quality criteria
- Any published squat-form-scoring rubric

---

## Section E: Biomechanical Constants & Normalization

### E.1 Anatomical Ratios (Winter's Model)

Verify and extend:

Current FiTrack uses **Winter's anthropometric ratios** (thigh 24.5%, lower leg 24.6% of height).

**Squat-specific additions:**
- **Knee length** (knee center to ankle center) = ?% of height
  - Used to normalize valgus/knee-shift thresholds
  
- **Femur length** (hip to knee) = 24.5% of height (already in SKILLS.md)
  - How does this affect forward-knee-shift threshold?
  
- **Torso length** (shoulder to hip, already used)
  - How should we normalize forward-lean angles?
  
- **Hip width** (left hip to right hip)
  - Normalize valgus collapse?

**Research:** Do these anatomical ratios vary significantly by sex, age, training status? Should thresholds be adaptive?

---

### E.2 Velocity-Based Training (VBT) for Squat

Research VBT metrics:

- **Mean Velocity Threshold (MVT)** for squat
  - At what velocity does a squat approach failure?
  - FiTrack already has `kSquatMVT: 0.30 m/s` (from SKILLS.md) — is this correct?
  - How is it measured? (hip displacement per second, knee extension velocity, etc.)
  
- **Fatigue detection:** Should squat trigger fatigue cues if velocity slows beyond threshold?

---

## Section F: Validation & Accuracy Benchmarks

### F.1 Rep-Counting Accuracy

Research prior studies (M3GYM, Pose Trainer, commercial apps):

- **Typical accuracy** of 2D pose rep counting (MAE, F1 score)
- **Accuracy by squat variant** (high-bar vs. low-bar vs. pause squat)
- **Accuracy by depth** (quarter, parallel, ATG)
- **Accuracy degradation** with: camera distance, lighting, clothing, fatigue
- **Gold-standard dataset:** Which public dataset is best for squat? (M3GYM, custom dataset requirements?)

**Target from FiTrack proposal:** MAE ≤ 1.5 reps per session — is this realistic for 2D pose? What factors are critical?

---

### F.2 Form-Error Detection Metrics

Research precision/recall/F1 for form-error detection:

- **Valgus collapse:** What precision/recall is achievable from front-view 2D?
- **Forward lean:** From side view, how often do false positives occur? (False alarm rate target: ≤25%)
- **Incomplete depth:** How is "incomplete" defined in prior studies? (Absolute angle vs. relative ROM vs. absolute distance?)

**Sources:** Pose Trainer, Fitbod blog posts, academic papers on pose-based exercise form assessment.

---

### F.3 Cross-Study Comparison

Compare thresholds across published squat-tracking systems:

| Study/System | Rep-Count Method | Depth Threshold | Valgus Method | Sample Size | Accuracy |
|---|---|---|---|---|---|
| M3GYM (2025) | ? | ? | ? | ? | ? |
| Pose Trainer (2020) | DTW scoring | ? | ? | ? | ? |
| Fitbod (commercial) | ? | ? | ? | ? | ? |
| Your prior work (if any) | ? | ? | ? | ? | ? |

**Output:** Consensus table showing where thresholds converge and where they diverge (and why).

---

## Section G: Data Collection & Validation Pipeline

### G.1 Dataset Design for FiTrack

Propose a **data collection protocol** to derive squat thresholds:

**Video recording specs:**
- Number of subjects (recommend: 20–30 untrained + trained)
- Videos per subject per variant (recommend: 5–10 reps each)
- Variants to record: High-bar, low-bar, bodyweight, goblet (recommend: start with 1–2)
- Views: Front + side (or + 45° if feasible)
- Lighting, distance, height constraints (per camera specs)

**Manual annotation:**
- **Rep boundaries** (start frame, bottom frame, end frame)
- **Rep quality** (good form / incomplete depth / valgus / forward lean / etc.)
- **Squat variant** (recorded variant)
- **Subject metadata** (height, weight, training experience, mobility notes)

**Validation:**
- **Intra-rater reliability** (one person re-labels 10% of clips; kappa score)
- **Inter-rater reliability** (two people label same clips; kappa score)
- **Target:** Cohen's kappa ≥ 0.80 (substantial agreement)

---

### G.2 Threshold Derivation Methodology

Propose a **statistical pipeline** (mirroring FiTrack's biceps-curl approach):

1. **Per-(variant, view) bucketing:** Derive thresholds separately for high-bar-front, high-bar-side, etc.
2. **Percentile estimation:** (e.g., P20 for depth start, P75 for valgus trigger)
3. **Bootstrap CI:** 95% confidence interval via BCa bootstrap (bias-corrected)
4. **MAD outlier rejection:** Remove biomechanically implausible samples
5. **FSM invariant checks:** Ensure thresholds allow all state transitions
6. **F1 validation:** Replay real squat videos through FSM + error detector; compute precision/recall/F1

**Output:** Generated Dart constants (`DefaultSquatThresholds.dart`) with per-variant, per-view thresholds + uncertainty estimates.

---

## Section H: Implementation Constraints (Mobile)

### H.1 Real-Time Performance Requirements

Research **landmark-detection latency** on target devices:

- **ML Kit Pose Detection latency** on mid-range Android (Snapdragon 665, 845, etc.)
  - Typical: 50–150 ms per frame (30 FPS max)
- **Feature extraction overhead:** Angle + distance computations
  - Typically < 5 ms for landmark-based features
- **FSM update latency:** < 5 ms
- **Form-error detection latency:** < 10 ms
- **Total budget:** ≤ 66 ms per frame (15 FPS target)

**Question:** What pose model / configuration optimizes for latency while preserving squat-landmark accuracy? (Base vs. accurate mode; resolution trade-offs)

---

### H.2 Robustness to Real-World Conditions

Research **how squat detection degrades** under:
- **Partial occlusion:** User's hands covering legs, squat rack in view
- **Clothing:** Loose pants, compression gear, baggy gym clothes
- **Lighting:** Dim gym, shadows, high-contrast
- **Camera angle drift:** User shifting slightly during set
- **Fatigue:** Does form degrade so much that landmark detection fails?

**Mitigation strategies** from literature:
- Landmark confidence gating (already in FiTrack; ≥0.4)
- Temporal smoothing (1€ filter; already used)
- Hybrid front+side (switch views if one fails)

---

## Section I: Summary & Recommendations for MVP

### I.1 Recommended Squat Model for FiTrack MVP

Synthesize all research into a **concrete specification:**

1. **Squat variant(s):** Recommend high-bar OR bodyweight squat (simplest to generalize)
2. **Camera setup:** Recommend front + side, or strict side-only?
3. **Rep-counting FSM:** Finalized angle thresholds (e.g., IDLE > 160°, BOTTOM < 90°, etc.)
4. **Form errors:** Priority list (top 3–4 most detectable + most valuable)
   - E.g., [incomplete depth, valgus collapse, forward lean] — all detectable from side view
5. **Thresholds:** Quantitative table with 95% CI
6. **Quality scoring:** Recommend proportional deduction model with specific weights
7. **Data collection:** Minimal viable dataset size + annotation checklist
8. **Timeline:** Estimated effort to collect data + derive thresholds + implement

---

### I.2 Out-of-MVP (Future Work)

Identify what's **beyond MVP scope:**
- Squat variant auto-detection
- Heel-lift detection (requires foot landmarks; less reliable)
- Dynamic pause-squat detection
- Asymmetry cues (harder to implement reliably in 2D)
- VBT fatigue detection

---

## Section J: Key References & Sources

**Request Gemini to cite:**

1. **Biomechanics textbooks:**
   - Neumann, D.A. *Kinesiology of the musculoskeletal system* (standard anatomy reference)
   - McGill, S. *Low back disorders* (spinal safety in squats)

2. **NASM/NSCA Standards:**
   - NASM Optimum Performance Training (OPT) Model — squat assessments
   - NSCA *Essentials of Strength Training and Conditioning* (WG4-specific)

3. **Recent peer-reviewed studies (2018–2025):**
   - M3GYM: "A Large-Scale Multimodal Multi-view Multi-person Pose Dataset..." (Xu et al., CVPR 2025) — cite if squat data available
   - Pose Trainer (Chen & Yang, 2020) — squat form correction
   - Any recent meta-analyses on squat biomechanics

4. **Commercial systems (if published methodologies exist):**
   - Fitbod squat scoring (if whitepaper available)
   - Athlytic rep-counting approach

5. **Mobile pose estimation:**
   - ML Kit / MediaPipe accuracy studies vs. VICON gold-standard
   - Studies on 2D-to-3D angle reconstruction error

---

## Deliverable Format

**Gemini Deep Research should provide:**

1. **Synthesis document** (~5,000–8,000 words)
   - Key findings per section (A–J)
   - Consensus thresholds (with sources)
   - Recommended FSM parameters
   - Open questions flagged

2. **Thresholds table** (CSV-ready for codegen)
   - Columns: error type, formula, threshold, CI-low, CI-high, variant, view, source

3. **Data-collection checklist** (actionable for FiTrack team)
   - Recording protocol
   - Annotation scheme
   - Quality gates

4. **Implementation pseudocode** (optional)
   - Angle computation formulas
   - Form-error detection logic
   - FSM transitions

---

## Success Criteria

This research is **complete and useful when it provides:**

- ✅ **Numeric FSM thresholds** (angle values with sources)
- ✅ **Form-error metrics** (formulas + threshold values)
- ✅ **95% confidence intervals** (shows uncertainty)
- ✅ **Squat-variant-specific adjustments** (if recommending > 1 variant)
- ✅ **Alignment with FiTrack's 15-FPS, 2D-pose, mobile constraints**
- ✅ **Data-collection plan** to derive thresholds empirically
- ✅ **Cited sources** (peer-reviewed, reputable)
- ✅ **Clear scope** (MVP vs. future extensions)

---

## Tone & Approach

- **Rigor:** Prioritize biomechanically sound, peer-reviewed sources over intuition
- **Practicality:** Acknowledge mobile constraints (2D, real-time, on-device)
- **Transparency:** Flag assumptions, limitations, open research gaps
- **Actionability:** Every recommendation should be implementable in Dart/Flutter code

---

**END OF PROMPT**
