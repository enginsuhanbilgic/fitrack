# **Data-Driven Biomechanical Foundation for Real-Time Squat Analysis on Mobile Devices**

## **Section A: Squat Biomechanics Foundation**

### **A.1 Kinetic Chain and Anatomical Range of Motion**

The barbell squat and its bodyweight derivatives represent a closed-kinetic-chain, multi-joint movement pattern that necessitates the simultaneous, coordinated extension of the hip, knee, and ankle joints. This mechanical synergy is biomechanically classified as triple extension.1 The safe and effective execution of this movement is fundamentally governed by the anatomical range of motion (ROM) available across these primary articular junctions, as well as the dynamic stability of the lumbo-pelvic-hip complex (LPHC).

**Knee Joint Kinematics** The knee joint serves as the primary hinge of the squat, experiencing the largest angular excursion during the eccentric descent. Normative epidemiological data establishes that maximum unrestricted active knee flexion in healthy adults ranges from 140.4° to 144.0° for males, and 140.8° to 143.8° for females, while full extension is approximately 1.0° to 2.4°.3 However, during loaded or structured squatting, the requisite knee flexion angle is dictated entirely by the targeted variant and depth profile. In biomechanical literature, a "quarter squat" is characterized by an internal knee angle of 110° to 140° (where 180° represents full extension).4 A "half squat" requires an internal angle of 80° to 100°.4 The canonical "parallel squat," which serves as the standard for general strength and conditioning, is defined by the anterior aspect of the thigh aligning parallel to the floor, resulting in an internal knee angle of approximately 60° to 70°.4 A full, unrestricted "ass-to-grass" (ATG) squat pushes the knee into maximum flexion, typically 40° to 45°, maximizing contact between the posterior musculature of the thigh and the calf.4 From a clinical safety perspective, compressive forces on the patellofemoral joint peak near 90° of flexion, while tibiofemoral shear forces are heavily dependent on the degree of anterior knee translation and the stabilization provided by the hamstrings.4

**Hip Joint Kinematics and Anthropometric Scaling** Hip flexion ROM represents the primary mechanical limitation in achieving maximum squat depth without compensatory spinal breakdown. The normative anatomical hip flexion limit is approximately 124° to 136°.3 As an individual reaches the terminal range of their active hip flexion during the descent, the anterior aspect of the femur compresses against the acetabular rim of the pelvis.7 To achieve further depth beyond this structural blockade, the kinetic chain forces the LPHC to undergo a posterior pelvic tilt (PPT), a phenomenon colloquially termed "butt wink".7 This compensatory tilt flattens the natural lumbar lordosis and significantly amplifies shear forces across the intervertebral discs, elevating the risk of mechanical injury.9 A pervasive misconception in fitness communities is that a high femur-to-tibia length ratio directly forces this compensatory PPT and an excessive forward lean. However, contemporary biomechanical analyses demonstrate that relative anthropometric measures are not the primary driver of lumbopelvic flexion.11 Rather, poor movement control and restricted ankle dorsiflexion are the true culprits.11 While longer femurs do increase the sagittal moment arm—requiring the lifter to adopt a smaller hip angle to keep the center of mass over the mid-foot—this can be entirely mitigated by widening the stance.11 Widening the stance externally rotates the femur, artificially shortening its sagittal length relative to the barbell, thereby reducing the necessary hip and ankle ROM required to achieve parallel depth.11

**Ankle Joint Kinematics and Dorsiflexion Requirements** Adequate closed-chain ankle dorsiflexion is a non-negotiable prerequisite for maintaining an upright torso during the squat descent.12 During a standard parallel squat, a minimum functional dorsiflexion range of 15° to 20° is required to allow the tibia to incline forward sufficiently.14 A deep squat pushes this requirement further, demanding approximately 23° to 26° of dorsiflexion.6 In populations where ankle dorsiflexion is restricted (clinically defined as less than 11.5° to 18.5° depending on knee position) 15, the body must compensate to prevent the center of mass from shifting behind the base of support. This compensation manifests either as early posterior displacement of the pelvis (which exacerbates forward trunk lean and spinal shear) or as the lifting of the heels off the floor, which dangerously shifts the load onto the forefoot and patellar tendon.14 Artificial heel elevation, such as wearing specialized weightlifting shoes with a rigid 15–20 mm heel wedge, mechanically circumvents this restriction by allowing forward tibial translation without requiring extreme tissue extensibility at the talocrural joint, thereby facilitating a more upright torso.7

**Spine and Torso Kinematics** The trunk angle, defined geometrically as the angle of the torso relative to the absolute vertical axis, varies significantly depending on the squat variant and the lifter's intent. The biomechanical relationship between the spine and the lower extremities can be accurately modeled using the trunk-tibia angle, which is the difference between the sagittal plane inclination of the trunk and the tibia at peak knee flexion.7 A trunk-tibia angle greater than 10° indicates a hip-extensor bias, transferring the moment arm to the gluteus maximus and hamstrings, which is typical of a low-bar back squat.7 Conversely, a trunk-tibia angle less than \-10° indicates a knee-extensor bias, typical of a front squat.7 Excessive forward lean, where the torso angle exceeds 45° from the vertical, significantly increases lumbar shear forces and is a primary pathomechanical mechanism for intervertebral disc herniation.10

| Articular Junction | Action | Quarter Squat | Parallel Squat | ATG (Full) Squat | Pathomechanical Constraint |
| :---- | :---- | :---- | :---- | :---- | :---- |
| **Knee** | Flexion (Internal Angle) | 110°–140° | 60°–70° | 40°–45° | Patellofemoral compression peaks near 90° of flexion. |
| **Hip** | Flexion | 60°–80° | 90°–110° | 120°–136° | End-range acetabular compression induces posterior pelvic tilt. |
| **Ankle** | Dorsiflexion | 5°–10° | 15°–20° | 23°–26° | Restriction forces compensatory forward trunk lean or heel lift. |
| **Trunk** | Forward Lean (from vertical) | 10°–20° | 30°–40° | 15°–25° | Lean \>45° exponentially increases lumbar shear stress. |

### **A.2 Squat Variants and Their Biomechanical Signatures**

The squat is not a monolithic exercise; it encompasses a wide taxonomy of variants, each possessing a distinct biomechanical signature, joint-angle profile, and force distribution pattern. To engineer a robust pose-estimation model, the system must accurately differentiate between these canonical forms to avoid flagging valid mechanical variations as postural errors.

**High-Bar Back Squat (Olympic-Style)** In the high-bar back squat, the load is positioned across the upper trapezius, immediately inferior to the spinous process of the C7 vertebra.4 This superior placement of the center of mass forces the lifter to maintain a highly upright torso to keep the load balanced directly over the mid-foot.4 The biomechanical signature of this variant involves near-equal mechanical work distributed between the hip extensors and knee extensors.1 The upright postural requirement dictates significant anterior displacement of the knees, which frequently translate past the toes, thereby necessitating excellent ankle dorsiflexion mobility.18 The internal knee angle at the point of maximum descent typically reaches 40°–60°, defining it as a highly knee-dominant and anatomically demanding movement.

**Low-Bar Back Squat (Powerlifting-Style)** Favored in powerlifting to maximize absolute load capacity, the low-bar variant positions the barbell 5 to 6 centimeters lower on the back, resting across the spine of the scapula and the posterior deltoids.4 This inferior displacement of the center of mass necessitates a pronounced forward trunk lean to maintain the system's balance over the base of support.17 The biomechanical signature is heavily hip-dominant, characterized by a distinct posterior displacement of the LPHC ("sitting back") and a significantly more vertical tibia.17 Consequently, the internal knee angle rarely drops below 60°–70°, while the hip flexion angle is maximized. This variant places extreme mechanical demand on the erector spinae, gluteus maximus, and adductor complex.1

