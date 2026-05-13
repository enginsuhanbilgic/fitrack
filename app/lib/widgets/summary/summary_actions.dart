import 'package:flutter/material.dart';

/// Bottom action row on the Session Complete page.
///
/// Pre-unification, each exercise had a different exit affordance: curl/squat
/// relied solely on the app-bar X, push-up had a "Done" button. This widget
/// is the canonical bottom action row used by every exercise.
class SummaryActions extends StatelessWidget {
  const SummaryActions({super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF00E676),
          foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(vertical: 18),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        onPressed: () =>
            Navigator.of(context).popUntil((route) => route.isFirst),
        child: const Text(
          'Done',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}
