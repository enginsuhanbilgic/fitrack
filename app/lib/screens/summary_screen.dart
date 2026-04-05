import 'package:flutter/material.dart';
import '../core/types.dart';

class SummaryScreen extends StatelessWidget {
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

  const SummaryScreen({
    super.key,
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
  });

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  Color _qualityColor(double? q) {
    if (q == null) return const Color(0xFF9E9E9E);
    if (q >= 0.80) return const Color(0xFF00E676); // green
    if (q >= 0.60) return const Color(0xFFFFB300); // amber
    return const Color(0xFFFF5252); // red
  }

  String _computeGrade(double? q) {
    if (q == null) return '—';
    final pct = q * 100;
    if (pct >= 90) return 'A';
    if (pct >= 80) return 'B';
    if (pct >= 65) return 'C';
    if (pct >= 50) return 'D';
    return 'F';
  }

  String _qualitySubtitle(double? q) {
    if (q == null) return 'No quality data.';
    if (q >= 0.85) return 'Excellent control. Maintain this pace and range.';
    if (q >= 0.70) return 'Good effort. Minor form deductions noted.';
    if (q >= 0.60) return 'Room for improvement. Review the insights below.';
    return 'Several form issues detected. Focus on the coaching tips.';
  }

  List<String> _buildInsights() {
    final insights = <String>[];

    if (eccentricTooFastCount > totalReps * 0.5) {
      insights.add('You rushed the lowering phase on most reps. Try a 2-second count on the way down.');
    } else if (eccentricTooFastCount > 0) {
      insights.add('You rushed the lowering on $eccentricTooFastCount rep(s). Slow, controlled lowering builds more muscle.');
    }

    if (fatigueDetected) {
      insights.add('Fatigue detected mid-session. Consider shorter sets with full recovery between them.');
    }

    if (asymmetryDetected) {
      insights.add('Your arms showed uneven range. Focus on matching both sides for balanced development.');
    }

    if (errorsTriggered.isEmpty || averageQuality != null && averageQuality! >= 0.85) {
      insights.add('Great session! Keep this tempo and range of motion.');
    }

    if (insights.isEmpty) {
      if (averageQuality != null && averageQuality! >= 0.85) {
        insights.add('Great session! Keep this tempo and range of motion.');
      } else {
        insights.add('Review the form issues above and focus on one correction at a time.');
      }
    }

    return insights;
  }

  String _viewLabel(CurlCameraView v) => switch (v) {
    CurlCameraView.front     => 'Front view',
    CurlCameraView.sideLeft  => 'Side view · Left',
    CurlCameraView.sideRight => 'Side view · Right',
    CurlCameraView.unknown   => 'Unknown',
  };

  IconData _errorIcon(FormError err) => switch (err) {
    FormError.torsoSwing       => Icons.swap_horiz,
    FormError.elbowDrift       => Icons.open_with,
    FormError.shortRom         => Icons.compress,
    FormError.eccentricTooFast => Icons.fast_forward_rounded,
    FormError.lateralAsymmetry => Icons.balance,
    FormError.fatigue          => Icons.battery_alert,
    _                          => Icons.error_outline,
  };