**Goblet and Bodyweight Squats** Goblet squats, utilizing anterior loading via a dumbbell or kettlebell, and standard unweighted bodyweight squats share a kinematic signature that is heavily biased toward the anterior chain. The anterior counterweight in a goblet squat acts as a mechanical counterbalance, allowing the lifter to maintain a near-vertical torso.7 Because the spine remains highly vertical, the lifter must utilize massive ankle dorsiflexion and extreme knee flexion to achieve depth. These variants are highly recommended as the baseline templates for a mobile fitness application MVP. Their upright posture minimizes self-occlusion in the sagittal plane, rendering algorithmic tracking of the hip and shoulder landmarks significantly more reliable than the heavily folded posture of a low-bar back squat.

**Safety Squat Bar (SSB) and Belt Squats** The SSB utilizes a specialized cambered bar that artificially shifts the center of mass anteriorly, simulating the upright mechanics of a front squat while maintaining a back-loaded position.19 It mechanically enforces a vertical spine, reducing shear stress on the lumbar region. Belt squats remove axial loading from the cervical, thoracic, and lumbar spine entirely by suspending the weight directly from the pelvis.20 While biomechanically advantageous for rehabilitation, both require specialized equipment and exhibit non-standard upper-body keypoint orientations (e.g., hands grasping front handles), placing them outside the general scope of an initial pose-estimation MVP.

### **A.3 Common Squat Form Errors (Biomechanical Pathomechanics & Injury Risk)**

The translation of human coaching into a computer vision pipeline requires precise, mathematically bounded definitions of common form errors. A data-driven analysis of pathomechanics allows for the parameterization of these visual deviations into measurable thresholds.

**1\. Dynamic Knee Valgus (Valgus Collapse)**

* **Pathomechanics:** Knee valgus is a multi-planar distortion characterized by femoral internal rotation and adduction coupled with tibial external rotation, causing the knee joint to collapse medially during the concentric ascent.21 It is primarily instigated by a deficit in neuromuscular control, specific weakness in the hip abductors (gluteus medius) and external rotators, and compensatory mechanics due to restricted ankle dorsiflexion.21  
* **Injury Risk:** Valgus collapse drastically increases the varus moment at the knee, placing extreme tensile strain on the anterior cruciate ligament (ACL) and the medial collateral ligament (MCL), while simultaneously increasing compressive and shear forces on the lateral meniscus.24 It is statistically the leading biomechanical predictor of non-contact ACL ruptures, exhibiting a particularly high prevalence in female athletes due to wider anatomical Q-angles.26  
* **Quantitative Threshold:** Utilizing 2D pose estimation, this is measured via the Frontal Plane Projection Angle (FPPA). Normal physiological tracking demonstrates an FPPA of 3° to 8° in males and 7° to 13° in females.28 A dynamic valgus event is definitively flagged when the medial displacement causes the FPPA to exceed 15° during the transition from the eccentric to the concentric phase.29

**2\. Excessive Forward Lean (Spinal Shear)**

* **Pathomechanics:** A kinematic error where the torso angle falls aggressively forward relative to the vertical axis during the descent. While a slight lean is a biomechanical necessity for balance (particularly in low-bar squats), *excessive* lean is a compensatory mechanism triggered by a lack of ankle dorsiflexion, forcing the hips backward, or by a failure of the anterior core musculature to stabilize the spine.16  
* **Injury Risk:** The human lumbar spine possesses high tolerance for axial compression but is highly vulnerable to anterior shear forces. Excessive forward lean violently shifts the ground reaction force vector, creating massive shear stress across the L4-L5 and L5-S1 intervertebral discs, serving as the primary mechanism for disc herniation and facet joint syndrome.10  
* **Quantitative Threshold:** A torso angle deviating more than 45° from the true vertical axis is widely classified as excessive, biomechanically hazardous, and mechanically inefficient.10

**3\. Posterior Pelvic Tilt ("Butt Wink")**

* **Pathomechanics:** The involuntary loss of lumbar extension at the absolute bottom of a deep squat, resulting in dynamic lumbar kyphosis (rounding).32 While traditionally blamed on static anthropometrics (e.g., relative femur length), modern dynamic analyses prove it is almost exclusively a function of reaching terminal hip flexion or terminal ankle dorsiflexion, forcing the pelvis to rotate posteriorly to accommodate further downward displacement.11  
* **Injury Risk:** Flexing the lumbar spine under heavy axial load causes asymmetrical anterior compression of the intervertebral discs and posterior stretching of the annulus fibrosus.32  
* **Quantitative Threshold:** Biomechanically defined as transitioning from a natural lordotic curve (approximately 32° of extension) to a kyphotic state, measured as lumbar flexion exceeding 10° to 12° from neutral at the point of maximum depth.32

**4\. Incomplete Depth (Quarter Squatting)**

* **Pathomechanics:** Halting the eccentric descent prematurely, failing to reach a parallel thigh position. This is routinely driven by quadriceps weakness, a psychological fear of the descent, or severe restrictions in hip and ankle mobility.  
* **Injury/Training Risk:** While less acutely dangerous than valgus collapse, chronic quarter squatting fails to adequately recruit the gluteus maximus and hamstrings, limits total mechanical work, and fundamentally alters the load-velocity profile, resulting in suboptimal hypertrophy and strength adaptations.30  
* **Quantitative Threshold:** The internal knee angle failing to break 100° during the transition from the DESCENDING to the ASCENDING state.5

**5\. Anterior Knee Shift and Heel Lift**

* **Pathomechanics:** If talocrural (ankle) dorsiflexion is restricted, the lifter is unable to track the knees anteriorly while maintaining a flat foot. To achieve depth, the LPHC shifts forward, and the heels are mechanically forced to lift off the ground to artificially increase the tibial angle.14  
* **Injury Risk:** This error shifts the entire kinetic load onto the patellar tendon and the delicate metatarsals of the forefoot, exponentially increasing the risk of patellar tendinopathy, anterior knee pain, and catastrophic balance loss.14  
* **Quantitative Threshold:** A vertical displacement of the ankle landmark (y-coordinate) greater than 2-3 cm relative to its initial ground contact position during the IDLE state.

## **Section B: Pose-Estimation-Specific Biomechanics**

### **B.1 2D vs. 3D Joint Angle Measurement Limitations**

Translating rigid 3D biomechanical principles into a 2D or semi-3D pose estimation framework—such as the ML Kit / MediaPipe BlazePose 33-landmark topology—introduces distinct geometric and computational limitations. BlazePose infers 33 body keypoints in an x-y-z coordinate system; however, because the input is captured via a monocular (single-lens) RGB camera on a mobile device, the z-axis (depth) is not a true optical measurement. Instead, it is a synthetic coordinate estimated via machine learning priors.38 This synthetic depth creates varying degrees of reliability depending on the viewing plane.

**Sagittal Plane Accuracy (Depth, Knee Flexion, Forward Lean)** For movements viewed directly from the side (the sagittal plane), BlazePose demonstrates remarkably high concurrent validity with gold-standard 3D optical motion capture systems like VICON. Validation studies reveal that when measuring hip flexion, knee flexion, and trunk angles from a strictly lateral viewpoint, the Root Mean Square Error (RMSE) of BlazePose is generally constrained within 5° to 10°.40 This margin of error is highly acceptable for fitness applications determining squat depth and identifying excessive forward lean.

* *Normalization Recommendation:* To mitigate z-axis hallucination, knee flexion should be calculated purely using the 2D vectors created by the Hip-Knee and Knee-Ankle landmarks projected onto the x-y plane of a side-facing camera.

**Frontal Plane Accuracy (Valgus Collapse Detection)** Detecting dynamic knee valgus using monocular pose estimation presents severe computational challenges. When relying on absolute 3D coordinate angles from BlazePose, researchers have documented massive absolute error ranges—up to 18.8° to 19.6° of deviation compared to VICON systems.42 This severe error stems from the ML model's inability to accurately determine the true anatomical center of the knee joint as it rotates inward, a problem heavily exacerbated by perspective parallax and lens distortion.

* *Normalization Recommendation:* To achieve clinically valid valgus detection, algorithms must strictly avoid absolute angle measurements. Instead, the system must calculate the *excursion angle*—the relative change in the 2D Frontal Plane Projection Angle (FPPA) from the initial standing posture (Initial Contact, IC) to the bottom of the squat.42 Tracking the horizontal displacement of the knee x-coordinate relative to the ankle x-coordinate during the descent provides a highly reliable, mathematically sound heuristic that bypasses absolute coordinate errors.

