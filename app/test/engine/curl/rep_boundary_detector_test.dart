import 'package:flutter_test/flutter_test.dart';
import 'package:fitrack/engine/curl/rep_boundary_detector.dart';

/// Builds a synthetic curl angle stream: starts at [topAngle], descends to
/// [bottomAngle] over [downFrames], stays a beat, ascends back over [upFrames].
List<double> _curlCycle({
  required double topAngle,
  required double bottomAngle,
  int downFrames = 15,
  int holdFrames = 3,
  int upFrames = 15,
}) {
  final out = <double>[];
  // Down-stroke (extension → flexion).
  for (var i = 0; i < downFrames; i++) {
    final t = i / (downFrames - 1);
    out.add(topAngle + (bottomAngle - topAngle) * t);
  }
  // Hold at bottom.
  for (var i = 0; i < holdFrames; i++) {
    out.add(bottomAngle);
  }
  // Up-stroke (flexion → extension).
  for (var i = 0; i < upFrames; i++) {
    final t = i / (upFrames - 1);
    out.add(bottomAngle + (topAngle - bottomAngle) * t);
  }
  return out;
}

void main() {
  late RepBoundaryDetector det;

  setUp(() => det = RepBoundaryDetector());
  tearDown(() => det.dispose());

  Future<List<RepExtreme>> _drive(List<double> angles) async {
    final got = <RepExtreme>[];
    final sub = det.extremes.listen(got.add);
    for (final a in angles) {
      det.onAngle(a);
    }
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    return got;
  }

  group('happy path', () {
    test(
      'a full down-up cycle emits one rep at the bottom turning point',
      () async {
        // Detector emits when descent flips to confirmed ascent — i.e. at
        // the bottom of the curl. A single full down-up suffices.
        final stream = _curlCycle(topAngle: 170, bottomAngle: 60);

        final got = await _drive(stream);

        expect(got, hasLength(1));
        expect(got.first.maxAngle, closeTo(170, 2));
        expect(got.first.minAngle, closeTo(60, 2));
      },
    );

    test('three full down-up cycles emit three reps', () async {
      final stream = <double>[];
      for (var i = 0; i < 3; i++) {
        stream.addAll(_curlCycle(topAngle: 170, bottomAngle: 65));
      }

      final got = await _drive(stream);
      expect(got, hasLength(3));
      for (final rep in got) {
        expect(rep.minAngle, closeTo(65, 3));
        expect(rep.maxAngle, closeTo(170, 3));
      }
    });
  });

  group('rejection rules', () {
    test('an excursion below kCalibrationMinExcursion is rejected', () async {
      // ROM = 30°, well below the 40° floor.
      final stream = _curlCycle(topAngle: 150, bottomAngle: 120);

      final got = await _drive(stream);
      expect(got, isEmpty);
    });

    test('a single jittery frame does not trigger a rep', () async {
      final stream = <double>[170, 170, 169, 170, 170, 170, 170, 170];

      final got = await _drive(stream);
      expect(got, isEmpty);
    });
  });

  group('bottom dwell guard', () {
    test(
      'long rest pause at bottom followed by clean ascent emits exactly one rep',
      () async {
        // Normal descent + long rest-pause (well above dwell threshold) + clean ascent.
        // Dwell counter only increments on moving frames in descending, so we
        // embed a few micro-drift descending samples during the rest. Then a
        // decisive ascent confirms after the dwell is satisfied.
        final stream = <double>[];
        // Descent 170 → 60 (22 frames).
        for (var i = 0; i < 22; i++) {
          stream.add(170 - (110 * i / 21));
        }
        // Rest at bottom with micro-drift (still trends slightly downward).
        for (var i = 0; i < 15; i++) {
          stream.add(60 - i * 0.05);
        }
        // Clean ascent.
        for (var i = 0; i < 20; i++) {
          stream.add(59.25 + (170 - 59.25) * i / 19);
        }

        final got = await _drive(stream);
        expect(got, hasLength(1));
      },
    );

    test(
      'clean bottom reversal with immediate ascent still emits (no false rejection)',
      () async {
        // Standard _curlCycle uses 15-frame descent — above the 8-frame dwell.
        // Guarantee the happy path is not regressed by the new guard.
        final stream = _curlCycle(topAngle: 170, bottomAngle: 60);
        final got = await _drive(stream);
        expect(got, hasLength(1));
      },
    );

    test(
      'short descent (below dwell threshold) followed by partial ascent does not emit',
      () async {
        // Descent of only 4 moving frames + ascent confirmation would flip
        // too early; the dwell guard must swallow the confirmation.
        final stream = <double>[
          170, 170, 170, // awaitingFirstMax plateau
          165, 160, 155, 150, // short 4-frame descent
          // Attempt ascent immediately — 3 ascending frames to confirm.
          155, 160, 165,
        ];
        final got = await _drive(stream);
        expect(got, isEmpty);
      },
    );
  });

  group('reset', () {
    test(
      'reset clears in-flight state so the next cycle is independent',
      () async {
        // First — drive a partial down-stroke.
        for (var a = 170.0; a > 100; a -= 5) {
          det.onAngle(a);
        }
        det.reset();

        // After reset, drive a complete cycle. With the bottom-emit algorithm
        // a single down-up suffices.
        final stream = _curlCycle(topAngle: 170, bottomAngle: 60);
        final got = await _drive(stream);
        expect(got, hasLength(1));
      },
    );
  });
}
