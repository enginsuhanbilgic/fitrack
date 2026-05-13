/// First-launch onboarding dialog — "Try FiTrack with sample data?"
///
/// Non-dismissible (`barrierDismissible: false`) so the user must make an
/// explicit choice before the dashboard mounts. Returns `true` when the user
/// taps "Use demo data", `false` for "Start fresh". The caller is responsible
/// for persisting the choice via `DemoService.recordOnboardingChoice`.
///
/// Per ADR-4 of `plans_of_claude/demo-mode-toggle.md`: this is a minimum
/// viable gate keyed by `onboarding_choice_made` pref. The full onboarding
/// flow (welcome / name / metrics / goals / permissions) lands later in
/// `PRODUCTION_ROADMAP.md` Phase 2 and will replace this dialog.
library;

import 'package:flutter/material.dart';

class FirstLaunchDemoDialog extends StatelessWidget {
  const FirstLaunchDemoDialog({super.key});

  /// Show the dialog. Returns the user's choice — `true` for demo, `false`
  /// for fresh. Never returns null (the dialog is non-dismissible).
  static Future<bool> show(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const FirstLaunchDemoDialog(),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Welcome to FiTrack'),
      content: const Text(
        'Would you like to start with a few sample workouts so you can see '
        'how the app looks with data? You can change this any time in Settings.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Start fresh'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Use demo data'),
        ),
      ],
    );
  }
}
