import 'package:flutter_test/flutter_test.dart';
import 'package:fitrack/engine/curl/mad_outlier.dart';

void main() {
  group('isMadOutlier', () {
    test('returns false when window size is below 4', () {
      expect(isMadOutlier(<double>[], 100.0), isFalse);
      expect(isMadOutlier([10, 12, 11], 999.0), isFalse);
    });

    test('returns false when MAD is zero (constant window)', () {
      final constant = List<double>.filled(6, 25.0);
      expect(isMadOutlier(constant, 100.0), isFalse);
    });

    test('returns true when sample deviates more than threshold × MAD', () {
      final window = [10.0, 11.0, 10.5, 10.2, 10.8, 10.3];
      expect(isMadOutlier(window, 60.0), isTrue);
    });

    test('returns false when sample sits inside the MAD band', () {
      final window = [10.0, 11.0, 10.5, 10.2, 10.8, 10.3];
      expect(isMadOutlier(window, 10.7), isFalse);
    });
  });

  group('median', () {
    test('returns middle value for odd-length list', () {
      expect(median([1.0, 2.0, 3.0]), 2.0);
    });

    test('returns mean of the two middle values for even-length list', () {
      expect(median([1.0, 2.0, 3.0, 4.0]), 2.5);
    });

    test('single-element list returns that element', () {
      expect(median([7.5]), 7.5);
    });
  });
}
