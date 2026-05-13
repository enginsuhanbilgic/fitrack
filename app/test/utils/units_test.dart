/// Unit tests for `lib/utils/units.dart` — the conversion + formatting
/// helpers that bridge metric storage and the user's chosen [Units]
/// preference.
library;

import 'package:fitrack/models/user_profile.dart';
import 'package:fitrack/utils/units.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('cm <-> in conversions', () {
    test('round-trip preserves the value within rounding tolerance', () {
      const cmIn = 175.0;
      final back = inToCm(cmToIn(cmIn));
      // Conversion factor is exact (2.54), so the round-trip should be
      // bit-perfect. Use an epsilon anyway in case future precision drift
      // is introduced.
      expect((back - cmIn).abs(), lessThan(1e-9));
    });

    test('170 cm renders as 5\'7"', () {
      expect(formatHeight(170, Units.imperial), "5'7\"");
    });

    test('null height renders as em-dash', () {
      expect(formatHeight(null, Units.metric), '—');
      expect(formatHeight(null, Units.imperial), '—');
    });

    test('metric just shows whole cm', () {
      expect(formatHeight(170.4, Units.metric), '170 cm');
      expect(formatHeight(170.6, Units.metric), '171 cm');
    });

    test('rounding 11.5 inches carries to next foot', () {
      // 60.96 cm = 24.0 in exactly, so no carry case.
      // 182.88 cm = 72.0 in = 6'0" exactly. Use 182.5 cm = ~71.85 in,
      // rounds to 72 → should print 6'0", not 5'12".
      expect(formatHeight(182.5, Units.imperial), "6'0\"");
    });
  });

  group('kg <-> lb conversions', () {
    test('round-trip preserves the value within rounding tolerance', () {
      const kgIn = 72.5;
      final back = lbToKg(kgToLb(kgIn));
      expect((back - kgIn).abs(), lessThan(1e-9));
    });

    test('70 kg renders as 154 lb', () {
      expect(formatWeight(70, Units.imperial), '154 lb');
    });

    test('metric formats as whole kg', () {
      expect(formatWeight(70.4, Units.metric), '70 kg');
    });

    test('null weight renders as em-dash', () {
      expect(formatWeight(null, Units.metric), '—');
    });
  });

  group('unit suffix labels', () {
    test('return the right short label per system', () {
      expect(heightUnitLabel(Units.metric), 'cm');
      expect(heightUnitLabel(Units.imperial), 'in');
      expect(weightUnitLabel(Units.metric), 'kg');
      expect(weightUnitLabel(Units.imperial), 'lb');
    });
  });

  group('rep count formatting', () {
    test('single digit', () {
      expect(formatRepCount(5), '5 reps');
    });

    test('inserts thousands separators', () {
      expect(formatRepCount(1234), '1,234 reps');
      expect(formatRepCount(1234567), '1,234,567 reps');
    });

    test('zero', () {
      expect(formatRepCount(0), '0 reps');
    });
  });
}
