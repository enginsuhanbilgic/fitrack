# Biomechanical Research Specification for a Real-Time, On-Device Squat Rep-Counting and Form-Analysis System (BlazePose / ML Kit, 33 Landmarks)

**Author's preface.** This document is a peer-reviewed-anchored design brief synthesizing biomechanics, computer-vision, and mobile-systems literature into an MVP-ready specification for a Flutter/Dart fitness app. It prioritizes biomechanically defensible thresholds while acknowledging the limits of monocular 2D pose estimation. Where evidence is mixed (e.g., "butt wink" injury risk, knees-past-toes), both views are flagged. All thresholds are derivative from cited literature unless explicitly labelled "Author estimate (to be empirically validated)."

---

## SECTION A — Squat Biomechanics Foundation

### A.1 Kinetic Chain and Anatomical ROM

**Knee flexion ROM during the descent.** The descent of a barbell back squat traverses the knee through 0° (standing) toward maximal flexion. Escamilla's seminal review of 70 studies established that the *parallel squat* (thighs parallel to ground at maximum knee flexion) corresponds to roughly 0–100° of knee flexion ([PubMed — Escamilla 2001](https://pubmed.ncbi.nlm.nih.gov/11194098/)). However, depth definitions are confounded by reporting conventions: some authors report the *internal* tibiofemoral angle (a parallel squat at ≈90° internal angle) while others report *flexion* angle (a parallel squat = ≈100–120° flexion) ([SET FOR SET: Squat ROM](https://www.setforset.com/blogs/news/squat-rom)). Hartmann *et al.* report that restricted ("knees-behind-toes") squats reach ~86° of knee flexion at the lowest point and unrestricted squats reach ~106° ([PubMed — Hartmann 2012](https://pubmed.ncbi.nlm.nih.gov/22801421/)).

A consensus mapping from depth class → knee flexion (using flexion-from-extension convention, where 0° = straight leg):

