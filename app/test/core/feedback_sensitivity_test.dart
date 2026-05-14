import 'package:flutter_test/flutter_test.dart';
import 'package:fitrack/core/types.dart';

/// Guards the two-tier sensitivity rule (.agent_brain/SKILLS.md, 2026-05-14).
///
/// Adding a third tier (e.g. `low`/`Permissive`) requires updating every
/// `*_SENSITIVITIES` dict in `tools/dataset_analysis/scripts/`, every
/// downstream resolver, and the doctrine itself. This test fails at the
/// first symptom — the enum length — so the broader churn cannot land
/// silently.
void main() {
  test('FeedbackSensitivity has exactly two tiers', () {
    expect(FeedbackSensitivity.values.length, 2);
    expect(
      FeedbackSensitivity.values,
      containsAll(<FeedbackSensitivity>[
        FeedbackSensitivity.high,
        FeedbackSensitivity.medium,
      ]),
    );
  });
}