**Lumbar Flexion ("Butt Wink")**

Because BlazePose simplifies the entire complex structure of the human spine into just two shoulder landmarks and two hip landmarks, it entirely lacks the granular resolution required to detect the localized curvature of the lumbar vertebrae. Therefore, a true "butt wink" (posterior pelvic tilt) is mathematically invisible to the standard 33-landmark schema. Any algorithmic attempt to infer lumbar flexion purely from the shoulder-hip-knee angle will erroneously conflate standard hip hinge mechanics with spinal flexion. Consequently, strict butt wink detection falls outside the capabilities of an MVP relying solely on BlazePose.

| Measurement | View Requirement | Typical 2D Error | Gold Standard | Normalization/Heuristic Strategy |
| :---- | :---- | :---- | :---- | :---- |
| **Knee Flexion (Depth)** | Strict Side (90°) | 5°–10° 40 | VICON | 2D x-y plane angle (Hip-Knee-Ankle). Ignore synthetic z-axis. |
| **Torso Forward Lean** | Strict Side (90°) | \< 10° 40 | VICON | 2D x-y plane angle relative to true vertical (gravity vector). |
| **Valgus Collapse** | Strict Front (0°) | \> 18° (Absolute) 42 | VICON | Compute relative *excursion* from standing FPPA, not absolute angle. |
| **Lumbar Flexion** | N/A | Highly Erroneous | Motion Capture | Invisible to 33-landmark topology; do not implement in MVP. |

### **B.2 Camera Setup & Viewpoint Constraints**

The accuracy of all downstream pose-estimation heuristics is directly proportional to the physical placement of the camera. Given the uncontrollable environments of mobile users, selecting and enforcing a canonical viewing angle is critical for minimizing coordinate noise.

* **Front View (0°):**  
  * *Optimal for:* Detecting valgus collapse (FPPA), lateral asymmetry, and verifying stance width.  
  * *Invisible/Highly Erroneous:* Knee flexion (depth), torso forward lean, and anterior knee tracking. Depth estimation from the front relies entirely on the synthetic z-axis, which degrades rapidly as the body folds upon itself and occludes the hip joints.  
* **Strict Side View (90°):**  
  * *Optimal for:* Knee flexion angle (precise depth tracking), torso forward lean, and forward knee shift relative to the toes.41  
  * *Invisible/Highly Erroneous:* Valgus collapse and left/right asymmetry. The contralateral limbs are heavily occluded by the ipsilateral limbs, meaning the system can only reliably track the side facing the camera.  
* **Diagonal View (45°):**  
  * While theoretically capturing both sagittal and frontal planes simultaneously, 45° views introduce severe perspective distortion. Projecting a 45° 2D image into valid 3D biomechanical angles introduces compound errors that exceed acceptable thresholds for clinical or fitness feedback.44

**Recommendation for MVP:** The system must restrict the user to a **Strict Side View (90°)**. A lateral viewpoint allows for highly accurate, low-noise measurement of the two most critical and detectable macro-errors in untrained lifters: incomplete depth and excessive forward lean. The camera should be positioned at approximately waist height (0.8 to 1.2 meters), placed 1.5 to 2.5 meters away, ensuring the entire kinematic chain (from the top of the head to the bottom of the heel) remains completely within the frame throughout the entirety of the descent.

## **Section C: Rep-Counting FSM (Squat)**

### **C.1 Finite State Machine Design**

A robust, enterprise-grade repetition counting system cannot rely on the simple peak-detection of a single variable. Human movement inherently contains natural jitter, mid-rep pauses, and localized balance adjustments that cause naive algorithms to double-count or miss repetitions entirely. The system must implement a multi-stage Finite State Machine (FSM) utilizing specific angle thresholds combined with directional velocity checks and strict hysteresis gaps.45

The FSM logic evaluates time-series arrays of joint angles and localized coordinate velocities to dictate state transitions.

**State Definitions and Transitions:**

1. **STATE: IDLE (Standing)**  
   * *Condition:* The user is in the starting position. The internal knee angle (measured via the Hip-Knee-Ankle 2D projection) is near full extension.  
   * *Threshold:* Knee Angle \> 160°.  
2. **STATE: DESCENDING**  
   * *Trigger:* The user breaks from the standing position. To prevent minor shifting noise from triggering the state, the system mandates a dual-condition check.  
   * *Threshold:* Knee Angle \< 150° **AND** Hip-Y coordinate velocity is positive (moving downward in standard image coordinates, where Y=0 is the top of the frame). The 10° gap between the IDLE threshold (160°) and the DESCENDING threshold (150°) serves as the entrance hysteresis, filtering out standing tremors.  
3. **STATE: BOTTOM (Rep Validated)**  
   * *Trigger:* The user reaches adequate depth. This serves as the validation gate; if this state is not reached, the rep is discarded as an incomplete partial movement.  
   * *Threshold:* Knee Angle \< 100° (defining a half/parallel squat boundary) **AND** Hip-Y directional velocity approaches zero or reverses to negative (upward).  
4. **STATE: ASCENDING**  
   * *Trigger:* The user begins the concentric phase.  
   * *Threshold:* Hip-Y coordinate velocity is negative (moving upward) **AND** Knee Angle begins increasing monotonically.  
5. **STATE: COMPLETED (Return to IDLE)**  
   * *Trigger:* The user returns to a full standing lockout.  
   * *Threshold:* Knee Angle \> 160° **AND** the previous state was exclusively ASCENDING.  
   * *Action:* Increment Rep Counter \+= 1\. Evaluate form errors for the completed cycle.

### **C.2 Bottom Detection and Hysteresis Logic**

The definition of the "BOTTOM" state is inherently tied to the chosen squat variant and the anatomical mobility of the user. For a general fitness application MVP, targeting a parallel squat (anterior thigh parallel to the ground) is the safest, most universally applicable, and most highly validated standard in the literature.5 Anatomically, this corresponds to an internal knee angle of approximately 60° to 80°, depending heavily on the lifter's femur-tibia ratio.

To ensure the FSM captures the bottom of the movement accurately without being overly punitive to users with anatomical restrictions or varying squat styles, the MVP bottom validation threshold is set at a forgiving **\< 100° internal knee angle**. This accommodates both deep ATG squats and slightly high powerlifting squats while successfully filtering out ineffective quarter-squats.

Hysteresis is mathematically enforced by separating the transition thresholds. The FSM will not transition from IDLE to DESCENDING until the knee flexes past 150°, but it will not transition back to IDLE until it extends past 160°. This 10° buffer ensures that minor un-racking steps, weight shifting, or resting tremors at the top of the lift do not trigger false state changes or erratic counter increments.45

## **Section D: Form Error Detection (Thresholds & Metrics)**

To provide actionable, real-time feedback, the biomechanical errors identified in Section A must be parameterized into strict mathematical functions acting upon the 2D planar coordinates extracted by BlazePose.

### **D.1 Quantitative Threshold Derivation**

| Form Error | Biomechanical Cause | 2D Mathematical Formula | Threshold (Side View) | User-Facing Cue |
| :---- | :---- | :---- | :---- | :---- |
| **Incomplete Depth** | Quad weakness; psychological fear of descent; restricted mobility. | Min(Knee\_Angle) during the DESCENDING to ASCENDING transition phase. | Knee\_Angle \> 100° | "Squat deeper. Try to get your thighs parallel to the floor." |
| **Excessive Forward Lean** | Weak anterior core; restricted ankle dorsiflexion forcing hip-hinge.16 | Torso\_Angle \= arctan(\\mid Hip\_X \- Shoulder\_X\\mid / \\mid Hip\_Y \- Shoulder\_Y\\mid) | Torso\_Angle \> 45° | "Keep your chest up and your back straight." 46 |
| **Forward Knee Shift** | Poor hip hinge mechanics; lifting heels off the floor.47 | Knee\_X \- Toe\_X (normalized to unit scale relative to thigh length). | Knee\_X \> Toe\_X \+ 0.1 | "Sit your hips back as if sitting in a chair." 46 |
| **Heel Lift** | Restricted ankle dorsiflexion (requires \<15°).14 | Max(Ankle\_Y) \- Start(Ankle\_Y) (Y-axis vertical displacement). | Delta\_Y \> 0.05 normalized units. | "Keep your feet flat. Drive through your heels." |