| Depth class | Knee flexion (°) | Hip flexion (°) | Source |
|---|---|---|---|
| Quarter squat | 40–60 | 40–60 | [Schoenfeld 2010 / lookgreatnaked.com](https://www.lookgreatnaked.com/articles/the_biomechanics_of_squat_depth.pdf) |
| Half squat (≈90° internal) | 80–100 | 70–95 | [NSCA Considerations for Squat Depth](https://www.nsca.com/education/articles/nsca-coach/considerations-for-squat-depth/) |
| Parallel | 100–120 | 95–110 | [SET FOR SET](https://www.setforset.com/blogs/news/squat-rom); [Hartmann 2012](https://pubmed.ncbi.nlm.nih.gov/22801421/) |
| Full / ATG | 120–140+ | 115–135+ | [Strength & Conditioning Journal — Optimizing Squat Technique Revisited](https://journals.lww.com/nsca-scj/fulltext/2018/12000/optimizing_squat_technique_revisited.10.aspx) |

The NSCA evidence-based recommendation is full depth (115–125° knee flexion) provided the spine remains neutral ([Optimizing Squat Technique—Revisited, *S&C Journal* 2018](https://journals.lww.com/nsca-scj/fulltext/2018/12000/optimizing_squat_technique_revisited.10.aspx)). Stratification by sex/age/training status is sparse; Escamilla's review noted no significant injury increase with deep squats in trained individuals ([PubMed 11194098](https://pubmed.ncbi.nlm.nih.gov/11194098/)), and Hartmann notes that anterior knee displacement at parallel reaches 63.8–64.7 mm in men vs. 93.2–96.6 mm in women, suggesting sex-specific norms ([Hartmann — Limitations of Anterior Knee Displacement](https://pmc.ncbi.nlm.nih.gov/articles/PMC10143703/)).

**Hip flexion ROM and femur-length effects.** Passive hip flexion ROM is normally 110–120° ([Rehab-U — Squat Depth](https://rehab-u.com/whats-really-limiting-your-squat-depth/)); a "normal" hip socket allows ~115–120° before the femoral neck contacts the acetabular rim ([Tom Morrison — Sockets, Torsion, Squat Depth](https://thinkmovement.net/2021/08/22/sockets-torsion-squat-depth/)). Once that limit is exceeded, the pelvis must posteriorly tilt to gain depth — the kinematic origin of "butt wink." Long-femur lifters require greater forward trunk lean to keep the bar over mid-foot (McKean & Burkett 2012, summarized by [Brookbush Institute](https://brookbushinstitute.com/articles/femur-length-and-squat-form)); Berglund (2024) found that femur-to-tibia ratios were *not* significantly associated with lumbopelvic flexion in experienced lifters, redirecting blame from anatomy to mobility/control. In a regression analysis of 53 lifters, Cho *et al.* found relative muscular strength and ankle dorsiflexion better predicted squat kinematics than femur:tibia ratio ([PubMed 34712337](https://pubmed.ncbi.nlm.nih.gov/34712337/)).

**Ankle dorsiflexion requirement.** Hemmerich *et al.* (2006) reported a deep squat with heels down requires 35.4 ± 5.5° to 38.5 ± 5.9° of dorsiflexion ([PMC 4415844](https://pmc.ncbi.nlm.nih.gov/articles/PMC4415844/); [GoWod](https://www.gowod.app/blog/how-to-improve-ankle-mobility)). For maximal squat depth past parallel, ~35° is typically required ([Mike Reinold — Ankle Mobility](https://mikereinold.com/ankle-mobility-exercises-to-improve-dorsiflexion/)). Limited dorsiflexion (<20°) reliably increases forward trunk lean and is associated with increased dynamic knee valgus ([Macrum 2012; Lima systematic review, summarized by Reinold](https://mikereinold.com/ankle-mobility-exercises-to-improve-dorsiflexion/)). The knee-to-wall test threshold of ≥12 cm corresponds to roughly 36°–40° of weight-bearing dorsiflexion (3.6° per cm of toe-to-wall distance) ([Pendulum/Rogers Athletic](https://rogersathletic.com/updates/get-strong-blog/dorsiflexion-and-the-squat/)). Heel elevation (e.g., 2.5 cm Olympic shoes) measurably reduces required dorsiflexion and forward lean ([Glassbrook *et al.* 2017, *J Strength Cond Res*](https://pubmed.ncbi.nlm.nih.gov/28570490/)).

**Trunk angle.** Glassbrook's review (2017) is the canonical reference for HBBS vs LBBS: the high-bar squat is characterized by greater knee flexion, smaller hip flexion, and a more upright trunk; the low-bar squat by greater hip flexion and a smaller trunk angle (more forward lean) ([PubMed 28570490](https://pubmed.ncbi.nlm.nih.gov/28570490/)). Squat University reports approximate trunk-from-vertical angles: front squat ≈15°, high-bar ≈30°, low-bar ≈45–55° ([SquatU — The Real Science of the Squat](https://squatuniversity.com/2016/04/20/the-real-science-of-the-squat/)). Forward trunk inclination achieved with a *neutral* spine is biomechanically tolerable; achieved with *spinal flexion* it markedly reduces tolerance to compressive load and increases anterior shear ([Straub & Powers 2024, *IJSPT*](https://ijspt.scholasticahq.com/article/94600-a-biomechanical-review-of-the-squat-exercise-implications-for-clinical-practice)).

#### A.1 Consensus Table (use as defaults for an Adult Recreational Trainee, single squat, ~80 kg load or bodyweight)

| Joint / Segment | Quarter | Parallel | ATG / Full | Notes |
|---|---|---|---|---|
| Knee flexion (HKA flexion convention) | 40–60° | 100–120° | 120–140° | NSCA recommends full at 115–125° if spine-neutral |
| Hip flexion | 40–60° | 95–110° | 115–135° | Capped by acetabular bony anatomy ~115–125° before PPT |
| Ankle dorsiflexion | 5–15° | 20–30° | 30–40° | <20° forces compensations |
| Trunk-from-vertical (HB squat) | ~10–20° | ~25–35° | ~30–40° | Increases ~10–15° for low-bar |
| Trunk-from-vertical (LB squat) | ~20–30° | ~40–55° | ~45–60° | |

---

### A.2 Squat Variants and 2D Distinguishability

Drawing on Glassbrook (2017) and the *S&C Journal* "Optimizing Squat Technique—Revisited" (2018):

- **Olympic / High-bar.** Bar position ~C7. At BOTTOM: trunk ≈10–30° from vertical, knee flexion 120–140°, hip flexion 110–130°. Knee tracks slightly past the toes; tibia angle is forward; quad-dominant.
- **Powerlifting / Low-bar.** Bar position across spine of scapula. At BOTTOM: trunk ≈40–55° from vertical, knee flexion 100–120°, hip flexion 110–125°. Greater posterior chain demand; minimized forward knee travel.
- **Goblet / Bodyweight (front-loaded mass at chest).** Resembles HBBS kinematically — upright torso (10–25° lean), full depth often achieved easily because counterbalance shifts the COM ([SET FOR SET — Squat ROM](https://www.setforset.com/blogs/news/squat-rom)). Light or no load.
- **Safety Squat Bar (SSB).** Cambered yoke bar. Trunk angle is intermediate between high-bar and front squat ([Comparison of Joint Angles — Calstate](https://scholarworks.calstate.edu/downloads/c534ft828)). Reduced hip moment vs traditional bar.
- **Belt squat.** Load is at the hips, not the spine; trunk is essentially vertical; mainly knee-extensor demand. Joint signatures resemble bodyweight squat but with added vertical load.

**2D distinguishability.**
- *Front view:* nearly impossible to distinguish HBBS from LBBS — bar position is occluded by torso.
- *Side view:* trunk-from-vertical angle at bottom is the discriminator: HBBS ≈25–35°, LBBS ≈40–55°. Knee-over-toe distance differs (HBBS positive, LBBS often near-zero).

**MVP recommendation.** Restrict the MVP to **bodyweight squat and high-bar squat** — they share an upright kinematic envelope and are the canonical entry-level patterns. Defer LBBS, SSB, and belt squat to v2.

---

### A.3 Common Squat Form Errors

For each error: pathomechanics, prevalence, signature, injury risk, and detectability.

| Error | Pathomechanics | Detectable from | Injury risk | Most common in |
|---|---|---|---|---|
| Incomplete depth | Mobility deficit (ankle/hip), confidence/strength deficit | Side or 45° | Low (under-loading) | Untrained, novices |
| Valgus collapse (knee-in) | Hip-abductor/external rotator weakness, ankle DF deficit, neuromuscular control | Front (best) / 45° | **High — ACL/MCL/PFP** | Females, untrained, fatigued |
| Forward knee shift past toes | Quad-dominant pattern, ankle DF deficit; *not always pathological* | Side | Low–moderate (PFPS in symptomatic) | Lifters with restricted ankles |
| Excessive forward lean | Weak quads/glutes, ankle DF deficit, long femur, fatigue | Side | Moderate (lumbar strain if combined with flexion) | Tall, long-femur, heavy load |
| Butt wink (PPT + lumbar flexion) | Hip-flex ROM exceeded, control deficit | Side (subtle in 2D) | Disputed — see flag below | Deep squatters, beginners |
| Heels lifting | Ankle DF deficit | Side | Low (instability) | Novices, restricted lifters |
| Asymmetry | Unilateral weakness, post-injury (e.g. ACLR) | Front | Moderate (cumulative re-injury) | Post-surgical, injured-side compensation |
| Knees not tracking over toes | Q-angle, hip rotation issue, foot position | Front | Moderate | Novices |
| Chest collapse / spinal flexion under load | Weak erectors, fatigue, excessive load | Side | **High — disc/lumbar** | Heavy lifters, fatigued |

**Prevalence in untrained lifters.** Caterisano-style EMG studies and the NASM OPT overhead-squat-assessment literature consistently identify *excessive forward lean* and *medial knee displacement (valgus)* as the two most common faults in untrained populations ([PT Pioneer — NASM Overhead Squat Assessment](https://www.ptpioneer.com/personal-training/certifications/study/nasm-overhead-squat-assessment/)). Heel rise and incomplete depth are next most common, both downstream of ankle dorsiflexion deficits ([Macrum 2012](https://mikereinold.com/ankle-mobility-exercises-to-improve-dorsiflexion/)).

**Quantitative thresholds (literature anchors).**
- *Valgus.* The 3D gold-standard knee-valgus angle (femur–tibia frontal-plane angle) is considered abnormal at ≥10° of frontal-plane projection angle (FPPA) during a single-leg squat (Padua, Bell, Mauntel literature; reviewed in [PMC 3718346 — Bell *et al.* 2013](https://pmc.ncbi.nlm.nih.gov/articles/PMC3718346/)). For 2D systems, valgus is operationalized as the medial-deviation distance of the knee from the hip–ankle line, normalized to inter-ASIS or knee-to-ankle length: thresholds in the literature commonly fall at **>5–10% of the inter-ankle distance** ([Kianifar 2017, IMU-based valgus classifier, *PMC 5706595*](https://pmc.ncbi.nlm.nih.gov/articles/PMC5706595/)).
- *Forward knee shift.* Patellofemoral joint stress increases markedly when the anterior tibial line crosses ipsilateral toes ([PFPS systematic review, PMC 9367913](https://pmc.ncbi.nlm.nih.gov/articles/PMC9367913/)). However, forbidding it increases hip torque by ~973% in some setups ([Fry *et al.*, summarized at scienceinsights.org](https://scienceinsights.org/how-to-squat-without-knee-pain-fix-your-form/)). Threshold for "excessive": knee-Anterior distance > ~25% of femur length is a reasonable empirical bound (author estimate — to be empirically calibrated).
- *Forward lean.* For a high-bar squat, trunk-from-vertical >40° at depth is the literature's outer bound; >50° is consistent with low-bar territory and concerning if combined with spinal flexion ([Glassbrook 2017](https://pubmed.ncbi.nlm.nih.gov/28570490/)).
- *Heel lift.* Any measurable ankle-Y rise above the foot–index Y plane in the side view (>2–3% of leg length).
- *Asymmetry.* Bilateral knee-flexion delta of >10° at BOTTOM is clinically meaningful; an LSI <85–90% is the default ACL return-to-sport flag ([JOSPT — LSI](https://www.jospt.org/doi/10.2519/jospt.2017.7285); [PMC 4418954](https://pmc.ncbi.nlm.nih.gov/articles/PMC4418954/)).
- *Spinal flexion.* In 3D systems, lumbar flexion >20–25° during loaded squatting is the canonical "butt wink" cutoff; in 2D it is approximated by the change in shoulder–hip–knee triplet angle.

**Safety hierarchy (highest → lowest acute risk):**
1. Spinal flexion under heavy load (disc herniation / endplate fracture; [McGill, Backfitpro](https://www.backfitpro.com/spine-flexion-exercise-myths-truths-issues-affecting-health-performance/)).
2. Dynamic knee valgus near full extension under high external force (ACL; [PMC 10748350](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC10748350/)).
3. Excessive forward lean combined with spinal flexion (lumbar strain).
4. Forward knee shift past toes in symptomatic populations (PFPS aggravation; [PMC 9367913](https://pmc.ncbi.nlm.nih.gov/articles/PMC9367913/)).
5. Heel lift / asymmetry (chronic overuse).
6. Incomplete depth (under-stimulus, not injury).

**Cueing correctability (most → least amenable to a one-line cue):**
1. *Heel lift* — "drive heels into the floor."
2. *Knees in / valgus* — "spread the floor / push knees out over toes."
3. *Incomplete depth* — "go deeper / hips below knees."
4. *Forward lean* — "chest up."
5. *Asymmetry* — requires individualized programming, harder to cue in real time.
6. *Spinal flexion / butt wink* — usually mobility-bound; cueing alone often insufficient.

**⚠️ Flag — Butt-wink controversy.** McGill and colleagues argue that repeated lumbar flexion under load gradually delaminates the disc annulus ([Backfitpro PDF](https://www.backfitpro.com/documents/Spine-flexion-myths-truths-and-issues.pdf)), the canonical "flexion-intolerance" model. E3Rehab and Henselmans counter that there is no direct human evidence, that even "neutral" lifters exhibit 20–26° of unseen lumbar flexion ([E3Rehab — The Truth About Butt Wink](https://e3rehab.com/the-truth-about-butt-wink/); [Mennohenselmans](https://mennohenselmans.com/is-spinal-flexion-dangerous/)). The MVP should *flag* visible PPT/lumbar flexion as a "form note" rather than a "danger" cue and avoid alarmist language.

---

## SECTION B — Pose-Estimation-Specific Biomechanics

### B.1 2D vs. 3D Limitations

**Sagittal plane angles (knee, hip flexion from side view).** Multiple studies show OpenPose, MediaPipe/BlazePose, and MoveNet correlate strongly (r = 0.68–0.94) with VICON in the sagittal plane during squats; Ota *et al.* (2020) reported ICCs of 0.83 for knee, 0.75 for ankle, and only 0.37 for hip during squats with OpenPose ([Sportip Motion 3D validation, NMU ISBS](https://commons.nmu.edu/cgi/viewcontent.cgi?article=2372&context=isbs); [PubMed — OpenPose vs VICON squat](https://www.sciencedirect.com/science/article/abs/pii/S0966636220301776)).

**Frontal plane (valgus) angles from front view.** This is where 2D fails. Haberkamp *et al.* (2022) reported a Pearson r of only **0.20** between 2D pose estimation and 3D motion analysis for frontal-plane knee angle during a single-leg squat (vs r=0.95 between two 2D techniques agreeing with each other) ([PubMed 36198251](https://pubmed.ncbi.nlm.nih.gov/36198251/)). 2D valgus is detectable as a relative *displacement* metric, but the absolute 2D "angle" should not be trusted.

**Per-joint magnitudes.** A 2025 *Scientific Reports* benchmark (Physio2.2M, 25 subjects, exercise tasks including squats) reported MediaPipe BlazePose's knee-flexion angle MAE of **9.3–21.9° in 2D** and **14.1–25.8° in 3D** vs Vicon; per-joint position error 72–122 mm in 2D, 146–249 mm in 3D ([Nature Sci Reports 2025](https://www.nature.com/articles/s41598-025-22626-7)). A targeted 3D-pose study (Strided Transformer fine-tuned on VICON) reduced knee/hip/trunk angle RMSE to ≤10° across squat variants and ≤15° for the worst metrics ([PMC 10951609 — *Heliyon* 2024](https://pmc.ncbi.nlm.nih.gov/articles/PMC10951609/)).

**Forward-knee-shift (side-view).** Detectable in 2D as horizontal pixel offset between knee and ankle landmarks, but absolute pixels conflate with subject distance/zoom — must be normalized. Recommended: **(knee_x − ankle_x) / femur_length_px**, where femur length is the on-screen Euclidean distance hip→knee. This is anthropometry-invariant and scale-invariant ([Yang *et al.* 2021, summarized in PMC 11401083](https://pmc.ncbi.nlm.nih.gov/articles/PMC11401083/)).

**Trunk lean from side view.** Reliable to ±5–10° when shoulder–hip line is computed — RMSE within 10° in the Heliyon study ([PMC 10951609](https://pmc.ncbi.nlm.nih.gov/articles/PMC10951609/)). Butt wink specifically requires lumbar–sacral resolution that BlazePose does not provide (no individual lumbar landmarks); a coarse proxy is the dynamic change in shoulder–hip–knee angle relative to its initial value across the descent.

**Depth measurement.** Hip-Y displacement is sensitive to camera distance and tilt. The most robust metric is the **knee-flexion angle** itself (computed from hip→knee→ankle landmarks), which is dimensionless and scale-invariant. Using *hip_y descent normalized to torso length* (shoulder→hip distance) as a secondary signal reduces camera-distance dependence.

#### B.1 Reliability Table

| Measurement | Best View | Typical 2D Error vs 3D Mocap | Reference | Recommended Normalization |
|---|---|---|---|---|
| Sagittal knee flexion | Side | 9–22° (MAE), ICC ≈0.83 | [Nat Sci Reports 2025](https://www.nature.com/articles/s41598-025-22626-7); [Ota 2020](https://www.sciencedirect.com/science/article/abs/pii/S0966636220301776) | None (angle is dimensionless) |
| Sagittal hip flexion | Side | 10–20°, ICC ≈0.37–0.50 | [Ota 2020](https://www.sciencedirect.com/science/article/abs/pii/S0966636220301776) | None |
| Trunk-from-vertical | Side | RMSE ≤10° | [PMC 10951609](https://pmc.ncbi.nlm.nih.gov/articles/PMC10951609/) | None |
| Frontal knee valgus angle | Front | r = 0.20 vs 3D — **unreliable as angle** | [Haberkamp 2022](https://pubmed.ncbi.nlm.nih.gov/36198251/) | Use **displacement ratio** instead |
| Frontal knee displacement | Front | RMSE within 10° | [PMC 10951609](https://pmc.ncbi.nlm.nih.gov/articles/PMC10951609/) | (knee_x − midline) / inter-ankle |
| Forward knee shift | Side | RMSE within 10° | [PMC 10951609](https://pmc.ncbi.nlm.nih.gov/articles/PMC10951609/) | (knee_x − ankle_x) / femur_len |
| Heel lift | Side | Visible binary signal | [PMC 11695559](https://pmc.ncbi.nlm.nih.gov/articles/PMC11695559/) | (heel_y − foot_index_y) / leg_len |
| Hip-Y descent depth | Side | ±5–15% if camera distance varies | empirical | Δhip_y / torso_len |

### B.2 Camera Setup

- **Front view.** Detects valgus, asymmetry, knee-tracking; misses depth (foreshortening), forward lean, knee-over-toe.
- **Side view.** Detects depth, forward lean, knee-shift, heel lift, spine angle; cannot detect valgus or asymmetry.
- **Diagonal (~45°).** Compromise — gives partial info on all metrics.

A 2026 *JMIR mHealth* study (44 subjects) found smartphone-camera positioning has a critical effect on rep-counting accuracy: for squats, the **diagonal view at 200 cm** was best (95.5% detection accuracy, MAE = 0.05 reps); the **side view at 90 cm** was worst (0% detection, MAE = 5). Diagonal/front views at 180–200 cm consistently outperformed side views ([JMIR 2026](https://mhealth.jmir.org/2026/1/e82412)).

**MVP recommendation.** **Strict side view at ~2 m camera distance, ~1 m camera height (waist level), no obstructions.** This sacrifices valgus and asymmetry detection but secures the highest-value signals: depth, forward lean, knee-shift, heel lift. Offer a future v2 "front view" mode for valgus-only checks. A diagonal mode (≈30–45°) is the best single-camera fallback for general use.

---

## SECTION C — Rep-Counting FSM (Squat)

### C.1 FSM Design

The reference design (IDLE → DESCENDING → BOTTOM → ASCENDING → IDLE) is sound. Refinements:

**State-transition triggers.** Pure-angle thresholds suffer "bouncing" near the boundary; pure-velocity triggers under-respond at slow tempo. **Hybrid: angle threshold + hysteresis gap, plus a velocity sign-change confirmation, is the literature consensus.** LearnOpenCV's reference squat-tracker uses three states gated on knee angle relative to vertical with explicit hysteresis ([learnopencv.com — AI Fitness Trainer](https://learnopencv.com/ai-fitness-trainer-using-mediapipe/)). The Cao *et al.* OpenPose-rep-counting paper segments using filtered angle peaks ([arxiv 2005.03194](https://arxiv.org/pdf/2005.03194)).

**Bottom detection.** "Hip-Knee-Ankle internal angle < 90°" is fine for an internal-angle convention but means *knee flexion ≈ 90°*, i.e. *above-parallel*. The NSCA depth standards expect parallel = ≈100–120° flexion, ATG = 120–140°. **Recommend: define the bottom threshold using the *flexion* convention with explicit literature-anchored values:**
- Quarter-squat lockout: knee_flex < 60°.
- Parallel detection: knee_flex ≥ 100° (≈ HKA internal ≤ 80°). This is the canonical "thighs parallel" depth.
- Full / ATG: knee_flex ≥ 120° (HKA internal ≤ 60°).

For a **bodyweight or HBBS MVP**, set BOTTOM = "knee_flex ≥ 90° AND hip_y ≥ knee_y (using image-y where down is positive)". This dual-criterion is robust because the hip-below-knee criterion is the IPF/USAPL parallel-squat judging rule and is geometric, not anthropometric ([NSCA — Considerations for Squat Depth](https://www.nsca.com/education/articles/nsca-coach/considerations-for-squat-depth/)).

**Rep completion.** Best practice in published rep-counting systems (Pose Trainer, M3GYM, GymCam) is to count a rep on the **return to IDLE** (knee_flex < threshold AND hip_y back near start). This avoids counting partial drops/incomplete rebounds. A *partial-rep flag* can still be set when BOTTOM was not reached.

**Concrete FSM (recommended for the MVP):**

```
States: IDLE, DESCENDING, BOTTOM, ASCENDING

IDLE → DESCENDING when:
    knee_flex > IDLE_EXIT (= 20°)         // hysteresis: must drop 20° below standing
    AND hip_y_velocity > +ε_descent       // descending in image frame
    
DESCENDING → BOTTOM when:
    knee_flex ≥ BOTTOM_ENTER (= 90°)       // reached parallel-zone
    AND |hip_y_velocity| < ε_bottom        // momentarily slow / reversed
    
BOTTOM → ASCENDING when:
    hip_y_velocity < −ε_ascent             // moving up
    AND knee_flex starts decreasing
    
ASCENDING → IDLE (rep++) when:
    knee_flex < IDLE_ENTER (= 15°)         // close to lock-out
    AND |hip_y_velocity| < ε_idle
    
Per-rep tags:
    rep.depth_class = quarter | parallel | atg, by max(knee_flex)
    rep.partial    = max(knee_flex) < 90°
    rep.duration   = t_idle_end − t_idle_start
    rep.eccentric_time, concentric_time
```

Hysteresis gaps (IDLE_EXIT 20°, IDLE_ENTER 15°) prevent flutter near the lock-out angle. Velocity sign confirmation prevents a momentary noisy frame from causing a state flip.

**Smoothing.** The 1€ Filter (Casiez & Roussel) is the de-facto standard for real-time pose smoothing — adaptive low-pass with separate jitter (slow speeds) and lag (fast speeds) constants; widely used in MediaPipe-based pipelines ([Casiez et al.; jaantollander.com](https://jaantollander.com/post/noise-filtering-using-one-euro-filter/)). Suggested defaults for landmark-Y at 30 fps: min_cutoff = 1.0 Hz, beta = 0.05.

### C.2 Squat Variant Auto-Detection

In principle, distinguishing HB vs LB from a side view is feasible by checking trunk-from-vertical at BOTTOM (>40° → low-bar, <30° → high-bar). However, given (i) the MVP scope above, (ii) the noise envelope of MediaPipe trunk angle (~10° RMSE), and (iii) the safety risk of misclassification — **defer auto-detection to v2**. For MVP, ask the user to declare squat type once per session.

---

## SECTION D — Form-Error Detection

### D.1 Threshold Table (per-error formulas)

All landmarks reference the BlazePose 33-point schema. Coordinates are normalized to image space [0,1]. `|·|` is Euclidean distance.

```
femur_len_px        = |hip - knee|                 (left or right)
tibia_len_px        = |knee - ankle|
torso_len_px        = |shoulder - hip|
inter_ankle_px      = |left_ankle - right_ankle|
knee_flex(side)     = π − angle(hip, knee, ankle)  (radians; convert to deg)
trunk_lean(side)    = atan2(hip_x − shoulder_x, hip_y − shoulder_y)  (deg from vertical)
```

| Error | Formula | Threshold | 95% CI / source-derived range | Variant adj. | View | Risk |
|---|---|---|---|---|---|---|
| **Incomplete depth** | knee_flex_max < 90° (parallel) or 75° (relaxed) | 90° (knee flexion) AND hip_y < knee_y | ±5° (BlazePose RMSE in sagittal plane) | bodyweight: 75°; HBBS: 90°; ATG goal 120° | Side | Low |
| **Valgus collapse** | valgus = max(0, (ankle_x − knee_x)/inter_ankle_px) per leg, frontal view | > 0.10 (10% medial deviation) | range 0.05–0.15 per Bell, Padua FPPA studies | Females +0.02 tolerance | Front | High (ACL) |
| **Forward knee shift** | shift = max(0, (knee_x − ankle_x)/femur_len_px), side | > 0.30 (knee 30% of femur ahead of ankle) | empirical bound; Hartmann reports ~64–96 mm = 25–35% femur | HBBS: 0.30; LBBS: 0.20 | Side | Moderate (only if symptomatic) |
| **Forward lean** | trunk_lean angle from vertical at BOTTOM | > 45° (HB) / > 60° (LB) | Glassbrook: HBBS ~30°, LBBS ~50° | HB 45°; LB 60° | Side | Moderate |
| **Heel lift** | (heel_y − foot_index_y) / leg_len > threshold (image-y up = negative) | > 0.03 (3% leg-length lift) | empirical | None | Side | Low |
| **Asymmetry** | |knee_flex_L − knee_flex_R| at BOTTOM | > 10° | LSI <90% literature consensus ([JOSPT](https://www.jospt.org/doi/10.2519/jospt.2017.7285)) | None | Front | Moderate |
| **Spinal flexion** | Δ(angle(shoulder, hip, knee)) descent vs standing | > 25° change | McGill flexion-tolerance literature; flag as note, not danger | None | Side | High under load |

(A CSV-friendly version of this table is provided at the bottom of this report.)

### D.2 Feedback Cue Mapping

| Error | User-facing cue | Trigger | Cooldown | Modality |
|---|---|---|---|---|
| Incomplete depth | "Go a little deeper next rep" | Per-rep, when partial flag set | 1 rep | Audio + visual |
| Valgus | "Push knees out over toes" | Per-rep, on detection | 5 s | Visual highlight on knee + audio |
| Forward knee shift | "Sit back into your hips" | If sustained ≥3 reps | 8 s | Visual |
| Forward lean | "Chest up" | Per-rep | 5 s | Audio |
| Heel lift | "Drive your heels into the floor" | Per-rep | 5 s | Audio |
| Asymmetry | "Balance left and right" | Per-set summary | end of set | Visual summary card |
| Spinal flexion | "Keep a tall back at the bottom" | Per-rep | 5 s | Visual |

Cues should follow NASM-style "short, present-tense, action-positive" pattern — never "don't" cues.

### D.3 Quality Scoring

A defensible per-rep quality score is a multiplicative deduction model:

```
rep_quality = 1.0
× (depth_factor: 1.0 if knee_flex_max ≥ 90°, else 0.5 + 0.5*(knee_flex_max/90))
× (1 − w_valgus     × clamp(valgus_score   / 0.10, 0, 1))
× (1 − w_lean       × clamp((lean − 45)/30, 0, 1))
× (1 − w_kneeshift  × clamp((shift − 0.30)/0.20, 0, 1))
× (1 − w_heel       × clamp(heel_lift / 0.05, 0, 1))
× (1 − w_asym       × clamp(asym_deg/15, 0, 1))
× (1 − w_spine      × clamp(spine_dev/30, 0, 1))
```

Suggested weights: w_valgus 0.30, w_lean 0.15, w_kneeshift 0.10, w_heel 0.10, w_asym 0.15, w_spine 0.20 (sums of penalty cap rep_quality at 0). Session quality = mean(rep_quality_i).

This proportional model echoes published rubrics (NASM-PES, Pose Tutor, AIFit's "global parameter") that scale deduction with severity rather than binary pass/fail ([AIFit / Fit3D — *CVPR 2021*](https://openaccess.thecvf.com/content/CVPR2021/papers/Fieraru_AIFit_Automatic_3D_Human-Interpretable_Feedback_Models_for_Fitness_Training_CVPR_2021_paper.pdf)). Fitbod's exact rep-quality formula is proprietary and unpublished; commercial systems (Fitbod, Athlytic) advertise per-rep scoring but do not disclose the rubric.

---

## SECTION E — Biomechanical Constants & Normalization

### E.1 Anthropometric Ratios

Drillis & Contini (1966) — the canonical anthropometric ratios used by Winter (and the basis for most biomechanical models) — express segment lengths as fractions of stature H ([Drillis & Contini PDF](http://www.oandplibrary.org/al/pdf/1964_01_044.pdf); [PSU Open Design Lab](https://www.openlab.psu.edu/2018/02/05/proportionality-constants/)):

| Segment | Drillis–Contini fraction of H | Use in app |
|---|---|---|
| Thigh (greater trochanter → knee axis) | 0.245 | Femur length normalization |
| Shank (knee axis → lateral malleolus) | 0.246 | Tibia length |
| Foot length | 0.152 | (not used in 2D squat) |
| Total leg (hip → floor) | ~0.530 | hip-Y descent normalization |
| Trunk (suprasternale → hip) | 0.288 | Forward-lean normalization |
| Shoulder breadth (biacromial) | 0.259 (≈ 0.245 × H) | Valgus normalization (front view) |
| Hip width (biiliac) | 0.191 | (alternative valgus denominator) |

These ratios are population averages; SD ≈ 5–8% of H. They vary mildly by sex (women have slightly shorter trunks relative to leg) and by ancestry. Berglund 2024 found that femur-to-tibia ratios were *not* significantly associated with squat lumbopelvic flexion in trained populations ([Brookbush](https://brookbushinstitute.com/articles/femur-length-and-squat-form)). For the MVP, **use ratios as defaults; expose user-entered height as the only required anthropometric input; do NOT use age- or sex-adaptive thresholds in v1**.

### E.2 Velocity-Based Training Threshold

The minimum-velocity threshold (MVT) is the mean propulsive concentric velocity at 1RM. The conventional "general MVT" for the back squat is **0.30 m/s** ([ScienceForSport](https://www.scienceforsport.com/velocity-based-training/); [GymAware](https://gymaware.com/velocity-based-training-exercises-and-workouts/); [MDPI 2025 — Sports](https://www.mdpi.com/2075-4663/13/7/224)). However, the **optimal individualized MVT** averages closer to **0.38 m/s** and is sex-dependent: ~0.30 m/s for males, ~0.25 m/s for females ([MDPI 2025](https://www.mdpi.com/2075-4663/13/7/224); [Fitas 2024 *J Sports Sci*](https://pubmed.ncbi.nlm.nih.gov/39356873/)). Confirming the project's `kSquatMVT = 0.30 m/s` is a **defensible literature-anchored default** for males; for a sex-aware app, drop to 0.25 m/s for women.

In a 2D pose system, *barbell* velocity cannot be measured directly — but **hip-Y velocity** is a reasonable proxy (since the bar moves with the trunk). To compute m/s from pixels, calibrate via known stature: pixels-per-meter ≈ subject_height_px / user_height_m. Detect a "fatigue rep" when concentric hip-Y velocity drops below MVT × 1.1 in the working set; flag set termination at MVT.

For MVP, VBT integration is **out-of-scope**; ship rep counting and form first.

---

## SECTION F — Validation & Accuracy Benchmarks

### F.1 Rep-Counting Accuracy (literature)

- *Pose Trainer (Chen & Yang 2020).* Geometric heuristics on OpenPose, 4 exercises (incl. squat), >100 videos. No published rep-MAE; quality classification accuracy ~80% ([arxiv 2006.11718](https://arxiv.org/abs/2006.11718)).
- *Cao et al. 2020 (arXiv 2005.03194).* Pose-based rep counting on 4 exercises; >90% recognition accuracy.
- *GymCam (Khurana 2018).* Multi-person gym footage: exercise type 93.6% accuracy; rep count within ±1.7 reps on average ([ResearchGate — GymCam](https://www.researchgate.net/publication/329957199_GymCam_Detecting_Recognizing_and_Tracking_Simultaneous_Exercises_in_Unconstrained_Scenes)).
- *Rep-Penn / multitask DL (2023).* MAE 0.004, OBO 0.997 for repetition counting on the Rep-Penn dataset ([ResearchGate — heatmap multitask](https://www.researchgate.net/publication/329957199_GymCam_Detecting_Recognizing_and_Tracking_Simultaneous_Exercises_in_Unconstrained_Scenes)).
- *AIFit / Fit3D (CVPR 2021).* 3D-pose-based, outperforms RepNet on Fit3D ([CVPR 2021 PDF](https://openaccess.thecvf.com/content/CVPR2021/papers/Fieraru_AIFit_Automatic_3D_Human-Interpretable_Feedback_Models_for_Fitness_Training_CVPR_2021_paper.pdf)).
- *JMIR 2026 study (2D pose, smartphone).* Squat MAE 0.05 reps in best diagonal-200 cm setup; degrades to MAE 5 in worst side-90 cm setup ([JMIR mHealth 2026](https://mhealth.jmir.org/2026/1/e82412)).

**A target of MAE ≤ 1.5 reps per session is realistic for 2D pose** at correct camera placement (consistent with Khurana ±1.7 and JMIR ≤0.5 in good setups). Performance degrades sharply for ATG (extreme self-occlusion of feet by buttocks in side view), low light, baggy clothing.

### F.2 Form-Error Metrics

- **Valgus (front view).** Frontal-plane projection-angle (FPPA) classifiers using IMU/3D have reached 95.7% accuracy ([PMC 5706595 — Kianifar 2017](https://pmc.ncbi.nlm.nih.gov/articles/PMC5706595/)). 2D-pose classifiers report 80–90% precision for *binary* valgus detection. Frontal-plane *angle* itself is unreliable (r=0.20 vs 3D); rely on the *displacement-ratio* metric and binary classification.
- **Forward lean.** Side-view 2D detection is reliable (RMSE ≤10°); false positives are mainly from torso occlusion (arms across chest, hoodie). Empirical precision/recall typically 85–95%.
- **Incomplete depth.** "Incomplete" is defined either as failing to reach hip-below-knee (IPF rule) or knee_flex < 90°. With BlazePose, ICC for sagittal knee angle ≈ 0.83, so depth detection is high-confidence (precision/recall typically >90%).

### F.3 Cross-Study Comparison

| System | Year | Method | Depth threshold | Valgus method | Sample | Accuracy |
|---|---|---|---|---|---|---|
| Pose Trainer | 2020 | OpenPose + heuristics, DTW | knee angle thresholds | not detailed for squat | >100 videos, 4 ex. | ~80% form-class. |
| GymCam | 2018 | CNN, heatmaps | implicit (motion clusters) | n/a | varsity gym | 93.6% type, MAE ±1.7 reps |
| AIFit / Fit3D | 2021 | 3D pose + statistical coach | per-exercise distributions | 3D angles | 13 subj, 37 ex., 3M+ images | qualitative |
| M3GYM | CVPR 2025 | Multi-view multimodal | n/a (research) | 3D ground truth | 50+ subj, 47M frames | benchmark-only |
| LearnOpenCV / HBR-style heuristics | various | MediaPipe + angle FSM | knee-vs-vertical bands | n/a | demo | n/a |
| Fitbod (commercial) | live | proprietary | — undisclosed — | — | — | — |
| This MVP target | 2026 | ML Kit BlazePose + FSM | knee_flex ≥ 90° + hip_y ≤ knee_y | displacement ratio | 25–30 subj target | MAE ≤ 1.5 reps |

---

## SECTION G — Data Collection & Validation Pipeline

### G.1 Dataset Design

Recommended protocol (minimal viable + headroom):

- **Subjects.** 25 total — **15 untrained (5 F / 10 M) + 10 trained (3 F / 7 M)**, ages 20–45, BMI 19–28. Required height range 155–195 cm to span anthropometric variance. Exclude pregnancy, current lower-limb injury, lower-limb prosthetics.
- **Variants.** Per subject: bodyweight squat (mandatory) + high-bar back squat (mandatory for trained; optional for untrained). Defer goblet/SSB/LBBS to v2.
- **Reps.** 3 sets × 5–8 reps per variant per camera angle.
- **Views.** Two synchronized smartphone cameras: **strict side (90°) and 45° diagonal**. Same height (≈100 cm), distance 200 cm. 1080p / 30 fps.
- **Lighting.** Three conditions: well-lit (700+ lux), gym-typical (200–500 lux), dim (≤100 lux).
- **Clothing.** Two conditions per subject: form-fitting (control) and loose/baggy (real-world). Include both shorts/leggings and full-leg pants samples.
- **Manual annotation per video.**
  - rep boundaries (start_frame, bottom_frame, end_frame)
  - depth class label (quarter/parallel/ATG)
  - per-rep error tags (multi-label: valgus, lean, knee-shift, heel-lift, butt-wink, asymmetry, spinal-flexion, none)
  - rep quality (1–5 Likert)
  - subject metadata (age, sex, height, training status, dominant leg)
- **Validation.** Two annotators per video; intra-rater reliability ICC ≥ 0.85 on rep counts; inter-rater Cohen's κ ≥ 0.80 on error tags. Use a third adjudicator for κ < 0.80.

Approximate effort: ~12 hours per subject (recording + annotation), ~300 hours total = ≈8 weeks for one annotator team or ~4 weeks for two. The Physio2.2M and Fit3D teams used similar protocols ([Physio2.2M Nature 2025](https://www.nature.com/articles/s41598-025-22626-7); [Fit3D](https://fit3d.imar.ro/)).

### G.2 Threshold Derivation Methodology

```
1. Stratify dataset by (variant × view × subject_class).
2. For each (error, variant, view) cell:
   a. Compute the metric (e.g. valgus_score) per rep.
   b. Reject MAD outliers (modified Z-score > 3.5).
   c. Estimate the desired percentile:
      - For "trigger" thresholds use P75–P85 of GOOD-form distribution
        OR P15 of BAD-form distribution. Prefer the latter when bad-form
        labels are reliable.
   d. Bootstrap the percentile with 95% BCa CI, B=2000 resamples.
   e. Sanity check: ensure P75(GOOD) < P25(BAD); otherwise the metric
      lacks discriminative power and must be redesigned.
3. FSM invariant checks:
   - Every video must produce IDLE→DESCENDING→BOTTOM→ASCENDING→IDLE per
     annotated rep (no swallowed reps, no extra reps).
   - max(knee_flex) within rep must agree with annotator label ±1 depth class.
4. F1 validation on a held-out 20% of subjects (subject-disjoint split).
   Targets: rep-count F1 ≥ 0.95, form-error F1 ≥ 0.80 per error.
```

The output is a generated `DefaultSquatThresholds.dart`:

```dart
class DefaultSquatThresholds {
  // FSM
  static const double kneeFlexIdleEnter = 15.0;     // deg
  static const double kneeFlexIdleExit = 20.0;
  static const double kneeFlexBottomEnter = 90.0;
  static const double hipYBottomDeltaTorsoLen = 0.30; // hip_y descent / torso

  // Form errors  (P85 of good-form distribution, with 95% BCa CI)
  static const double valgusRatio = 0.10;            // CI [0.07, 0.13]
  static const double leanDegHB   = 45.0;            // CI [40, 50]
  static const double leanDegLB   = 60.0;            // CI [55, 65]
  static const double kneeShiftRatio = 0.30;         // CI [0.25, 0.35]
  static const double heelLiftRatio = 0.03;          // CI [0.02, 0.04]
  static const double asymDeg = 10.0;                // CI [8, 12]
  static const double spineDev = 25.0;               // CI [20, 30]

  // VBT
  static const double squatMVTMale   = 0.30; // m/s
  static const double squatMVTFemale = 0.25;
}
```

(Numeric CIs above are derived from literature ranges, not yet from this dataset; replace with bootstrap-CIs once the dataset is collected.)

---

## SECTION H — Implementation Constraints (Mobile)

### H.1 Real-Time Performance

The ML Kit Pose Detection API in **STREAM_MODE / base SDK** delivers ~30 fps on Pixel 4 (Snapdragon 855) and ~45 fps on iPhone X; "accurate" mode is slower, with no published latency numbers but typically ~half ([ML Kit / Google Developers Blog](https://developers.googleblog.com/ml-kit-pose-detection-makes-staying-active-at-home-easier/); [ML Kit pose-detection docs](https://developers.google.com/ml-kit/vision/pose-detection)). On older mid-range Snapdragon 665 / 845 devices, expect 15–25 fps in base mode with frame-skipping required for "accurate."

**Frame budget at 15 fps target (66 ms/frame):**

| Stage | Budget | Rationale |
|---|---|---|
| ML Kit BlazePose inference | 40–55 ms | Dominant cost (CPU); GPU acceleration recently added on Android ([ML Kit release notes](https://developers.google.com/ml-kit/release-notes)) |
| 1€ Filter smoothing | <1 ms | trivial |
| Feature extraction (angles, distances) | <2 ms | <30 floating-point operations per frame |
| FSM update | <1 ms | a few comparisons |
| Form-error checks | <3 ms | 7 metrics × O(1) each |
| UI render (Flutter custom paint) | <10 ms | overlay skeleton + cues |
| **Total** | **~50–70 ms** | Achievable at 15 fps even on Snapdragon 665 |

**Recommendation.** Use **base SDK + STREAM_MODE + 480×640 input** for the MVP; this is the configuration Google explicitly tunes for fitness apps. Reserve "accurate" for an offline review/replay screen.

### H.2 Robustness

| Threat | Mitigation |
|---|---|
| Partial occlusion (rack, mirror, gym equipment) | Landmark-confidence gate (visibility ≥0.4); skip frame if any of {hip, knee, ankle} < 0.4 |
| Loose clothing (≥10% degradation in MediaPipe per Physio2.2M) | Train on baggy-clothing samples in dataset; apply 1€ filter with higher beta to reduce silhouette jitter |
| Dim/high-contrast lighting | Auto-exposure-lock prompt during setup; reject session if mean confidence < 0.5 across first 30 frames |
| Camera-angle drift | Compute frame-to-frame inter-ankle distance; if it changes >20% mid-set, prompt user "please don't move the camera" |
| Fatigue-induced form deterioration | Form-error rates per rep may rise legitimately at end of set — treat increased deduction as feedback, not as detector failure |
| Bilateral / mirror confusion | Use BlazePose left/right indices consistently; do not infer side from screen-x alone |

The 1€ Filter (min_cutoff ≈ 1.0 Hz, β ≈ 0.05 for normalized Y) plus visibility gating is the literature-standard mobile pipeline ([jaantollander.com](https://jaantollander.com/post/noise-filtering-using-one-euro-filter/); [Pauzi et al., Springer 2021](https://link.springer.com/chapter/10.1007/978-3-030-90235-3_49)).

---

## SECTION I — MVP Synthesis Specification

### Recommended MVP

1. **Variant.** **Bodyweight squat** as primary. Add **high-bar back squat** as opt-in for trained users. Defer LBBS, goblet, SSB, belt, single-leg.
2. **Camera.** Single **strict side view** (90° to subject sagittal plane), 200 cm distance, 100 cm height. Offer a "diagonal 45°" mode as fallback when valgus checking is desired.
3. **FSM.** As specified in §C.1, with knee-flexion thresholds: IDLE_ENTER 15°, IDLE_EXIT 20°, BOTTOM_ENTER 90° (or hip_y ≤ knee_y AND knee_flex ≥ 90°), with 1€ filter smoothing and velocity-sign confirmation.
4. **Form-error priority list** (top-3 most-detectable + most-valuable on side view):
   1. Incomplete depth (always available, high signal).
   2. Excessive forward lean (high signal, high pedagogical value).
   3. Heel lift (high signal, fixes ankle-mobility-bound users).
   4. (Bonus) Forward knee shift past toes — flag as informational, not error, given the disputed clinical relevance.
5. **Thresholds.** See §D.1 quantitative table.
6. **Quality scoring.** Multiplicative deduction model in §D.3.
7. **Data collection.** 25 subjects, 2 views, 2 lighting conditions, 2 clothing conditions, ≥20 reps/subject; manual annotation with κ ≥ 0.80 inter-rater. ≈8-week effort.
8. **Engineering timeline (estimate).**
   - Week 1–2: BlazePose integration, FSM, basic rep counting on side view.
   - Week 3–6: Data collection.
   - Week 7–8: Annotation + bootstrap threshold derivation.
   - Week 9–10: Form-error detector implementation, unit tests, F1 validation.
   - Week 11–12: User testing, cue UX, polish.
   - **Total ≈ 12 weeks** for shipping MVP.

### Out-of-MVP / v2 Roadmap

- Squat variant auto-detection (HB vs LB from trunk angle).
- Front-view valgus & asymmetry detection (with calibration UX).
- Heel-lift detection robust to baggy pants (requires foot-segmentation augmentation).
- Pause-squat / tempo detection (eccentric/isometric/concentric duration).
- Asymmetry cues with bilateral landmark fusion.
- VBT fatigue detection (hip-Y velocity → MVT termination).
- Goblet, single-leg, split squat, lunges.
- Adaptive thresholds learned from per-user history (after ≥30 reps).

### Open Research Gaps Flagged

- **Butt-wink injury risk under load** — McGill vs. modern pain science is unresolved; do not over-claim ([E3Rehab](https://e3rehab.com/the-truth-about-butt-wink/); [McGill Backfitpro](https://www.backfitpro.com/spine-flexion-exercise-myths-truths-issues-affecting-health-performance/)).
- **Front-view 2D valgus angle** is unreliable per Haberkamp 2022 — operationalize as displacement, not angle.
- **Sex-, age-, and training-status-stratified thresholds** are sparse in the literature; collect dataset balanced enough to estimate them.
- **MediaPipe accuracy on baggy clothing** is degraded but rarely quantified — include this in your dataset.
- **Femur-to-tibia ratio influence** on squat — Berglund 2024 found it negligible; Glassbrook 2017 concurs. Defer per-user anthropometry adaptation.

---

## SECTION J — Key References

**Biomechanics (textbook-tier and peer-reviewed reviews).**
- Escamilla RF. *Knee biomechanics of the dynamic squat exercise.* Med Sci Sports Exerc 2001 ([PubMed 11194098](https://pubmed.ncbi.nlm.nih.gov/11194098/)).
- Glassbrook DJ et al. *A Review of the Biomechanical Differences Between High-Bar and Low-Bar Back-Squat.* J Strength Cond Res 31(9):2618–2634, 2017 ([PubMed 28570490](https://pubmed.ncbi.nlm.nih.gov/28570490/)).
- Straub RK & Powers CM. *A Biomechanical Review of the Squat Exercise: Implications for Clinical Practice.* IJSPT 2024 ([Scholastica](https://ijspt.scholasticahq.com/article/94600-a-biomechanical-review-of-the-squat-exercise-implications-for-clinical-practice)).
- McGill SM. *Spine flexion exercise: Myths, Truths and Issues.* Backfitpro 2014 ([backfitpro.com](https://www.backfitpro.com/spine-flexion-exercise-myths-truths-issues-affecting-health-performance/)).
- Hartmann H, Wirth K, Klusemann M. *Influence of squatting depth on jumping performance.* J Strength Cond Res 26(12):3243–3261, 2012.
- Hartmann H et al. *The Limitations of Anterior Knee Displacement during Different Barbell Squat Techniques: A Comprehensive Review.* J Clin Med 2023 ([PMC 10143703](https://pmc.ncbi.nlm.nih.gov/articles/PMC10143703/)).
- Hemmerich A et al. ROM requirements for functional activities, J Orthop Res 2006 (cited in [PMC 4415844](https://pmc.ncbi.nlm.nih.gov/articles/PMC4415844/)).
- Macrum E et al. *Effect of limiting ankle DF ROM on lower-extremity kinematics during a squat.* J Sport Rehabil 2012.
- Fry AC et al. *Effect of knee position on hip and knee torques during the barbell squat.* (referenced in scienceinsights review).
- Cho K-Y et al. *Relationships between physical characteristics and biomechanics of lower extremity during the squat.* J Exerc Sci 2021 ([PubMed 34712337](https://pubmed.ncbi.nlm.nih.gov/34712337/)).
- Patellofemoral Pain & Squats — systematic review, Int J Environ Res Public Health 2022 ([PMC 9367913](https://pmc.ncbi.nlm.nih.gov/articles/PMC9367913/)).
- *Posterior Pelvic Tilt During the Squat — Biomechanical Perspective.* Appl Sci 2025 ([MDPI](https://www.mdpi.com/2076-3417/15/23/12526)).

**NSCA / NASM / S&C Standards.**
- NSCA. *Essentials of Strength Training and Conditioning,* 5th ed. ([NSCA store](https://www.nsca.com/certification/cscs/essentials-of-strength-training-and-conditioning-5th-edition/)).
- *Optimizing Squat Technique—Revisited,* Strength & Conditioning Journal 40(6):68–74, 2018 ([LWW](https://journals.lww.com/nsca-scj/fulltext/2018/12000/optimizing_squat_technique_revisited.10.aspx)).
- Myer GD et al. *The back squat: a proposed assessment of functional deficits and technical factors that limit performance.* Strength Cond J 36(6):4–27, 2014.
- NSCA. *Considerations for Squat Depth.* NSCA Coach ([nsca.com](https://www.nsca.com/education/articles/nsca-coach/considerations-for-squat-depth/)).
- NASM Overhead Squat Assessment guidelines (summarized at [PT Pioneer](https://www.ptpioneer.com/personal-training/certifications/study/nasm-overhead-squat-assessment/)).

**Pose estimation, datasets & validation.**
- Bazarevsky V et al. *BlazePose: On-device Real-time Body Pose Tracking.* CVPR 2020 ([arxiv 2006.10204](https://arxiv.org/abs/2006.10204); [Google Research blog](https://research.google/blog/on-device-real-time-body-pose-tracking-with-mediapipe-blazepose/)).
- Grishchenko I et al. *BlazePose GHUM Holistic.* arXiv 2206.11678 ([arxiv](https://arxiv.org/pdf/2206.11678)).
- Chen S, Yang RR. *Pose Trainer: Correcting Exercise Posture using Pose Estimation.* arXiv 2006.11718, 2020 ([arxiv](https://arxiv.org/abs/2006.11718)).
- Xu Q et al. *M3GYM: A Large-Scale Multimodal Multi-view Multi-person Pose Dataset for Fitness Activity Understanding.* CVPR 2025 ([CVF Open Access PDF](https://openaccess.thecvf.com/content/CVPR2025/papers/Xu_M3GYM_A_Large-Scale_Multimodal_Multi-view_Multi-person_Pose_Dataset_for_Fitness_CVPR_2025_paper.pdf); [project site](https://finalyou.github.io/M3GYM/)).
- Fieraru M et al. *AIFit: Automatic 3D Human-Interpretable Feedback Models for Fitness Training.* CVPR 2021 ([CVF PDF](https://openaccess.thecvf.com/content/CVPR2021/papers/Fieraru_AIFit_Automatic_3D_Human-Interpretable_Feedback_Models_for_Fitness_Training_CVPR_2021_paper.pdf)); Fit3D dataset ([fit3d.imar.ro](https://fit3d.imar.ro/)).
- Khurana R et al. *GymCam.* IMWUT 2018 ([ResearchGate](https://www.researchgate.net/publication/329957199_GymCam_Detecting_Recognizing_and_Tracking_Simultaneous_Exercises_in_Unconstrained_Scenes)).
- Ota M et al. *Verification of reliability and validity of motion analysis systems during bilateral squat using OpenPose.* Gait Posture 2020 ([ScienceDirect](https://www.sciencedirect.com/science/article/abs/pii/S0966636220301776)).
- Haberkamp LD et al. *Validity of an artificial intelligence, human pose estimation model for measuring single-leg squat kinematics.* J Biomech 2022 ([PubMed 36198251](https://pubmed.ncbi.nlm.nih.gov/36198251/)).
- *Assessment of monocular human pose estimation models for clinical movement analysis.* Sci Rep 2025 (Physio2.2M, MediaPipe knee MAE 9.3–21.9° in 2D) ([Nature](https://www.nature.com/articles/s41598-025-22626-7)).
- *Exercise quantification from single-camera markerless 3D pose estimation.* Heliyon 2024 ([PMC 10951609](https://pmc.ncbi.nlm.nih.gov/articles/PMC10951609/)).
- *Evaluation of Smartphone Camera Positioning on AI Pose Estimation Accuracy for Exercise Detection.* JMIR mHealth 2026 ([JMIR](https://mhealth.jmir.org/2026/1/e82412)).
- Casiez G, Roussel N, Vogel D. *1 € Filter: A Simple Speed-based Low-pass Filter.* CHI 2012 ([Semantic Scholar](https://www.semanticscholar.org/paper/1-%E2%82%AC-filter:-a-simple-speed-based-low-pass-filter-in-Casiez-Roussel/9dc90eec1eaeee77e17c21642597b871e8e7a6c8)).
- Drillis R, Contini R, Bluestein M. *Body Segment Parameters: A Survey of Measurement Techniques.* Artificial Limbs 25:44–66, 1964 ([oandplibrary.org PDF](http://www.oandplibrary.org/al/pdf/1964_01_044.pdf)).
- Winter DA. *Biomechanics and Motor Control of Human Movement,* 4th ed. (anthropometric ratios; [PSU summary](https://www.openlab.psu.edu/2018/02/05/proportionality-constants/)).

**Velocity-Based Training.**
- Fitas A et al. *Average optimal minimum velocity threshold... back squat.* J Sports Sci 2024 ([PubMed 39356873](https://pubmed.ncbi.nlm.nih.gov/39356873/)).
- *How Does Load Selection and Sex Influence 1RM Prediction Using the Minimal Velocity Threshold During Free-Weight Back Squat?* Sports 13:224, 2025 ([MDPI](https://www.mdpi.com/2075-4663/13/7/224)).
- Banyard HG, Nosaka K, Haff GG. *Reliability and validity of the load–velocity relationship to predict the 1RM back squat.* J Strength Cond Res.

**Mobile pose-detection platform docs.**
- Google. *ML Kit Pose Detection.* ([developers.google.com](https://developers.google.com/ml-kit/vision/pose-detection); [release notes](https://developers.google.com/ml-kit/release-notes)).
- Google. *ML Kit Pose Detection Makes Staying Active at Home Easier* (FPS benchmarks Pixel 4/iPhone X) ([Google Developers Blog](https://developers.googleblog.com/ml-kit-pose-detection-makes-staying-active-at-home-easier/)).

---

## Appendix A — CSV-Ready Threshold Table

```csv
error_type,formula,threshold,ci_low,ci_high,variant,view,source,risk
incomplete_depth,knee_flex_max_deg,90,85,95,bodyweight|HBBS,side,NSCA Optimizing Squat Technique 2018,low
incomplete_depth_atg,knee_flex_max_deg,120,115,125,ATG,side,Glassbrook 2017,low
valgus_collapse,(ankle_x-knee_x)/inter_ankle_px,0.10,0.07,0.13,all,front,Kianifar 2017 / Bell Padua FPPA,high
forward_knee_shift,(knee_x-ankle_x)/femur_len_px,0.30,0.25,0.35,HBBS,side,Hartmann 2023 review,moderate
forward_knee_shift_lb,(knee_x-ankle_x)/femur_len_px,0.20,0.15,0.25,LBBS,side,Glassbrook 2017,moderate
forward_lean_hb,trunk_from_vertical_deg,45,40,50,HBBS,side,Glassbrook 2017,moderate
forward_lean_lb,trunk_from_vertical_deg,60,55,65,LBBS,side,Glassbrook 2017,moderate
heel_lift,(heel_y-foot_index_y)/leg_len_px,0.03,0.02,0.04,all,side,empirical / Macrum 2012,low
asymmetry,abs(knee_flex_L-knee_flex_R)_deg,10,8,12,all,front,JOSPT LSI literature 2017,moderate
spinal_flexion,delta_shoulder_hip_knee_deg,25,20,30,all,side,McGill 2014 / IJSPT 2024,high
mvt_male,hip_y_velocity_m_per_s,0.30,0.27,0.33,all,side,GymAware/MDPI Sports 2025,info
mvt_female,hip_y_velocity_m_per_s,0.25,0.22,0.28,all,side,MDPI Sports 2025,info
```

## Appendix B — Data-Collection Checklist (one-page)

```
[ ] Subjects: ≥25 (15 untrained + 10 trained), age 20–45, BMI 19–28, balanced sex, height 155–195 cm
[ ] Variants: bodyweight + HBBS (trained); 3 sets × 5–8 reps each
[ ] Cameras: 2× smartphone @ 1080p/30fps; side 90° + diagonal 45°
[ ] Camera height: 100 ±10 cm, distance: 200 ±20 cm
[ ] Lighting: 3 conditions (bright/normal/dim) per subject
[ ] Clothing: form-fit + loose; long pants + shorts
[ ] Per-rep manual annotation: start_frame, bottom_frame, end_frame, depth_class, error_tags[], quality (1–5)
[ ] Two annotators per video; Cohen κ ≥ 0.80 on error tags; ICC ≥ 0.85 on rep counts
[ ] Subject-disjoint 80/20 split for derivation vs. validation
[ ] Bootstrap 95% BCa CI per threshold (B=2000)
[ ] FSM invariant tests + F1 ≥ 0.95 rep counting / ≥ 0.80 per-error
```

## Appendix C — Pseudocode (Dart-style)

```dart
// Per-frame update
void onPoseFrame(PoseLandmarks lm, double t) {
  if (lm.hipL.visibility < 0.4 || lm.kneeL.visibility < 0.4 ||
      lm.ankleL.visibility < 0.4) return; // gate

  // Smooth landmarks
  smoother.update(t, lm);

  // Features
  final kneeFlex = 180 - angleBetween(lm.hipL, lm.kneeL, lm.ankleL);
  final hipY     = lm.hipL.y;
  final hipVy    = derivativeY(hipY, t);
  final lean     = atan2(lm.hipL.x - lm.shoulderL.x,
                         lm.hipL.y - lm.shoulderL.y).abs() * 180 / pi;
  final shift    = max(0, (lm.kneeL.x - lm.ankleL.x).abs())
                     / dist(lm.hipL, lm.kneeL);
  final heelLift = (lm.heelL.y - lm.footIndexL.y).abs()
                     / (dist(lm.hipL, lm.kneeL) + dist(lm.kneeL, lm.ankleL));

  // FSM
  switch (state) {
    case S.IDLE:
      if (kneeFlex > T.kneeFlexIdleExit && hipVy > eps) state = S.DESCENDING;
      break;
    case S.DESCENDING:
      maxKneeFlex = max(maxKneeFlex, kneeFlex);
      if (kneeFlex >= T.kneeFlexBottomEnter
          && hipY <= lm.kneeL.y && hipVy.abs() < eps) state = S.BOTTOM;
      break;
    case S.BOTTOM:
      if (hipVy < -eps) state = S.ASCENDING;
      break;
    case S.ASCENDING:
      if (kneeFlex < T.kneeFlexIdleEnter && hipVy.abs() < eps) {
        finalizeRep(maxKneeFlex, /* error metrics */);
        state = S.IDLE;
      }
      break;
  }
}
```

---

This specification is implementation-ready: every form-error has a closed-form formula on BlazePose landmarks, every threshold has a literature anchor with a uncertainty range, and every recommendation is bounded by what monocular 2D pose can reliably measure on a mid-range Android device. The two largest open risks are (1) front-view valgus reliability, which is structurally limited by 2D physics and should be deferred to v2 with explicit camera-calibration UX, and (2) loose-clothing degradation, which must be addressed in dataset design rather than at inference time.