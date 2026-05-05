# Biceps Curl — Technical Improvement Suggestions

## 1. Rep Tempo Tracking *(High value, low complexity)*

Track `DateTime` at each FSM transition. Compute:
- `concentricDuration` = IDLE→CONCENTRIC to CONCENTRIC→PEAK
- `eccentricDuration` = PEAK→ECCENTRIC to ECCENTRIC→IDLE

New `FormError`: `eccentricTooFast` — if eccentric < 1.5s, fire "Lower slowly."
The eccentric phase is where most muscle growth happens; users almost always rush it.

---

## 2. Per-Rep Quality Score *(High value, medium complexity)*

Compute a `[0.0–1.0]` quality score per rep instead of binary pass/fail:
- Start at 1.0
- Deduct for torso swing magnitude (proportional, not just threshold)
- Deduct for elbow drift magnitude
- Deduct for asymmetry
- Deduct for rushed eccentric
- Deduct for short ROM

Expose score in `RepSnapshot`. Show on `SummaryScreen` as "Average rep quality: 78%".
Foundation for fatigue detection and session comparison.

---

## 3. Bilateral Asymmetry Detection *(High value, low complexity — front view only)*

In front view, compare `leftPeakAngle` vs `rightPeakAngle` at rep completion.
If delta > 15° for 3+ consecutive reps → new `FormError.lateralAsymmetry`:
"Your right arm is lagging — focus on equal range."

Real injury-risk signal currently ignored by all mobile fitness apps.

---

## 4. Fatigue Detection via Rep Velocity Degradation *(High value, high complexity)*

Track concentric duration across reps via FSM timestamps. When the last 3 reps
average significantly slower than the first 3 reps → fire:
- "You're slowing down — great effort, push through"
- OR "Consider stopping — form may break down"

Pure kinematics from FSM timing — no accelerometer needed.
Genuinely novel for a mobile-only system.

## Priority Ranking

| # | Feature | User Value | Technical Novelty | Complexity | Priority |
|---|---------|-----------|-------------------|------------|----------|
| 1 | Rep tempo / eccentric speed | Very high | Medium | Low | **#1** |
| 2 | Per-rep quality score | Very high | High | Medium | **#2** |
| 3 | Bilateral asymmetry | High | Medium | Low | **#3** |
| 4 | Fatigue detection | High | Very high | Medium | **#4** |

---

## Recommended Starting Point

**#1 + #2 together** — they share FSM timing infrastructure and jointly produce
`SummaryScreen` data that makes the app feel like a real coach, not just a rep counter.
