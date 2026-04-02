import 'package:flutter/material.dart';
import '../core/types.dart';

class SummaryScreen extends StatelessWidget {
  final ExerciseType exercise;
  final int totalReps;
  final int totalSets;
  final Duration sessionDuration;

  const SummaryScreen({
    super.key,
    required this.exercise,
    required this.totalReps,
    required this.totalSets,
    required this.sessionDuration,
  });

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(title: const Text('Workout Complete')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(
                Icons.check_circle_outline,
                color: Color(0xFF00E676),
                size: 96,
              ),
              const SizedBox(height: 24),
              Text(
                exercise.label,
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 48),
              _StatRow(label: 'Reps', value: '$totalReps'),
              const SizedBox(height: 16),
              _StatRow(label: 'Sets', value: '$totalSets'),
              const SizedBox(height: 16),
              _StatRow(label: 'Duration', value: _formatDuration(sessionDuration)),
              const Spacer(),
              ElevatedButton(
                onPressed: () =>
                    Navigator.of(context).popUntil((route) => route.isFirst),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                ),
                child: const Text(
                  'Done',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  final String label;
  final String value;

  const _StatRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label,
            style: const TextStyle(color: Colors.white54, fontSize: 18)),
        Text(value,
            style: const TextStyle(
                color: Colors.white, fontSize: 24, fontWeight: FontWeight.w600)),
      ],
    );
  }
}
