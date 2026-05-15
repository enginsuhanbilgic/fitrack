import 'dart:math' as math;

import '../core/constants.dart';
import '../models/landmark_types.dart';
import '../models/pose_result.dart';

/// Outcome of the setup-time camera-framing check.
///
/// Industry-standard "Frame Check" pattern (Nike Training Club, Tempo,
/// Tonal, Peloton Guide), specialised for FiTrack biceps curl: the whole
/// arm — from the wrist at full extension up to the head — must fit
/// inside the frame, and the camera lens must sit at mid-chest height.
/// Operates on normalised landmark coordinates (0..1 of frame); no frame
/// dimensions needed.
///
/// Four signals — all must pass for [ok]:
///   1. Head visible with top margin: `nose.y >= kSetupHeadTopMargin`.
///   2. Active wrist visible with bottom margin:
///      `wrist.y <= kSetupWristBottomMargin`.
///   3. Camera lens at mid-chest: shoulder-hip midpoint y within
///      `kSetupMidChestTolerance` of `kSetupMidChestTarget` (0.5).
///   4. Shoulder-hip tilt from vertical <= [kSetupTorsoTiltMaxDeg].
class SetupFramingResult {
  /// Whether framing is acceptable to proceed.
  final bool ok;

  /// Short user-facing hint when [ok] is false. `null` when ok.
  final String? hint;

  /// Diagnostics for tests and telemetry. Each may be `null` if the
  /// underlying landmarks were missing.
  final double? noseY;
  final double? wristY;
  final double? midChestY;
  final double? tiltDeg;

  const SetupFramingResult._({
    required this.ok,
    this.hint,
    this.noseY,
    this.wristY,
    this.midChestY,
    this.tiltDeg,
  });

  static const SetupFramingResult _missing = SetupFramingResult._(
    ok: false,
    hint: 'Step into frame — full arm and head must be visible',
  );
}

/// Returns the framing verdict for [pose].
///
/// Picks whichever shoulder–hip pair has higher confidence as the "active
/// side," then validates that side's wrist plus the nose plus the camera
/// height (via mid-chest midpoint). If neither side resolves, returns
/// [SetupFramingResult._missing].
SetupFramingResult evaluateSetupFraming(
  PoseResult pose, {
  double minConfidence = kSetupCurlMinConfidence,
}) {
  final leftS = pose.landmark(LM.leftShoulder, minConfidence: minConfidence);
  final leftH = pose.landmark(LM.leftHip, minConfidence: minConfidence);
  final rightS = pose.landmark(LM.rightShoulder, minConfidence: minConfidence);
  final rightH = pose.landmark(LM.rightHip, minConfidence: minConfidence);

  final leftScore = (leftS != null && leftH != null)
      ? leftS.confidence + leftH.confidence
      : -1.0;
  final rightScore = (rightS != null && rightH != null)
      ? rightS.confidence + rightH.confidence
      : -1.0;

  if (leftScore < 0 && rightScore < 0) return SetupFramingResult._missing;

  final useLeft = leftScore >= rightScore;
  final shoulder = useLeft ? leftS! : rightS!;
  final hip = useLeft ? leftH! : rightH!;
  final wrist = pose.landmark(
    useLeft ? LM.leftWrist : LM.rightWrist,
    minConfidence: minConfidence,
  );
  final nose = pose.landmark(LM.nose, minConfidence: minConfidence);

  // Signal 1 — head must be in frame with a top safety margin.
  if (nose == null) {
    return const SetupFramingResult._(
      ok: false,
      hint: 'Head not visible — raise the camera so your face is in frame',
    );
  }
  if (nose.y < kSetupHeadTopMargin) {
    return SetupFramingResult._(
      ok: false,
      hint: 'Head is clipping the top — step back or lower the camera',
      noseY: nose.y,
    );
  }

  // Signal 2 — active wrist (extended arm at rest) must be in frame with
  // a bottom safety margin. If the wrist is missing, the arm itself is
  // off-screen.
  if (wrist == null) {
    return SetupFramingResult._(
      ok: false,
      hint: 'Arm not fully visible — step back so your wrist is in frame',
      noseY: nose.y,
    );
  }
  if (wrist.y > kSetupWristBottomMargin) {
    return SetupFramingResult._(
      ok: false,
      hint: 'Wrist is clipping the bottom — step back or raise the camera',
      noseY: nose.y,
      wristY: wrist.y,
    );
  }

  // Signal 3 — camera at mid-chest height. Shoulder-hip midpoint y projects
  // near 0.5 when the optical axis crosses the body at mid-chest.
  final midChestY = (shoulder.y + hip.y) / 2.0;
  final midChestDelta = midChestY - kSetupMidChestTarget;
  if (midChestDelta.abs() > kSetupMidChestTolerance) {
    // Sign tells us direction: positive delta → body sitting low in frame
    // → camera is too high; negative → body sitting high → camera too low.
    final hint = midChestDelta > 0
        ? 'Lower the camera to chest height'
        : 'Raise the camera to chest height';
    return SetupFramingResult._(
      ok: false,
      hint: hint,
      noseY: nose.y,
      wristY: wrist.y,
      midChestY: midChestY,
    );
  }

  // Signal 4 — torso near-vertical.
  final dx = (shoulder.x - hip.x).abs();
  final dy = (shoulder.y - hip.y).abs();
  final tiltDeg = dy <= 0 ? 90.0 : math.atan2(dx, dy) * 180.0 / math.pi;
  if (tiltDeg > kSetupTorsoTiltMaxDeg) {
    return SetupFramingResult._(
      ok: false,
      hint: 'Hold the phone level and stand upright',
      noseY: nose.y,
      wristY: wrist.y,
      midChestY: midChestY,
      tiltDeg: tiltDeg,
    );
  }

  return SetupFramingResult._(
    ok: true,
    noseY: nose.y,
    wristY: wrist.y,
    midChestY: midChestY,
    tiltDeg: tiltDeg,
  );
}