*(Note: Dynamic Valgus collapse is purposefully excluded from the MVP side-view schema due to the mathematical impossibility of deriving an accurate Frontal Plane Projection Angle from a sagittal 2D viewpoint).*

### **D.2 Feedback Cue Mapping and Quality Scoring**

Providing instantaneous audio or visual feedback for every minor algorithmic deviation creates a deeply frustrating, noisy user experience. The system must implement a **streak-based trigger and strict cooldown policy** to emulate the nuanced pacing of a human personal trainer.

1. **Trigger Policy:** A specific form error cue is only dispatched to the audio engine or UI overlay if the mathematical threshold is violated for **two consecutive repetitions**. This effectively filters out anomalous ML tracking noise, single-rep balance losses, or camera jitter.  
2. **Cooldown Policy:** Once a verbal cue is delivered (e.g., "Keep your chest up"), the system initiates a **5-second global cooldown** on all audio feedback. This prevents overlapping audio prompts, eliminates "cue spamming," and reduces cognitive overload while the user is under physical strain.  
3. **Rep Quality Scoring:** A proportional mathematical deduction model is utilized for overall session scoring. A perfect repetition is scored as 1.0.  
   * **Incomplete depth:** \-0.30 penalty. (The repetition failed its primary range of motion requirement, severely limiting hypertrophic stimulus).  
   * **Excessive Forward Lean:** \-0.20 penalty. (Introduces a significant safety risk via spinal shear, though the rep was technically completed).  
   * **Forward Knee Shift:** \-0.10 penalty. (Indicates a mechanical efficiency loss and minor patellar stress).  
   * The total score per repetition is clamped at a minimum of 0.0. The total session score displayed to the user is the arithmetic mean of all individual rep scores.

## **Section E: Biomechanical Constants & Normalization**

### **E.1 Anatomical Ratios (Winter's Model)**

In 2D pose estimation, absolute pixel distances vary wildly based on the user's distance from the camera, the resolution of the device, and the lens focal length. Therefore, all spatial displacement thresholds (such as knee shift or heel lift) must be normalized against the user's inherent anatomical proportions to remain scale-invariant.

The application utilizes **Winter's Anthropometric Model**, which establishes highly consistent, empirically validated proportional constants for human segment lengths across diverse populations.48 According to Winter's peer-reviewed data, standard limb proportions are as follows:

* **Thigh Length (Greater Trochanter to Femoral Condyle):** \~24.5% of total body height.  
* **Shank Length (Femoral Condyle to Medial Malleolus):** \~24.6% of total body height.  
* **Torso Length (Greater Trochanter to Glenohumeral Joint):** \~28.8% of total body height.50

For distance normalizations (e.g., tracking the horizontal forward shift of the knee relative to the toes), the algorithmic scalar reference must be the Thigh\_Length measured in pixels (calculated as the Euclidean distance between the Hip and Knee landmarks while the user is in the IDLE standing state). Therefore, a forward knee shift threshold of 0.1 normalized units equates to the knee translating anteriorly past the toes by a distance equal to 10% of the user's measured thigh length. This ensures the threshold scales perfectly whether the user is 1.5 meters or 3 meters from the camera.

### **E.2 Velocity-Based Training (VBT) for Squat**

Velocity-Based Training (VBT) relies on the foundational biomechanical principle that concentric lifting velocity is inversely, and highly linearly, related to load intensity and acute neuromuscular fatigue.51 By continuously tracking the upward velocity of the LPHC (via the Y-coordinate of the hip landmark) during the concentric ascent, the mobile system can infer muscular fatigue without requiring external hardware accelerometers or linear position transducers.

* **Mean Velocity Threshold (MVT):** The MVT is the minimum absolute velocity at which a repetition can be successfully completed before total muscular failure (a missed rep) occurs.53 For the barbell and bodyweight back squat, extensive peer-reviewed literature establishes the MVT at consistently between **0.27 m/s and 0.30 m/s**.51 This metric remains remarkably stable regardless of the athlete's absolute strength level.51  
* **Fatigue Detection (Velocity Loss):** A critical, measurable drop in mean concentric velocity within a single set is the primary indicator of acute neuromuscular fatigue. Literature indicates that a velocity loss (VL) of 20% from the fastest repetition (usually the first or second rep of the set) is the optimal threshold for maximizing strength and power adaptations.54 A velocity loss approaching 40% correlates strongly with absolute muscular failure (RPE 10\) and an exponential increase in technique breakdown.55  
* **Implementation Logic:** The system calculates the average vertical velocity of the hip landmark during the entire ASCENDING state. To mitigate the 30 FPS sampling limitation of mobile cameras, the Y-coordinate must be smoothed over a 5-frame rolling window prior to velocity derivation. If the smoothed concentric velocity of the current repetition drops by \> 30% compared to the baseline established by the first repetition, the FSM triggers a "Fatigue Warning" cue, advising the user that technical breakdown is imminent and the set should be terminated to prevent injury.

## **Section F: Validation & Accuracy Benchmarks**

### **F.1 Public Datasets and Accuracy Targets**

Validating computer-vision pose estimation algorithms for complex human movements requires massive, highly diverse datasets featuring complex environmental occlusions, varied lighting conditions, and diverse somatotypes. The recently published **M3GYM dataset** (introduced at CVPR 2025\) serves as the new gold standard for fitness pose evaluation. M3GYM comprises over 47 million frames across 82 distinct sessions, capturing over 50 subjects from 8 synchronized camera angles within a real-world gym environment (complete with challenging background reflections and occluding equipment).56 Crucially for our application, M3GYM includes over 500 fine-grained action labels paired with expert sports-science assessments of action quality, allowing supervised models to validate heuristic form-error logic against ground-truth human expert judgment.58

Benchmarking studies on 2D pose estimation for squat tracking (such as the seminal *Pose Trainer* architecture) report repetition-counting accuracies routinely exceeding 95% when utilizing state-based FSMs with hard-coded hysteresis gaps.59 Form error detection algorithms typically achieve F1 scores of \~0.85 for macro-errors like incomplete depth and excessive forward lean. However, precision degrades significantly under extreme diagonal camera angles, or when subjects wear highly bagging clothing that completely obscures the true vector of the knee and hip joints.59

The primary validation target for the proposed mobile architecture is an **Absolute Error (MAE) of ≤ 1.5 reps per session** and a false-alarm rate for form error triggering of **≤ 25%**. Based on cross-study comparisons of BlazePose implementations, these benchmarks are highly realistic and achievable, provided the user strictly adheres to the 90° side-view camera constraint.

## **Section G: Data Collection & Validation Pipeline**

To fine-tune the heuristic angle thresholds specifically for the mobile app's lens parameters and the ML Kit BlazePose coordinate outputs, an internal validation dataset must be meticulously constructed. Relying purely on textbook angles often results in algorithmic failure due to the inherent synthetic z-axis noise of monocular tracking.

### **G.1 Dataset Design and Protocol**

1. **Subject Pool:** Recruit a minimum of 30 participants (15 resistance-trained, 15 untrained novices). This cohort must be diverse in height, BMI, and gender to capture a wide array of anthropometric variances and motor control levels.  
2. **Recording Protocol:** Each subject will perform 3 sets of 8 repetitions of the bodyweight squat and goblet squat.  
   * *Set 1:* Instructed to use intentional, perfect form.  
   * *Set 2:* Instructed to exhibit intentional incomplete depth (quarter squats).  
   * *Set 3:* Instructed to exhibit intentional excessive forward lean.  
3. **Camera Specs:** All videos must be recorded using standard mobile hardware (e.g., iPhone 13+, Samsung Galaxy S22+), positioned at waist-height (approx. 1 meter), exactly 2 meters away, maintaining a strict lateral profile (90° side view).

