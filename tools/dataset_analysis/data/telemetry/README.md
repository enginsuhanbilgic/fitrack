# Telemetry — raw sessions and derived thresholds

## Directory layout

```
telemetry/
  sessions/   — raw Diagnostics "Copy all" exports from the app
  derived/    — script output (threshold reports + Dart snippets)
```

## Naming convention

```
YYYY-MM-DD_<view>_<arm>_<notes>.txt
```

Examples:
- `2026-04-28_sideRight_left-arm_debug.txt`  — session logged as sideRight but physically left arm (known mirror-inversion bug)
- `2026-05-10_sideLeft_left-arm_goodform.txt` — session after bug fix

## How to reproduce a derived output

```bash
# Frame-signal mode (use when FSM never counted reps — broken thresholds):
python -m scripts.derive_thresholds_from_telemetry \
  --from-frames --view <view> --side <side> \
  data/telemetry/sessions/<filename>.txt \
  2>&1 | tee data/telemetry/derived/<filename>_thresholds.txt

# Default mode (use when FSM counted reps — rep.extremes lines present):
python -m scripts.derive_thresholds_from_telemetry \
  data/telemetry/sessions/<filename>.txt \
  2>&1 | tee data/telemetry/derived/<filename>_thresholds.txt
```

## Session index

| File | Date | View logged | Actual arm | Mode | Reps kept | Applied to |
|---|---|---|---|---|---|---|
| `2026-04-28_sideRight_left-arm_debug.txt` | 2026-04-28 | sideRight | left (bug) | --from-frames | 5/7 | `ManualRomOverrides.sideLeft/RightStrict/Default` |
