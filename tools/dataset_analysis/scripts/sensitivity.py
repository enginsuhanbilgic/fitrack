"""Single source of truth for sensitivity tier names across derivation scripts.

The Dart `FeedbackSensitivity` enum is the contract — adding a tier requires
updating `app/lib/core/types.dart` first; the unit test
`app/test/core/feedback_sensitivity_test.dart` fails if the enum length
diverges from 2. The constants below mirror that enum so the Python side
emits compatible blocks.

Sensitivity vs Form Audit doctrine (2026-05-14, PR A, `.agent_brain/SKILLS.md`):
these tiers govern *ROM gates only*. Form-audit thresholds are fixed and do
NOT iterate over `TIERS`.
"""

from __future__ import annotations

# Order matches FeedbackSensitivity.values: high first, then medium. Scripts
# iterate this tuple to emit one Dart block per tier; reordering changes the
# emitted block order in the derived report.
TIERS: tuple[str, ...] = ("high", "medium")

# Dart field-name suffix per tier. Matches the `ManualRomOverrides`
# convention — "Strict" / "Default" — so the emitted snippet pastes into
# the per-exercise `*_rom_defaults.dart` files unchanged.
TIER_SUFFIX: dict[str, str] = {
    "high": "Strict",
    "medium": "Default",
}