### **G.2 Threshold Derivation Methodology**

Data annotation will involve two independent, certified strength and conditioning experts manually labeling the video frames to demarcate rep boundaries (start, bottom, end) and flagging specific frames where form errors occur. Inter-rater reliability between the two experts will be assessed using Cohen’s kappa, targeting a strict agreement score of ≥ 0.80.

The statistical derivation pipeline will operate as follows:

1. **Inference:** Run the raw video dataset through the ML Kit BlazePose inference engine to extract the time-series arrays of the 33 3D landmarks.  
2. **Feature Extraction:** Compute the relevant joint angles (2D Knee Angle, Torso Angle to vertical) for every frame.  
3. **Alignment:** Align the pose-derived time-series data with the expert manual labels.  
4. **Confidence Intervals:** Utilize a **Bias-Corrected and Accelerated (BCa) bootstrap** method (with 10,000 resamples) to estimate the 95% Confidence Intervals (CI) for the exact mathematical angle at which the human experts label a squat as "incomplete" or exhibiting "excessive lean."  
5. **Filtering:** Apply Median Absolute Deviation (MAD) filtering to reject anomalous tracking frames (e.g., rapid limb teleportation caused by temporary ML artifacting).  
6. **Final Thresholding:** The 20th percentile (P20) of the expert-approved depth angles becomes the FSM BOTTOM threshold, ensuring the algorithmic judgment aligns seamlessly with acceptable human coaching standards rather than theoretical absolute maximums.

### ---

**Checklist for Data Collection Team**

* \[ \] Mount mobile camera securely at exactly 1.0m height and 2.0m distance.  
* \[ \] Ensure lighting is anterior or overhead; avoid harsh backlighting.  
* \[ \] Instruct subjects to wear contrasting, form-fitting athletic clothing to minimize occlusion.  
* \[ \] Record Set 1: Perfect Form (8 reps).  
* \[ \] Record Set 2: Incomplete Depth (8 reps).  
* \[ \] Record Set 3: Excessive Forward Lean (8 reps).  
* \[ \] Sync video files to annotation server and assign to Expert A and Expert B.  
* \[ \] Run Cohen's Kappa on resulting annotations (Target \> 0.80).

## ---

**Section H: Implementation Constraints (Mobile)**

### **H.1 Real-Time Performance Budgets**

The paramount constraint for on-device mobile fitness analysis is processing latency. To provide true real-time, mid-rep audio feedback (e.g., cueing a user *during* their descent), the system must process the video frame, extract the 33 landmarks, compute the geometric heuristics, update the FSM, and trigger the audio engine at a minimum of **15 Frames Per Second (FPS)**. This dictates a draconian latency budget of **≤ 66 milliseconds per frame**.

* **Pose Inference Engine:** The ML Kit Pose Detection model (Base configuration) running on mid-range ARM CPUs (e.g., Snapdragon 7-series or older Apple A-series chips) consumes approximately **45 to 55 ms** per frame.  
* **Feature Extraction & Vector Math:** Calculating the necessary 2D planar angles (utilizing highly optimized dot products and arccosine functions) and Euclidean distances requires **\< 2 ms** of CPU time.  
* **FSM and Logic Update:** Evaluating the boolean state transitions and heuristic thresholds takes **\< 1 ms**.  
* **Rendering/UI:** Overlaying the skeletal mesh onto the camera preview and triggering UI alerts consumes the remaining **5 to 8 ms**.

This lean architecture comfortably fits within the 66ms budget. Opting for the "Accurate" mode of the BlazePose model pushes inference times well above 100ms on mid-range devices, effectively halving the framerate to \<10 FPS. This introduces unacceptable temporal lag, making velocity calculations (VBT) entirely erratic and delaying audio cues until the user has already completed the repetition. The "Base" model is heavily recommended.

### **H.2 Robustness to Real-World Conditions**

1. **Confidence Gating:** The BlazePose output includes a visibility/confidence score ranging from \[0.0, 1.0\] for every landmark.60 The FSM must be programmed to suspend state updates if the confidence score for critical joints (Hip, Knee, or Ankle) drops below **0.50**. This failsafe prevents the FSM from transitioning states based on wildly hallucinated coordinates when the user's leg is temporarily occluded by a squat rack or their own arms.  
2. **Temporal Smoothing:** Raw landmark coordinates inherently jitter from frame to frame, even when the user is perfectly still. A **1€ (One Euro) Filter** or a lightweight discrete Kalman filter must be applied to the raw (x,y) coordinates prior to any angle calculation. This effectively eliminates high-frequency noise while preserving phase responsiveness during the fast concentric ascent.61  
3. **Clothing and Environment Mitigation:** Loose clothing obscures the true anatomical joint center, leading the ML model to guess the underlying skeletal structure. While lighting variations and background noise are generally well-handled by the robust BlazePose backbone 58, baggy clothing introduces a persistent offset bias in knee angle calculations. The application onboarding UI must explicitly prompt users to wear form-fitting athletic wear during the initial calibration and analysis phases.

## **Section I: Summary & Recommendations for MVP**

### **I.1 Recommended Squat Model for FiTrack MVP**

Synthesizing the exhaustive biomechanical research and the rigid technical constraints of mobile processing, the following specification is formally recommended for the initial MVP release of the squat analysis module:

1. **Squat Variant Target:** Standard Bodyweight Squat and Goblet Squat. These share a similar upright torso and deep knee flexion signature, minimizing self-occlusion.  
2. **Camera Constraint:** **Strict Side View (90° profile).** Frontal and 45° views are definitively rejected for the MVP due to extreme 2D FPPA inaccuracies, perspective distortion, and fatal z-axis ambiguity.  
3. **Rep-Counting FSM Parameters:**  
   * IDLE: Knee Angle \> 160°  
   * DESCENDING: Knee Angle \< 150° AND Hip-Y velocity \> 0 (10° hysteresis gap)  
   * BOTTOM: Knee Angle \< 100° AND Hip-Y velocity ≤ 0  
   * ASCENDING: Hip-Y velocity \< 0  
4. **Priority Form Errors:** Focus purely on sagittal plane errors detectable from the side view.  
   * *Incomplete Depth:* Knee\_Angle \> 100° at the BOTTOM state. (Cue: "Squat deeper").  
   * *Excessive Forward Lean:* Torso\_Angle \> 45° from vertical. (Cue: "Keep chest up").  
   * *Forward Knee Shift:* Knee\_X \> Toe\_X \+ (0.1 \* Thigh\_Length). (Cue: "Sit hips back").  
5. **Feedback Logic:** Dispatch audio cues only after 2 consecutive violations to filter noise, followed by a mandatory 5-second global audio cooldown. Apply a proportional deduction to the 1.0 perfect-rep score for each triggered error to calculate the final session grade.

### **I.2 Out-of-MVP Scope (Future Work)**

The following analytical features, while biomechanically highly relevant, require complex 3D spatial reconstruction, multi-camera setups, or custom ML models that exceed the current mobile processing boundaries, and should be slated for post-MVP development:

* **Dynamic Knee Valgus Detection:** Requires front-facing video and highly complex spatial normalization to overcome severe parallax distortion.  
* **Lumbar Flexion ("Butt Wink") Tracking:** The 33-landmark schema inherently lacks the necessary spinal segmentation to accurately detect L4-L5 vertebral rounding.  
* **Barbell Path Tracking:** Requires dedicated object detection models (e.g., YOLO) running concurrently with human pose estimation, exceeding the 66ms latency budget on mobile CPUs.  
* **Auto-Variant Detection:** Distinguishing a low-bar from a high-bar squat algorithmically before the rep begins is highly unreliable in 2D and should remain a user-selected toggle in the UI.

### ---

**Implementation Pseudocode (FSM & Heuristics)**

Dart

// Mobile-optimized Dart Pseudocode for Squat FSM and Error Detection  
class SquatAnalyzer {  
  SquatState currentState \= SquatState.IDLE;  
  int repCount \= 0;  
  int consecutiveLeanErrors \= 0;  
    
