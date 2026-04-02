import 'package:flutter/material.dart';
import '../core/types.dart';
import 'workout_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('FiTrack')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 32),
              const Text(
                'Choose Exercise',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'Place your phone 2 m away and step back',
                style: TextStyle(color: Colors.white54),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 48),
              _ExerciseCard(
                icon: Icons.fitness_center,
                title: ExerciseType.bicepsCurl.label,
                subtitle: 'Front camera · stand 2 m away, side profile',
                enabled: true,
                onTap: () => _startWorkout(context, ExerciseType.bicepsCurl),
              ),
              const SizedBox(height: 16),
              _ExerciseCard(
                icon: Icons.airline_seat_legroom_extra,
                title: ExerciseType.squat.label,
                subtitle: 'Front camera · stand 2 m away, full body visible',
                enabled: true,
                onTap: () => _startWorkout(context, ExerciseType.squat),
              ),
              const SizedBox(height: 16),
              _ExerciseCard(
                icon: Icons.sports_gymnastics,
                title: ExerciseType.pushUp.label,
                subtitle: 'Side camera · place phone at floor level, 1.5 m away',
                enabled: true,
                onTap: () => _startWorkout(context, ExerciseType.pushUp),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _startWorkout(BuildContext context, ExerciseType exercise) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WorkoutScreen(exercise: exercise),
      ),
    );
  }
}

class _ExerciseCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;
  final VoidCallback onTap;

  const _ExerciseCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1.0 : 0.4,
      child: Material(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Icon(icon, size: 36, color: const Color(0xFF00E676)),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Text(subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 13)),
                    ],
                  ),
                ),
                if (enabled)
                  const Icon(Icons.chevron_right, color: Colors.white38),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
