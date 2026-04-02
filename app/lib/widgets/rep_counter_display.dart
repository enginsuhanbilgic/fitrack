import 'package:flutter/material.dart';
import '../core/types.dart';

/// Floating overlay that shows reps, set count, elbow angle, and form state.
class RepCounterDisplay extends StatelessWidget {
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
                '$reps',
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
                  const Text('REPS',
                      style: TextStyle(color: Colors.white54, fontSize: 12)),
                  Text('Set $sets',
                      style:
                          const TextStyle(color: Colors.white38, fontSize: 11)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 4),
          // State + angle.
          Text(
            '${state.name.toUpperCase()}'
            '${jointAngle != null ? '  ${jointAngle!.toInt()}°' : ''}',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          // Form errors.
          if (activeErrors.isNotEmpty) ...[
            const SizedBox(height: 6),
            for (final err in activeErrors)
              Text(
                _errorLabel(err),
                style: const TextStyle(
                    color: Colors.redAccent,
                    fontSize: 13,
                    fontWeight: FontWeight.w600),
              ),
          ],
        ],
      ),
    );
  }

  String _errorLabel(FormError err) => switch (err) {
    FormError.torsoSwing     => 'Keep your torso still',
    FormError.elbowDrift     => 'Keep your elbow still',
    FormError.shortRom       => 'Full range of motion',
    FormError.squatDepth     => 'Go deeper',
    FormError.trunkTibia     => 'Keep your chest up',
    FormError.hipSag         => 'Keep your body straight',
    FormError.pushUpShortRom => 'Go lower',
  };
}