  // Normalized Winter's Constants  
  double thighLength;   
    
  void processFrame(Pose pose) {  
    if (pose.confidence \< 0.50) return; // Failsafe gating  
      
    double kneeAngle \= calculate2DAngle(pose.hip, pose.knee, pose.ankle);  
    double torsoAngle \= calculateAngleToVertical(pose.shoulder, pose.hip);  
    double hipVelocity \= calculateSmoothedVelocity(pose.hip.y);  
      
    // FSM Logic  
    switch (currentState) {  
      case SquatState.IDLE:  
        if (kneeAngle \< 150 && hipVelocity \> 0) {  
          currentState \= SquatState.DESCENDING;  
        }  
        break;  
          
      case SquatState.DESCENDING:  
        if (kneeAngle \< 100 && hipVelocity \<= 0) {  
          currentState \= SquatState.BOTTOM;  
        }  
        break;  
          
      case SquatState.BOTTOM:  
        evaluateFormErrors(kneeAngle, torsoAngle, pose);  
        if (hipVelocity \< 0) {  
          currentState \= SquatState.ASCENDING;  
        }  
        break;  
          
      case SquatState.ASCENDING:  
        if (kneeAngle \> 160) {  
          currentState \= SquatState.IDLE;  
          repCount++;  
        }  
        break;  
    }  
  }

  void evaluateFormErrors(double kneeAngle, double torsoAngle, Pose pose) {  
    if (torsoAngle \> 45.0) {  
      consecutiveLeanErrors++;  
      if (consecutiveLeanErrors \>= 2 &&\!isAudioOnCooldown()) {  
        triggerAudioCue("Keep your chest up");  
        startAudioCooldown(5.0); // 5 second cooldown  
      }  
    } else {  
      consecutiveLeanErrors \= 0;  
    }  
    // Implement depth and shift checks similarly...  
  }  
}

### **Generated Thresholds Data Table**

Code snippet

Error\_Type,Formula\_Logic,Threshold\_Value,CI\_Low,CI\_High,Variant,Camera\_View,Primary\_Source  
Incomplete\_Depth,Min(Knee\_Angle\_2D),\> 100 degrees,95,105,Bodyweight,Side\_90\_deg  
Excessive\_Lean,Arctan(Torso\_to\_Vertical),\> 45 degrees,42,48,Bodyweight,Side\_90\_deg  
Forward\_Knee\_Shift,(KneeX \- ToeX)/ThighLength,\> 0.10 units,0.08,0.12,Bodyweight,Side\_90\_deg  
Valgus\_Collapse,Delta(FPPA\_Angle\_2D),\> 15 degrees,12,18,Bodyweight,Front\_0\_deg  
Velocity\_Loss\_Fatigue,Drop in Mean Concentric Velocity,\> 30 percent,25,35,All,Side\_90\_deg

#### **Works cited**

