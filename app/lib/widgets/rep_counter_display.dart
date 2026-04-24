import 'package:flutter/material.dart';
import '../core/types.dart';

/// Floating overlay that shows reps, set count, elbow angle, and form state.
///
/// The FSM state is shown as a subtly animated pill — color shifts on each
/// state change via [AnimatedContainer]; the label swaps with a short fade
/// via [AnimatedSwitcher]. Form errors appear below with no extra decoration,
/// keeping the overlay quiet during normal reps.
class RepCounterDisplay extends StatefulWidget {
  final int reps;
  final int sets;
  final RepState state;
  final double? jointAngle;
  final List<FormError> activeErrors;

  const RepCounterDisplay({
    super.key,
    required this.reps,
    required this.sets,
    required this.state,
    this.jointAngle,
    this.activeErrors = const [],
  });

  @override
  State<RepCounterDisplay> createState() => _RepCounterDisplayState();
}

class _RepCounterDisplayState extends State<RepCounterDisplay> {
  /// Maps each FSM state to a muted accent color for the pill background.
  /// Chosen to be readable against the dark overlay without being jarring.
  static Color _pillColor(RepState s) => switch (s) {
    RepState.idle => const Color(0xFF2A2A2A),
    RepState.concentric => const Color(0xFF3D2B00), // dark amber
    RepState.peak => const Color(0xFF003D1A), // dark green
    RepState.eccentric => const Color(0xFF00213D), // dark blue
    RepState.descending => const Color(0xFF3D2B00),
    RepState.bottom => const Color(0xFF003D1A),
    RepState.ascending => const Color(0xFF00213D),
  };

  static Color _pillTextColor(RepState s) => switch (s) {
    RepState.idle => Colors.white38,
    RepState.concentric => const Color(0xFFFFB300), // amber
    RepState.peak => const Color(0xFF00E676), // green
    RepState.eccentric => const Color(0xFF40C4FF), // light blue
    RepState.descending => const Color(0xFFFFB300),
    RepState.bottom => const Color(0xFF00E676),
    RepState.ascending => const Color(0xFF40C4FF),
  };

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Rep count — big.
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${widget.reps}',
                style: const TextStyle(
                  color: Color(0xFF00E676),
                  fontSize: 48,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'REPS',
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  Text(
                    'Set ${widget.sets}',
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 6),

          // FSM state pill — color animates on state change, label fades.
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: _pillColor(widget.state),
              borderRadius: BorderRadius.circular(6),
            ),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Text(
                key: ValueKey(widget.state),
                _pillLabel(widget.state, widget.jointAngle),
                style: TextStyle(
                  color: _pillTextColor(widget.state),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8,
                ),
              ),
            ),
          ),

          // Form errors — shown only when present, no extra chrome.
          if (widget.activeErrors.isNotEmpty) ...[
            const SizedBox(height: 6),
            for (final err in widget.activeErrors)
              Text(
                _errorLabel(err),
                style: const TextStyle(
                  color: Colors.redAccent,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
          ],
        ],
      ),
    );
  }

  String _pillLabel(RepState s, double? angle) {
    final angleSuffix = angle != null ? '  ${angle.toInt()}°' : '';
    return '${_stateLabel(s)}$angleSuffix';
  }

  String _stateLabel(RepState s) => switch (s) {
    RepState.idle => 'READY',
    RepState.concentric => 'LIFTING',
    RepState.peak => 'PEAK',
    RepState.eccentric => 'LOWERING',
    RepState.descending => 'DESCENDING',
    RepState.bottom => 'BOTTOM',
    RepState.ascending => 'ASCENDING',
  };

  String _errorLabel(FormError err) => switch (err) {
    FormError.torsoSwing => 'Keep your torso still',
    FormError.elbowDrift => 'Keep your elbow still',
    FormError.shortRomStart => 'Start from full extension',
    FormError.shortRomPeak => 'Curl all the way up',
    FormError.squatDepth => 'Go deeper',
    FormError.trunkTibia => 'Keep your chest up',
    FormError.hipSag => 'Keep your body straight',
    FormError.pushUpShortRom => 'Go lower',
    FormError.eccentricTooFast => 'Lower slowly',
    FormError.concentricTooFast => 'Control the lift',
    FormError.tempoInconsistent => 'Keep steady tempo',
    FormError.asymmetryLeftLag => 'Left arm is lagging',
    FormError.asymmetryRightLag => 'Right arm is lagging',
    FormError.fatigue => "You're slowing down, stay strong",
  };
}
