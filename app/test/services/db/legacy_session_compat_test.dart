/// Legacy session compatibility regression test.
///
/// The Squat Master Rebuild deprecates `FormError.trunkTibia` (replacement:
/// `excessiveForwardLean`). The enum value is RETAINED so legacy WP5 session
/// rows continue to deserialize via `FormError.values.byName('trunkTibia')`.
/// This test asserts that contract — flipping it on by removing `trunkTibia`
/// from the enum would silently break every pre-rebuild squat session in the
/// user's history.
library;

import 'package:fitrack/core/types.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FormError — legacy deserialization contract', () {
    test(
      'FormError.values.byName("trunkTibia") still resolves (deprecated, retained)',
      () {
        // The session repository deserializes form_errors rows via
        // `FormError.values.byName(name)`. Removing the deprecated value
        // would throw `ArgumentError` on every legacy row.
        expect(() => FormError.values.byName('trunkTibia'), returnsNormally);
        expect(FormError.values.byName('trunkTibia'), FormError.trunkTibia);
      },
    );

    test('new FormError values round-trip via byName', () {
      // Sanity check on the inverse direction — the names we'll write to
      // form_errors.error must round-trip cleanly.
      for (final err in [
        FormError.excessiveForwardLean,
        FormError.heelLift,
        FormError.forwardKneeShift,
      ]) {
        expect(FormError.values.byName(err.name), err);
      }
    });
  });

  group('ExerciseType — legacy bicepsCurl deserialization contract', () {
    test(
      'ExerciseType.values.byName("bicepsCurl") still resolves (deprecated, retained for DB compat)',
      () {
        // The v4 migration rewrites rows, but _parseExerciseType's try/catch
        // is the safety net. Removing the deprecated value would make byName
        // throw before the catch fires — this test ensures the value stays.
        // ignore: deprecated_member_use
        expect(() => ExerciseType.values.byName('bicepsCurl'), returnsNormally);
        // ignore: deprecated_member_use
        expect(
          ExerciseType.values.byName('bicepsCurl'),
          ExerciseType.bicepsCurl,
        );
      },
    );

    test(
      '_parseExerciseType fallback: unknown name returns bicepsCurlFront without throwing',
      () {
        // Simulate _parseExerciseType logic inline — mirrors the production
        // implementation in SqliteSessionRepository.
        ExerciseType parseExerciseType(String name) {
          try {
            return ExerciseType.values.byName(name);
          } catch (_) {
            return ExerciseType.bicepsCurlFront;
          }
        }

        // A truly unknown string (e.g. a future build that got rolled back)
        // must never throw — it falls back to bicepsCurlFront.
        expect(
          parseExerciseType('unknownExercise'),
          ExerciseType.bicepsCurlFront,
        );

        // The legacy name still resolves correctly via byName before the catch.
        // ignore: deprecated_member_use
        expect(parseExerciseType('bicepsCurl'), ExerciseType.bicepsCurl);

        // New names round-trip cleanly.
        expect(
          parseExerciseType('bicepsCurlFront'),
          ExerciseType.bicepsCurlFront,
        );
        expect(
          parseExerciseType('bicepsCurlSide'),
          ExerciseType.bicepsCurlSide,
        );
      },
    );
  });

  group('SquatVariant — name round-trip', () {
    test('SquatVariant.values.byName round-trips both members', () {
      for (final v in SquatVariant.values) {
        expect(SquatVariant.values.byName(v.name), v);
      }
    });

    test('unknown name throws (handled by caller with try/catch)', () {
      expect(
        () => SquatVariant.values.byName('overheadSquat'),
        throwsArgumentError,
        reason:
            'The SQLite repo wraps this in a try/catch and falls back to '
            'bodyweight — see SqlitePreferencesRepository.getSquatVariant.',
      );
    });
  });
}