  String _errorLabel(FormError err) => switch (err) {
    FormError.torsoSwing       => 'Torso Swing',
    FormError.elbowDrift       => 'Elbow Drift',
    FormError.shortRom         => 'Short ROM',
    FormError.eccentricTooFast => 'Rushed Lowering',
    FormError.lateralAsymmetry => 'Arm Asymmetry',
    FormError.fatigue          => 'Fatigue',
    _                          => err.name,
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Workout Complete'),
      ),
      body: SafeArea(
        child: exercise == ExerciseType.bicepsCurl
            ? _buildCurlSummary(context)
            : _buildSimpleSummary(context),
      ),
    );
  }

  Widget _buildCurlSummary(BuildContext context) {
    final quality = averageQuality;
    final qualityColor = _qualityColor(quality);
    final insights = _buildInsights();

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // [1] Hero Header
          Center(
            child: Column(
              children: [
                Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: qualityColor.withValues(alpha: 0.15),
                  ),
                  child: Icon(Icons.check_circle_rounded, color: qualityColor, size: 64),
                ),
                const SizedBox(height: 16),
                Text(
                  exercise.label,
                  style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: qualityColor.withValues(alpha: 0.2),
                    border: Border.all(color: qualityColor, width: 1.5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Grade: ${_computeGrade(quality)}',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: qualityColor),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // [2] Stats Row — 3 chips
          Row(
            children: [
              Expanded(
                child: _StatChip(
                  icon: Icons.repeat,
                  label: 'REPS',
                  value: '$totalReps',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatChip(
                  icon: Icons.layers,
                  label: 'SETS',
                  value: '$totalSets',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatChip(
                  icon: Icons.timer,
                  label: 'TIME',
                  value: _formatDuration(sessionDuration),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // [3] Quality Score Card
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: qualityColor.withValues(alpha: 0.4), width: 1),
            ),
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.star_rounded, color: qualityColor, size: 20),
                    const SizedBox(width: 8),
                    const Text('Form Quality', style: TextStyle(color: Colors.white54, fontSize: 13)),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      '${(quality != null ? quality * 100 : 0).round()}',
                      style: TextStyle(fontSize: 56, fontWeight: FontWeight.bold, color: qualityColor),
                    ),
                    Text('%', style: TextStyle(fontSize: 24, color: qualityColor.withValues(alpha: 0.7))),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  _qualitySubtitle(quality),
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // [4] Per-Rep Quality Bar Chart
          if (repQualities.isNotEmpty) ...[
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(16),
              ),
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.bar_chart_rounded, color: Colors.white54, size: 20),
                      const SizedBox(width: 8),
                      const Text('Rep Quality', style: TextStyle(color: Colors.white54, fontSize: 13)),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Column(
                    children: repQualities.asMap().entries.map((entry) {
                      final repNum = entry.key + 1;
                      final repQuality = entry.value;
                      final barColor = _qualityColor(repQuality);

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 28,
                              child: Text('R$repNum',
                                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                                  textAlign: TextAlign.right),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: LayoutBuilder(
                                builder: (ctx, constraints) => Stack(
                                  children: [
                                    Container(
                                      width: constraints.maxWidth,
                                      height: 14,
                                      decoration: BoxDecoration(
                                        color: Colors.white.withValues(alpha: 0.07),
                                        borderRadius: BorderRadius.circular(7),
                                      ),
                                    ),
                                    Container(
                                      width: constraints.maxWidth * repQuality,
                                      height: 14,
                                      decoration: BoxDecoration(
                                        color: barColor,
                                        borderRadius: BorderRadius.circular(7),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 36,
                              child: Text('${(repQuality * 100).round()}%',
                                  style: TextStyle(color: barColor, fontSize: 11)),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          // [5] Form Analysis Card
          if (errorsTriggered.isNotEmpty) ...[
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(16),
              ),
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.warning_amber_rounded, color: Color(0xFFFFB300), size: 20),
                      const SizedBox(width: 8),
                      const Text('Form Issues Detected', style: TextStyle(color: Colors.white54, fontSize: 13)),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: errorsTriggered
                        .where((err) => ![
                          FormError.squatDepth,
                          FormError.trunkTibia,
                          FormError.hipSag,
                          FormError.pushUpShortRom,
                        ].contains(err))
                        .map((err) {
                      final chipColor = const Color(0xFFFF5252);
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                        decoration: BoxDecoration(
                          color: chipColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: chipColor.withValues(alpha: 0.5)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(_errorIcon(err), color: chipColor, size: 14),
                            const SizedBox(width: 6),
                            Text(_errorLabel(err),
                                style: TextStyle(color: chipColor, fontSize: 13)),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          // [6] Insights Card
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(16),
            ),
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.lightbulb_outline_rounded, color: Color(0xFF00E676), size: 20),
                    const SizedBox(width: 8),
                    const Text('Coaching Insights', style: TextStyle(color: Colors.white54, fontSize: 13)),
                  ],
                ),
                const SizedBox(height: 16),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: insights.asMap().entries.map((entry) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 4,
                            height: 4,
                            margin: const EdgeInsets.only(top: 6),
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Color(0xFF00E676),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              entry.value,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 14,
                                height: 1.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // [7] Camera View Chip
          if (detectedView != CurlCameraView.unknown)
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.videocam_outlined, color: Colors.white38, size: 14),
                    const SizedBox(width: 6),
                    Text(_viewLabel(detectedView),
                        style: const TextStyle(color: Colors.white38, fontSize: 12)),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 32),

          // Done Button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00E676),
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 18),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () => Navigator.of(context).popUntil((route) => route.isFirst),
              child: const Text('Done', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSimpleSummary(BuildContext context) {
    return Padding(
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
            onPressed: () => Navigator.of(context).popUntil((route) => route.isFirst),
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
    );
  }
}

class _StatChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _StatChip({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: const Color(0xFF00E676), size: 20),
          const SizedBox(height: 6),
          Text(value,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white)),
          Text(label,
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 11,
                letterSpacing: 1.2,
              )),
        ],
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
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 18)),
        Text(value,
            style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w600)),
      ],
    );
  }
}
