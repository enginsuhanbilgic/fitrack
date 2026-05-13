library;

import '../../core/constants.dart';

class PushUpRomThresholds {
  const PushUpRomThresholds({
    required this.startAngle,
    required this.bottomAngle,
    required this.shallowRepMaxAngle,
    required this.endAngle,
  });

  static const defaults = PushUpRomThresholds(
    startAngle: kPushUpStartAngle,
    bottomAngle: kPushUpBottomAngle,
    shallowRepMaxAngle: kPushUpShallowRepMaxAngle,
    endAngle: kPushUpEndAngle,
  );

  final double startAngle;
  final double bottomAngle;
  final double shallowRepMaxAngle;
  final double endAngle;
}

class PushUpRomProfile {
  static const int schemaVersion = 1;

  const PushUpRomProfile({
    required this.topAngle,
    required this.bottomAngle,
    required this.sampleCount,
    required this.createdAt,
    required this.lastUpdated,
  });

  factory PushUpRomProfile.calibrated({
    required double topAngle,
    required double bottomAngle,
    int sampleCount = 1,
    DateTime? now,
  }) {
    final reason = validate(topAngle: topAngle, bottomAngle: bottomAngle);
    if (reason != null) {
      throw StateError(reason);
    }
    final timestamp = now ?? DateTime.now();
    return PushUpRomProfile(
      topAngle: topAngle,
      bottomAngle: bottomAngle,
      sampleCount: sampleCount,
      createdAt: timestamp,
      lastUpdated: timestamp,
    );
  }

  final double topAngle;
  final double bottomAngle;
  final int sampleCount;
  final DateTime createdAt;
  final DateTime lastUpdated;

  bool get isCalibrated => sampleCount > 0;

  double get romDegrees => topAngle - bottomAngle;

  PushUpRomThresholds get thresholds {
    final rom = romDegrees;
    final startMargin = _clampDouble(
      rom * 0.25,
      kPushUpProfileMinGateGap,
      kPushUpProfileStartMargin,
    );
    final start = _clampDouble(
      topAngle - startMargin,
      bottomAngle + (kPushUpProfileMinGateGap * 2),
      kPushUpEndAngle,
    );
    final bottomMargin = _clampDouble(
      rom * 0.20,
      kPushUpProfileMinGateGap,
      kPushUpProfileBottomMargin,
    );
    final bottom = _clampDouble(
      bottomAngle + bottomMargin,
      kPushUpCalibrationBottomMinAngle,
      start - (kPushUpProfileMinGateGap * 2),
    );
    final activeRom = start - bottom;
    final shallow = _clampDouble(
      bottom + (activeRom * 0.55),
      bottom + kPushUpProfileMinGateGap,
      start - kPushUpProfileMinGateGap,
    );
    final endMargin = _clampDouble(
      rom * 0.12,
      kPushUpProfileMinGateGap,
      kPushUpProfileEndMargin,
    );
    final maxEnd = topAngle - kPushUpProfileMinGateGap;
    final end = maxEnd <= start
        ? start
        : _clampDouble(start + endMargin, start, maxEnd);

    return PushUpRomThresholds(
      startAngle: start,
      bottomAngle: bottom,
      shallowRepMaxAngle: shallow,
      endAngle: end,
    );
  }

  static String? validate({
    required double topAngle,
    required double bottomAngle,
  }) {
    if (topAngle < kPushUpCalibrationTopMinAngle ||
        topAngle > kPushUpCalibrationTopMaxAngle) {
      return 'Top angle must be ${kPushUpCalibrationTopMinAngle.toStringAsFixed(0)}-'
          '${kPushUpCalibrationTopMaxAngle.toStringAsFixed(0)} degrees.';
    }
    if (bottomAngle < kPushUpCalibrationBottomMinAngle ||
        bottomAngle > kPushUpCalibrationBottomMaxAngle) {
      return 'Bottom angle must be ${kPushUpCalibrationBottomMinAngle.toStringAsFixed(0)}-'
          '${kPushUpCalibrationBottomMaxAngle.toStringAsFixed(0)} degrees.';
    }
    if ((topAngle - bottomAngle) < kPushUpCalibrationMinExcursion) {
      return 'Range too small. Start fully extended and go to your lowest controlled push-up.';
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'topAngle': topAngle,
    'bottomAngle': bottomAngle,
    'sampleCount': sampleCount,
    'createdAt': createdAt.toIso8601String(),
    'lastUpdated': lastUpdated.toIso8601String(),
  };

  factory PushUpRomProfile.fromJson(Map<String, dynamic> json) {
    final version = json['schemaVersion'] as int?;
    if (version != schemaVersion) {
      throw StateError(
        'PushUpRomProfile schema mismatch: got=$version expected=$schemaVersion',
      );
    }
    final profile = PushUpRomProfile(
      topAngle: (json['topAngle'] as num).toDouble(),
      bottomAngle: (json['bottomAngle'] as num).toDouble(),
      sampleCount: json['sampleCount'] as int? ?? 0,
      createdAt: DateTime.parse(json['createdAt'] as String),
      lastUpdated: DateTime.parse(json['lastUpdated'] as String),
    );
    final reason = validate(
      topAngle: profile.topAngle,
      bottomAngle: profile.bottomAngle,
    );
    if (reason != null) {
      throw StateError(reason);
    }
    return profile;
  }

  static double _clampDouble(double value, double min, double max) =>
      value.clamp(min, max).toDouble();
}
