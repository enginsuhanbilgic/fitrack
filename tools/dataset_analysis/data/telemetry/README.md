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

The script now auto-saves the derived report into `derived/` whenever a file
path is passed as input. The filename matches the input stem with
`_thresholds.txt` appended. No shell `tee` plumbing required.

```bash
# Frame-signal mode (use when FSM never counted reps — broken thresholds):
python -m scripts.derive_thresholds_from_telemetry \
  --from-frames --view <view> --side <side> \
  data/telemetry/sessions/<filename>.txt
# → derived/<filename>_thresholds.txt auto-saved

# Default mode (use when FSM counted reps — rep.extremes lines present):
python -m scripts.derive_thresholds_from_telemetry \
  data/telemetry/sessions/<filename>.txt
# → derived/<filename>_thresholds.txt auto-saved
```

**Stdin invocations are NOT auto-saved** — that's the "quick experiment" mode.
Pass `--no-save` to disable auto-save even when a file path is given.
Existing derived files are overwritten silently — the session file is the
canonical source, so re-running on the same input is a deterministic refresh.

## Session index

| File | Date | View logged | Actual arm | Mode | Reps kept | Applied to |
|---|---|---|---|---|---|---|
| `2026-04-28_sideRight_left-arm_debug.txt` | 2026-04-28 | sideRight | left (bug) | --from-frames | 5/7 | `CurlRomDefaults.sideLeft/RightStrict/Default` |
