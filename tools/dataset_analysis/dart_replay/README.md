# Dart replay harness (Phase E)

Feeds extracted MediaPipe keypoints through the **real** `RepCounter` FSM
from `app/`, and compares detected rep boundaries against the manual
annotations to compute precision / recall / F1 per clip.

No Python port of the FSM: a second implementation would inevitably drift
from the shipping one. By depending on `../../../app` via a path dep, this
harness exercises the exact same state machine users run on-device.

## Running

```bash
cd tools/dataset_analysis/dart_replay
flutter pub get                         # once, to wire up the path dep
dart run bin/replay.dart                # defaults match the dataset layout
```

Outputs: `../data/derived/validation_report.md` (a Markdown table of
per-clip precision / recall / F1 plus a totals row).

## CLI flags

| flag | default | purpose |
|------|---------|---------|
| `--keypoints` | `../data/keypoints` | directory of `{clip_id}.jsonl` from `extract_keypoints.py` |
| `--videos` | `../data/annotations/videos.csv` | per-clip metadata (arm, fps) |
| `--reps` | `../data/annotations/reps.csv` | manual rep annotations |
| `--out` | `../data/derived/validation_report.md` | Markdown report destination |

## Scoring

For each clip:

* a **true positive** is a detected rep whose final frame falls inside an
  annotated rep's `[start_frame, end_frame]` window
* a **false positive** is a detected rep that never lines up with any
  annotation
* a **false negative** is an annotation with no matching detection

Matching is greedy in annotation order — each annotation pairs with at most
one detection.

## Analyzer note

`analysis_options.yaml` excludes `bin/**` because the `package:fitrack/*`
imports only resolve after `flutter pub get` has written the
`.dart_tool/package_config.json`. Once you run `pub get`, re-run
`flutter analyze` in this directory to verify the harness still compiles
against the current engine surface.
