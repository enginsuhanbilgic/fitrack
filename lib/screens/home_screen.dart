import 'package:flutter/material.dart';
import 'benchmark_screen.dart';

enum PoseModel { mlkit, mlkitFull, movenet, yoloPose }
enum InputSource { liveCamera, videoFile }
enum ExerciseType { bicepCurl }

extension PoseModelLabel on PoseModel {
  String get label {
    switch (this) {
      case PoseModel.mlkit:
        return 'ML Kit Lite';
      case PoseModel.mlkitFull:
        return 'ML Kit Full';
      case PoseModel.movenet:
        return 'MoveNet Lightning';
      case PoseModel.yoloPose:
        return 'YOLO-Pose';
    }
  }
}

extension ExerciseTypeLabel on ExerciseType {
  String get label => switch (this) {
    ExerciseType.bicepCurl => 'Bicep Curl',
  };
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  PoseModel _selectedModel = PoseModel.mlkit;
  ExerciseType _selectedExercise = ExerciseType.bicepCurl;

  void _navigateToBenchmark(InputSource source) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BenchmarkScreen(
          model: _selectedModel,
          source: source,
          exerciseType: _selectedExercise,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text('FiTrack Benchmark'),
        backgroundColor: const Color(0xFF1E1E1E),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 32),
            const Text(
              'Select Pose Model',
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: const Color(0xFF2A2A2A),
                borderRadius: BorderRadius.circular(12),
              ),
              child: DropdownButton<PoseModel>(
                value: _selectedModel,
                isExpanded: true,
                dropdownColor: const Color(0xFF2A2A2A),
                underline: const SizedBox(),
                style: const TextStyle(color: Colors.white, fontSize: 16),
                items: PoseModel.values.map((m) {
                  return DropdownMenuItem(value: m, child: Text(m.label));
                }).toList(),
                onChanged: (v) => setState(() => _selectedModel = v!),
              ),
            ),
            const SizedBox(height: 48),
            const Text(
              'Select Exercise',
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: const Color(0xFF2A2A2A),
                borderRadius: BorderRadius.circular(12),
              ),
              child: DropdownButton<ExerciseType>(
                value: _selectedExercise,
                isExpanded: true,
                dropdownColor: const Color(0xFF2A2A2A),
                underline: const SizedBox(),
                style: const TextStyle(color: Colors.white, fontSize: 16),
                items: ExerciseType.values.map((e) {
                  return DropdownMenuItem(value: e, child: Text(e.label));
                }).toList(),
                onChanged: (v) => setState(() => _selectedExercise = v!),
              ),
            ),
            const SizedBox(height: 48),
            const Text(
              'Select Input Source',
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 16),
            _SourceButton(
              icon: Icons.videocam,
              label: 'Live Camera',
              subtitle: 'Use emulator webcam for real-time inference',
              onTap: () => _navigateToBenchmark(InputSource.liveCamera),
            ),
            const SizedBox(height: 12),
            _SourceButton(
              icon: Icons.video_library,
              label: 'Upload Video',
              subtitle: 'Pick a video file and benchmark frame-by-frame',
              onTap: () => _navigateToBenchmark(InputSource.videoFile),
            ),
            const Spacer(),
            Text(
              'Model: ${_selectedModel.label}',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback onTap;

  const _SourceButton({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF2A2A2A),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Icon(icon, color: Colors.cyanAccent, size: 32),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_ios, color: Colors.white38, size: 16),
            ],
          ),
        ),
      ),
    );
  }
}
