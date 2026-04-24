import '../core/types.dart';
import '../models/pose_result.dart';

/// Shared contract for every exercise's form analyzer.
///
/// Lifecycle (strict ordering per rep):
///   onRepStart(pose)           — once when the FSM leaves IDLE.
///   evaluate(pose)             — per-frame during any active state; returns
///                                frame-scoped errors.
///   consumeCompletionErrors()  — once at rep commit OR at abort; drains
///                                boundary errors accumulated during the rep.
///   reset()                    — restores first-use state (end of session,
///                                set rollover, or hard reset).
///
/// Drain invariant: a second call to [consumeCompletionErrors] without an
/// intervening [onRepStart] MUST return an empty list. Boundary errors are
/// one-shot and may not be replayed.
abstract class FormAnalyzerBase {
  void onRepStart(PoseResult startSnapshot);

  List<FormError> evaluate(PoseResult current);

  List<FormError> consumeCompletionErrors();

  void reset();
}
