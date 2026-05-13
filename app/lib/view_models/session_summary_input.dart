import 'package:flutter/foundation.dart';

import '../core/rom_thresholds.dart';
import '../core/squat_rom_defaults.dart';
import '../core/types.dart';
import '../engine/curl/curl_rom_profile.dart';
import '../engine/push_up/push_up_rom_profile.dart';
import '../engine/squat/squat_rom_profile.dart';

/// Plain value class that captures every field [SessionSummaryViewModel]
/// needs from the host screen.
///
/// Exists to break the previous `view_models/` → `screens/` import cycle:
/// the screen builds one of these from its widget fields in `build()` and
/// passes it to `SessionSummaryViewModel.fromInput(...)`. The VM never
/// imports the screen, and tests can construct an input directly without
/// instantiating a `SummaryScreen` widget.
@immutable
class SessionSummaryInput {
  const SessionSummaryInput({
    required this.exercise,
    required this.totalReps,
    required this.totalSets,
    required this.sessionDuration,
    this.averageQuality,
    this.detectedView = CurlCameraView.unknown,
    this.repQualities = const [],
    this.fatigueDetected = false,
    this.asymmetryDetected = false,
    this.eccentricTooFastCount = 0,
    this.errorsTriggered = const {},
    this.errorCounts = const {},
    this.curlRepRecords = const [],
    this.squatVariant = SquatVariant.bodyweight,
    this.squatLongFemurLifter = false,
    this.squatRepMetrics = const [],
    this.bicepsSideRepMetrics = const [],
    this.curlProfile,
    this.pushUpProfile,
    this.squatProfile,
    this.autoCalSnapshot,
    this.squatAutoCalSnapshot,
    this.feedbackSensitivity = FeedbackSensitivity.medium,
  });

  final ExerciseType exercise;
  final int totalReps;
  final int totalSets;
  final Duration sessionDuration;
  final double? averageQuality;
  final CurlCameraView detectedView;
  final List<double> repQualities;
  final bool fatigueDetected;
  final bool asymmetryDetected;
  final int eccentricTooFastCount;
  final Set<FormError> errorsTriggered;
  final Map<FormError, int> errorCounts;
  final List<CurlRepRecord> curlRepRecords;
  final SquatVariant squatVariant;
  final bool squatLongFemurLifter;
  final List<SquatRepMetrics> squatRepMetrics;
  final List<BicepsSideRepMetrics> bicepsSideRepMetrics;
  final CurlRomProfile? curlProfile;
  final PushUpRomProfile? pushUpProfile;
  final SquatRomProfile? squatProfile;
  final RomThresholds? autoCalSnapshot;
  final SquatRomThresholdSet? squatAutoCalSnapshot;
  final FeedbackSensitivity feedbackSensitivity;
}