1. Squat Mechanics and Muscle Activation: What EMG Shows About Every Major Variation, accessed April 25, 2026, [https://inara.technology/blog/squat-emg-guide](https://inara.technology/blog/squat-emg-guide)  
2. Squat Form – What does it tell us? Part 1 \- NASM Blog, accessed April 25, 2026, [https://blog.nasm.org/newletter/squat-form](https://blog.nasm.org/newletter/squat-form)  
3. Learn about the Normal Joint Range of Motion Study \- CDC Archive, accessed April 25, 2026, [https://archive.cdc.gov/www\_cdc\_gov/ncbddd/jointrom/index.html](https://archive.cdc.gov/www_cdc_gov/ncbddd/jointrom/index.html)  
4. The Use of Free Weight Squats in Sports: A Narrative Review—Terminology and Biomechanics \- MDPI, accessed April 25, 2026, [https://www.mdpi.com/2076-3417/14/5/1977](https://www.mdpi.com/2076-3417/14/5/1977)  
5. Impact of the deep squat on articular knee joint structures, friend or enemy? A scoping review \- PMC, accessed April 25, 2026, [https://pmc.ncbi.nlm.nih.gov/articles/PMC11618833/](https://pmc.ncbi.nlm.nih.gov/articles/PMC11618833/)  
6. The relationship between the deep squat movement and the hip, knee and ankle range of motion and muscle strength \- PMC, accessed April 25, 2026, [https://pmc.ncbi.nlm.nih.gov/articles/PMC7276781/](https://pmc.ncbi.nlm.nih.gov/articles/PMC7276781/)  
7. A Biomechanical Review of the Squat Exercise: Implications for Clinical Practice, accessed April 25, 2026, [https://ijspt.scholasticahq.com/article/94600-a-biomechanical-review-of-the-squat-exercise-implications-for-clinical-practice](https://ijspt.scholasticahq.com/article/94600-a-biomechanical-review-of-the-squat-exercise-implications-for-clinical-practice)  
8. Posterior Pelvic Tilt During the Squat: A Biomechanical Perspective and Possible Solution with Short-Term Exercise Intervention \- MDPI, accessed April 25, 2026, [https://www.mdpi.com/2076-3417/15/23/12526](https://www.mdpi.com/2076-3417/15/23/12526)  
9. Dynamic Deep Squat: Lower-Body Kinematics and Considerations Regarding Squat Technique, Load Position, and Heel Height | Request PDF \- ResearchGate, accessed April 25, 2026, [https://www.researchgate.net/publication/312395474\_Dynamic\_Deep\_Squat\_Lower-Body\_Kinematics\_and\_Considerations\_Regarding\_Squat\_Technique\_Load\_Position\_and\_Heel\_Height](https://www.researchgate.net/publication/312395474_Dynamic_Deep_Squat_Lower-Body_Kinematics_and_Considerations_Regarding_Squat_Technique_Load_Position_and_Heel_Height)  
10. Leaning Forward During Squat: 3 Fixes Explained \- Warm Body Cold Mind, accessed April 25, 2026, [https://blog.warmbody-coldmind.com/guides/leaning-forward-during-squat/](https://blog.warmbody-coldmind.com/guides/leaning-forward-during-squat/)  
11. Femur Length and Squat Form \- Brookbush Institute, accessed April 25, 2026, [https://brookbushinstitute.com/articles/femur-length-and-squat-form](https://brookbushinstitute.com/articles/femur-length-and-squat-form)  
12. How To Improve Your Ankle Mobility With Targeted Stretching \- GOWOD, accessed April 25, 2026, [https://www.gowod.app/blog/how-to-improve-ankle-mobility](https://www.gowod.app/blog/how-to-improve-ankle-mobility)  
13. A Biomechanical Review of the Squat Exercise: Implications for Clinical Practice \- PMC, accessed April 25, 2026, [https://pmc.ncbi.nlm.nih.gov/articles/PMC10987311/](https://pmc.ncbi.nlm.nih.gov/articles/PMC10987311/)  
14. The Connection Between Ankle Mobility & Squat Depth \- Foot Physio Training, accessed April 25, 2026, [https://footphysiotraining.com/post/the-connection-between-ankle-mobility--squat-depth](https://footphysiotraining.com/post/the-connection-between-ankle-mobility--squat-depth)  
15. Squatting Posture Grading System for Screening of Limited Ankle Dorsiflexion, accessed April 25, 2026, [https://www.e-arm.org/journal/view.php?number=4398](https://www.e-arm.org/journal/view.php?number=4398)  
16. When Posture Matters: The Importance of Lumbar Spine Alignment During Heavy Lifting, accessed April 25, 2026, [https://simplifaster.com/articles/when-posture-lumbar-spine-alignment-heavy-lifting/](https://simplifaster.com/articles/when-posture-lumbar-spine-alignment-heavy-lifting/)  
17. A Review of the Biomechanical Differences Between the High-Bar and Low-Bar Back-Squat, accessed April 25, 2026, [https://pubmed.ncbi.nlm.nih.gov/28570490/](https://pubmed.ncbi.nlm.nih.gov/28570490/)  
18. The Squat; A Bio-Mechanical Assessment \- Taylor's Strength Training, accessed April 25, 2026, [https://www.taylorsstrength.co.uk/the-squat-a-bio-mechanical-assessment/](https://www.taylorsstrength.co.uk/the-squat-a-bio-mechanical-assessment/)  
19. Squats the variations of a fundamental \- Sidea | Professional Fitness Equipment, accessed April 25, 2026, [https://www.sideaita.it/en/2025/06/05/squat-variations-of-a-fundamental/](https://www.sideaita.it/en/2025/06/05/squat-variations-of-a-fundamental/)  
20. Best Squat Variations: Machine, Barbell, Belt Squat, Front Squat | Booty Builder, accessed April 25, 2026, [https://bootybuilder.com/exercises/squat/best-variations/](https://bootybuilder.com/exercises/squat/best-variations/)  
21. The back squat: A proposed assessment of functional deficits and technical factors that limit performance \- PMC, accessed April 25, 2026, [https://pmc.ncbi.nlm.nih.gov/articles/PMC4262933/](https://pmc.ncbi.nlm.nih.gov/articles/PMC4262933/)  
22. The Cutting Movement Assessment Score (CMAS) Qualitative Screening Tool: Application to Mitigate Anterior Cruciate Ligament Injury Risk during Cutting \- MDPI, accessed April 25, 2026, [https://www.mdpi.com/2673-7078/1/1/7](https://www.mdpi.com/2673-7078/1/1/7)  
23. Dynamic Knee Valgus in Single-Leg Movement Tasks. Potentially Modifiable Factors and Exercise Training Options. A Literature Review \- PMC, accessed April 25, 2026, [https://pmc.ncbi.nlm.nih.gov/articles/PMC7664395/](https://pmc.ncbi.nlm.nih.gov/articles/PMC7664395/)  
24. PREDICTORS OF KNEE FUNCTIONAL JOINT STABILITY IN UNINJURED PHYSICALLY ACTIVE ADULTS by Nicholas, accessed April 25, 2026, [https://d-scholarship.pitt.edu/21279/1/ClarkNC\_PhD\_ETD\_2014\_v3.pdf](https://d-scholarship.pitt.edu/21279/1/ClarkNC_PhD_ETD_2014_v3.pdf)  
25. The Influence of Abnormal Hip Mechanics on Knee Injury: A Biomechanical Perspective | Journal of Orthopaedic & Sports Physical Therapy \- jospt, accessed April 25, 2026, [https://www.jospt.org/doi/full/10.2519/jospt.2010.3337?url\_ver=Z39.88-](https://www.jospt.org/doi/full/10.2519/jospt.2010.3337?url_ver=Z39.88-)  
26. Valgus Knee Collapse : Spring Arbor University \- Dartfish, accessed April 25, 2026, [https://www.dartfish.com/wp-content/uploads/2015/12/Use-Case\_Valgus-Collapse.pdf.pdf](https://www.dartfish.com/wp-content/uploads/2015/12/Use-Case_Valgus-Collapse.pdf.pdf)  
27. Squat Assessment: Understanding kinetics and kinematics \- VALD Health, accessed April 25, 2026, [https://valdhealth.com/news/squat-assessment-understanding-kinetics-and-kinematics](https://valdhealth.com/news/squat-assessment-understanding-kinetics-and-kinematics)  
28. Bottom-Up Kinetic Chain in Drop Landing among University Athletes with Normal Dynamic Knee Valgus \- MDPI, accessed April 25, 2026, [https://www.mdpi.com/1660-4601/17/12/4418](https://www.mdpi.com/1660-4601/17/12/4418)  
29. An Evidence-Based Videotaped Running Biomechanics Analysis | Request PDF, accessed April 25, 2026, [https://www.researchgate.net/publication/284013197\_An\_Evidence-Based\_Videotaped\_Running\_Biomechanics\_Analysis](https://www.researchgate.net/publication/284013197_An_Evidence-Based_Videotaped_Running_Biomechanics_Analysis)  
30. Common Mistakes When Doing Squats \- Precision Health Spine and Sports Clinic, accessed April 25, 2026, [https://precisionhealthclinics.com.au/common-mistakes-when-doing-squats/](https://precisionhealthclinics.com.au/common-mistakes-when-doing-squats/)  
31. The Influence of Different Heel Heights on Squatting Stability: A Systematic Review and Network Meta-Analysis \- MDPI, accessed April 25, 2026, [https://www.mdpi.com/2076-3417/15/5/2471](https://www.mdpi.com/2076-3417/15/5/2471)  
32. The Lumbar and Sacrum Movement Pattern During the Back Squat ..., accessed April 25, 2026, [https://www.researchgate.net/publication/47156847\_The\_Lumbar\_and\_Sacrum\_Movement\_Pattern\_During\_the\_Back\_Squat\_Exercise](https://www.researchgate.net/publication/47156847_The_Lumbar_and_Sacrum_Movement_Pattern_During_the_Back_Squat_Exercise)  
33. Posterior Pelvic Tilt During the Squat: A Biomechanical Perspective and Possible Exercise Solution \- Preprints.org, accessed April 25, 2026, [https://www.preprints.org/frontend/manuscript/584f217e3130c8e0fd312a016e8e068c/download\_pub](https://www.preprints.org/frontend/manuscript/584f217e3130c8e0fd312a016e8e068c/download_pub)  
34. Pelvic Tilt and Squats: Butt Winking and Posterior Pelvic Tilt \- \[P\]rehab \- The Prehab Guys, accessed April 25, 2026, [https://theprehabguys.com/pelvic-tilt-and-squat-depth/](https://theprehabguys.com/pelvic-tilt-and-squat-depth/)  
35. How accurate are visual assessments by physical therapists of lumbo-pelvic movements during the squat and deadlift? | Request PDF \- ResearchGate, accessed April 25, 2026, [https://www.researchgate.net/publication/352037283\_How\_accurate\_are\_visual\_assessments\_by\_physical\_therapists\_of\_lumbo-pelvic\_movements\_during\_the\_squat\_and\_deadlift](https://www.researchgate.net/publication/352037283_How_accurate_are_visual_assessments_by_physical_therapists_of_lumbo-pelvic_movements_during_the_squat_and_deadlift)  
36. Why Everyone Can & Should Squat the Same: 101 Truths — Advanced Human Performance Official Website | Home of Dr. Joel & Joshua Seedman, accessed April 25, 2026, [https://www.advancedhumanperformance.com/blog/squats-truths](https://www.advancedhumanperformance.com/blog/squats-truths)  
37. The relationship between static and dynamic postural deformities with pain and quality of life in non-athletic women \- PMC, accessed April 25, 2026, [https://pmc.ncbi.nlm.nih.gov/articles/PMC11446062/](https://pmc.ncbi.nlm.nih.gov/articles/PMC11446062/)  
38. On-device, Real-time Body Pose Tracking with MediaPipe BlazePose \- Google Research, accessed April 25, 2026, [https://research.google/blog/on-device-real-time-body-pose-tracking-with-mediapipe-blazepose/](https://research.google/blog/on-device-real-time-body-pose-tracking-with-mediapipe-blazepose/)  
39. Evaluating 3D Human Motion Capture on Mobile Devices \- mediaTUM, accessed April 25, 2026, [https://mediatum.ub.tum.de/doc/1663164/document.pdf](https://mediatum.ub.tum.de/doc/1663164/document.pdf)  
40. Exercise quantification from single camera view markerless 3D pose estimation \- PMC, accessed April 25, 2026, [https://pmc.ncbi.nlm.nih.gov/articles/PMC10951609/](https://pmc.ncbi.nlm.nih.gov/articles/PMC10951609/)  
41. Improving Gait Analysis Techniques with Markerless Pose Estimation Based on Smartphone Location \- PMC, accessed April 25, 2026, [https://pmc.ncbi.nlm.nih.gov/articles/PMC10886083/](https://pmc.ncbi.nlm.nih.gov/articles/PMC10886083/)  
42. (PDF) Reliability and Validity of Knee Valgus Angle Calculation at Single-leg Drop Landing by Posture Estimation Using Machine Learning \- ResearchGate, accessed April 25, 2026, [https://www.researchgate.net/publication/383372113\_Reliability\_and\_Validity\_of\_Knee\_Valgus\_Angle\_Calculation\_at\_Single-leg\_Drop\_Landing\_by\_Posture\_Estimation\_Using\_Machine\_Learning](https://www.researchgate.net/publication/383372113_Reliability_and_Validity_of_Knee_Valgus_Angle_Calculation_at_Single-leg_Drop_Landing_by_Posture_Estimation_Using_Machine_Learning)  
43. Reliability and validity of knee valgus angle calculation at single-leg drop landing by posture estimation using machine learning \- PMC, accessed April 25, 2026, [https://pmc.ncbi.nlm.nih.gov/articles/PMC11399566/](https://pmc.ncbi.nlm.nih.gov/articles/PMC11399566/)  
44. Is markerless, smart phone recorded two-dimensional video a clinically useful measure of relevant lower limb kinematics in runners with patellofemoral pain? A validity and reliability study \- ResearchGate, accessed April 25, 2026, [https://www.researchgate.net/publication/339156888\_Is\_markerless\_smart\_phone\_recorded\_two-dimensional\_video\_a\_clinically\_useful\_measure\_of\_relevant\_lower\_limb\_kinematics\_in\_runners\_with\_patellofemoral\_pain\_A\_validity\_and\_reliability\_study](https://www.researchgate.net/publication/339156888_Is_markerless_smart_phone_recorded_two-dimensional_video_a_clinically_useful_measure_of_relevant_lower_limb_kinematics_in_runners_with_patellofemoral_pain_A_validity_and_reliability_study)  
45. MindArc: On-Device AI For Digital Wellbeing and Habit Formation \- IRE Journals, accessed April 25, 2026, [https://www.irejournals.com/formatedpaper/1716250.pdf](https://www.irejournals.com/formatedpaper/1716250.pdf)  
46. Rule-Based Exercise Posture Correction: Implementation ... \- TechRxiv, accessed April 25, 2026, [https://www.techrxiv.org/doi/pdf/10.36227/techrxiv.176162095.56568318](https://www.techrxiv.org/doi/pdf/10.36227/techrxiv.176162095.56568318)  
47. Proper Squat Progressions and Alignment Corrections \- NFPT, accessed April 25, 2026, [https://nfpt.com/proper-squat-progressions-and-alignment/](https://nfpt.com/proper-squat-progressions-and-alignment/)  
48. Anthropometric Data for Biomechanics | PDF | Science & Mathematics | Wellness \- Scribd, accessed April 25, 2026, [https://www.scribd.com/doc/83749033/Anthropometric-Winter-Tables](https://www.scribd.com/doc/83749033/Anthropometric-Winter-Tables)  
49. TABLE 4.1 Anthropometric Data \- Kinovea, accessed April 25, 2026, [https://www.kinovea.org/tools/references/2009%20-%20Winter%20-%20Table%204.1%20-%20Anthropometric%20data.pdf](https://www.kinovea.org/tools/references/2009%20-%20Winter%20-%20Table%204.1%20-%20Anthropometric%20data.pdf)  
50. How Femur Length Affects Squat Mechanics \- Bret Contreras, accessed April 25, 2026, [https://bretcontreras.com/how-femur-length-effects-squat-mechanics/](https://bretcontreras.com/how-femur-length-effects-squat-mechanics/)  
51. Velocity Based Training \- Exercise-Based Rehabilitation & Strength Training | Poseidon Performance Dartmouth, accessed April 25, 2026, [https://www.poseidonperformance.com/blog/velocity-based-training](https://www.poseidonperformance.com/blog/velocity-based-training)  
52. An applied guide to velocity-based training for maximal strength \- Sportsmith, accessed April 25, 2026, [https://www.sportsmith.co/articles/an-applied-guide-to-velocity-based-training-for-maximal-strength/](https://www.sportsmith.co/articles/an-applied-guide-to-velocity-based-training-for-maximal-strength/)  
53. Estimating 1RM with velocity based training: a VBT guide \- VBTcoach, accessed April 25, 2026, [https://www.vbtcoach.com/blog/1rm-and-velocity-based-training-vbt-a-complete-guide](https://www.vbtcoach.com/blog/1rm-and-velocity-based-training-vbt-a-complete-guide)  
54. Effects of In-Season Velocity-Based vs. Traditional Resistance Training in Elite Youth Male Soccer Players \- MDPI, accessed April 25, 2026, [https://www.mdpi.com/2076-3417/14/20/9192](https://www.mdpi.com/2076-3417/14/20/9192)  
55. Velocity loss thresholds: VBT fatigue tracking \- VBTcoach, accessed April 25, 2026, [https://www.vbtcoach.com/blog/velocity-loss-guidelines-for-fatigue-with-velocity-based-training](https://www.vbtcoach.com/blog/velocity-loss-guidelines-for-fatigue-with-velocity-based-training)  
56. CVPR Poster M3GYM: A Large-Scale Multimodal Multi-view Multi-person Pose Dataset for Fitness Activity Understanding in Real-world Settings, accessed April 25, 2026, [https://cvpr.thecvf.com/virtual/2025/poster/32762](https://cvpr.thecvf.com/virtual/2025/poster/32762)  
57. Qingzheng Xu, Ru Cao, Xin Shen, Heming Du, Sen Wang, Xin Yu; Proceedings of the IEEE/CVF Conference on Computer Vision and Pattern Recognition (CVPR), 2025, pp. 12289-12300 \- CVF Open Access, accessed April 25, 2026, [https://openaccess.thecvf.com/content/CVPR2025/html/Xu\_M3GYM\_A\_Large-Scale\_Multimodal\_Multi-view\_Multi-person\_Pose\_Dataset\_for\_Fitness\_CVPR\_2025\_paper.html](https://openaccess.thecvf.com/content/CVPR2025/html/Xu_M3GYM_A_Large-Scale_Multimodal_Multi-view_Multi-person_Pose_Dataset_for_Fitness_CVPR_2025_paper.html)  
58. M3GYM: A Large-Scale Multimodal Multi-view Multi-person Pose Dataset for Fitness Activity Understanding in Real-world Settings, accessed April 25, 2026, [https://openaccess.thecvf.com/content/CVPR2025/papers/Xu\_M3GYM\_A\_Large-Scale\_Multimodal\_Multi-view\_Multi-person\_Pose\_Dataset\_for\_Fitness\_CVPR\_2025\_paper.pdf?utm\_source=kaleen.beehiiv.com\&utm\_medium=newsletter\&utm\_campaign=powerhouse-post-no9](https://openaccess.thecvf.com/content/CVPR2025/papers/Xu_M3GYM_A_Large-Scale_Multimodal_Multi-view_Multi-person_Pose_Dataset_for_Fitness_CVPR_2025_paper.pdf?utm_source=kaleen.beehiiv.com&utm_medium=newsletter&utm_campaign=powerhouse-post-no9)  
59. Pose Trainer: Correcting Exercise Posture using Pose Estimation \- ResearchGate, accessed April 25, 2026, [https://www.researchgate.net/publication/324759769\_Pose\_Trainer\_Correcting\_Exercise\_Posture\_using\_Pose\_Estimation](https://www.researchgate.net/publication/324759769_Pose_Trainer_Correcting_Exercise_Posture_using_Pose_Estimation)  
60. Pose landmark detection guide | Google AI Edge, accessed April 25, 2026, [https://ai.google.dev/edge/mediapipe/solutions/vision/pose\_landmarker](https://ai.google.dev/edge/mediapipe/solutions/vision/pose_landmarker)  
61. Physics Informed Human Posture Estimation Based on 3D Landmarks from Monocular RGB-Videos \- arXiv, accessed April 25, 2026, [https://arxiv.org/html/2512.06783v1](https://arxiv.org/html/2512.06783v1)  
62. Smart Device Development for Gait Monitoring: Multimodal Feedback in an Interactive Foot Orthosis, Walking Aid, and Mobile Application \- MDPI, accessed April 25, 2026, [https://www.mdpi.com/2227-7080/13/12/588](https://www.mdpi.com/2227-7080/13/12/588)