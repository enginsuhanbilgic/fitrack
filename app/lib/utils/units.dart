/// Unit conversion + formatting helpers for the user profile.
///
/// Storage is always metric (cm, kg). These helpers convert at the UI
/// boundary — either when rendering metric values to the user in their
/// preferred system, or when parsing the user's typed input back to
/// metric for save.
///
/// All conversion factors are International System exact values. No
/// rounding inside the conversion — round only at format time.
library;

import '../models/user_profile.dart';

/// Inches per centimeter — 1 in = 2.54 cm exactly.
const double _kCmPerIn = 2.54;

/// Pounds per kilogram — 1 lb = 0.45359237 kg exactly.
const double _kKgPerLb = 0.45359237;

// ───────────────── height ─────────────────

/// Convert a stored cm value to inches.
double cmToIn(double cm) => cm / _kCmPerIn;

/// Convert a user-typed inch value to cm for storage.
double inToCm(double inches) => inches * _kCmPerIn;

/// Format a metric height for display in the user's preferred [Units].
/// Metric → "170 cm". Imperial → "5'7\"" (feet + inches).
String formatHeight(double? cm, Units units) {
  if (cm == null) return '—';
  if (units == Units.metric) {
    return '${cm.round()} cm';
  }
  final totalIn = cmToIn(cm);
  final feet = totalIn ~/ 12;
  final inches = (totalIn - feet * 12).round();
  // Carry-over when 11.5" rounds to 12 — convert to next foot.
  if (inches == 12) return "${feet + 1}'0\"";
  return "$feet'$inches\"";
}

// ───────────────── weight ─────────────────

/// Convert a stored kg value to pounds.
double kgToLb(double kg) => kg / _kKgPerLb;

/// Convert a user-typed pound value to kg for storage.
double lbToKg(double lb) => lb * _kKgPerLb;

/// Format a metric weight for display in the user's preferred [Units].
/// Metric → "70 kg". Imperial → "154 lb".
String formatWeight(double? kg, Units units) {
  if (kg == null) return '—';
  if (units == Units.metric) {
    return '${kg.round()} kg';
  }
  return '${kgToLb(kg).round()} lb';
}

// ───────────────── unit-suffix labels for form inputs ─────────────────

String heightUnitLabel(Units units) => units == Units.metric ? 'cm' : 'in';
String weightUnitLabel(Units units) => units == Units.metric ? 'kg' : 'lb';

// ───────────────── volume (used for Dashboard "weekly volume") ─────────────────

/// Format a rep-volume number with a thin space thousands separator,
/// independent of units (we count reps, not weight). Returns "1,234 reps".
String formatRepCount(int reps) {
  final s = reps.toString();
  final buf = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return '$buf reps';
}
