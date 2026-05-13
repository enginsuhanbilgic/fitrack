/// Edit Profile — captures display name, optional demographics, fitness
/// experience + primary goal, and the user's preferred [Units] / TTS /
/// haptics preferences. Reachable from the Profile tab.
///
/// Design constraints from the plan:
///   - Required field: `displayName` only.
///   - Storage is metric — height/weight inputs convert at save time.
///   - The form pre-populates from any saved profile; if none exists, the
///     screen acts as a first-time setup form (Save button enabled the
///     moment a non-empty name is typed).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme.dart';
import '../models/user_profile.dart';
import '../services/app_services.dart';
import '../services/db/preferences_repository.dart';
import '../services/db/user_profile_repository.dart';
import '../utils/units.dart';

class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  late final UserProfileRepository _userRepo;
  late final PreferencesRepository _prefsRepo;

  bool _bootstrapped = false;
  bool _saving = false;

  // Form state — initialized from the saved profile (or defaults) once
  // dependencies resolve.
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _ageCtrl = TextEditingController();
  final _heightCtrl = TextEditingController();
  final _weightCtrl = TextEditingController();

  String? _avatarEmoji;
  Gender? _gender;
  ExperienceLevel? _experience;
  FitnessGoal? _primaryGoal;
  Units _units = Units.metric;
  bool _ttsEnabled = true;
  bool _hapticsEnabled = true;

  /// Loaded profile (used for `createdAt` preservation on save). Null when
  /// the user has never saved a profile before.
  UserProfile? _existing;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_bootstrapped) return;
    _bootstrapped = true;
    final services = AppServicesScope.of(context);
    _userRepo = services.userProfileRepository;
    _prefsRepo = services.preferencesRepository;
    _hydrate();
  }

  Future<void> _hydrate() async {
    final profile = await _userRepo.load();
    final units = await _prefsRepo.getUnits();
    final tts = await _prefsRepo.getTtsEnabled();
    final haptics = await _prefsRepo.getHapticsEnabled();
    if (!mounted) return;
    setState(() {
      _existing = profile;
      _nameCtrl.text = profile?.displayName ?? '';
      _ageCtrl.text = profile?.age?.toString() ?? '';
      _avatarEmoji = profile?.avatarEmoji;
      _gender = profile?.gender;
      _experience = profile?.experience;
      _primaryGoal = profile?.primaryGoal;
      _units = units;
      _ttsEnabled = tts;
      _hapticsEnabled = haptics;
      _heightCtrl.text = _formatHeightInput(profile?.heightCm, units);
      _weightCtrl.text = _formatWeightInput(profile?.weightKg, units);
    });
  }

  String _formatHeightInput(double? cm, Units units) {
    if (cm == null) return '';
    return units == Units.metric
        ? cm.round().toString()
        : cmToIn(cm).round().toString();
  }

  String _formatWeightInput(double? kg, Units units) {
    if (kg == null) return '';
    return units == Units.metric
        ? kg.round().toString()
        : kgToLb(kg).round().toString();
  }

  /// When the user toggles units, re-render the height/weight fields in
  /// the new system without losing the underlying metric value.
  void _onUnitsChanged(Units next) {
    if (next == _units) return;
    final currentHeightCm = _parseHeightCm();
    final currentWeightKg = _parseWeightKg();
    setState(() {
      _units = next;
      _heightCtrl.text = _formatHeightInput(currentHeightCm, next);
      _weightCtrl.text = _formatWeightInput(currentWeightKg, next);
    });
  }

  double? _parseHeightCm() {
    final raw = _heightCtrl.text.trim();
    if (raw.isEmpty) return null;
    final n = double.tryParse(raw);
    if (n == null) return null;
    return _units == Units.metric ? n : inToCm(n);
  }

  double? _parseWeightKg() {
    final raw = _weightCtrl.text.trim();
    if (raw.isEmpty) return null;
    final n = double.tryParse(raw);
    if (n == null) return null;
    return _units == Units.metric ? n : lbToKg(n);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final now = DateTime.now();
    final created = _existing?.createdAt ?? now;
    final age = int.tryParse(_ageCtrl.text.trim());
    final heightCm = _parseHeightCm();
    final weightKg = _parseWeightKg();

    final profile = UserProfile(
      displayName: _nameCtrl.text.trim(),
      avatarEmoji: _avatarEmoji,
      age: age,
      gender: _gender,
      heightCm: heightCm,
      weightKg: weightKg,
      experience: _experience,
      primaryGoal: _primaryGoal,
      goals: _existing?.goals ?? const <UserGoal>[],
      createdAt: created,
      updatedAt: now,
    );

    try {
      // ADR-8 (Gap 34): user-driven saves promote the row to real.
      // Once the user types into the form, the data is theirs — `disable()`
      // will see `is_demo=0` and leave the row alone.
      await _userRepo.saveAsReal(profile);
      await _prefsRepo.setUnits(_units);
      await _prefsRepo.setTtsEnabled(_ttsEnabled);
      await _prefsRepo.setHapticsEnabled(_hapticsEnabled);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not save profile: $e')));
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _ageCtrl.dispose();
    _heightCtrl.dispose();
    _weightCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ft = FiTrackColors.of(context);
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: ft.bg,
      appBar: AppBar(
        backgroundColor: ft.bg,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text('Edit Profile'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(
                    'Save',
                    style: TextStyle(
                      color: ft.accent,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
          ),
        ],
        iconTheme: IconThemeData(color: cs.onSurface),
      ),
      body: !_bootstrapped
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  _SectionLabel('IDENTITY'),
                  _IdentityCard(
                    nameCtrl: _nameCtrl,
                    avatarEmoji: _avatarEmoji,
                    onAvatarChanged: (e) => setState(() => _avatarEmoji = e),
                  ),
                  const SizedBox(height: 20),
                  _SectionLabel('DEMOGRAPHICS'),
                  _DemographicsCard(
                    ageCtrl: _ageCtrl,
                    heightCtrl: _heightCtrl,
                    weightCtrl: _weightCtrl,
                    units: _units,
                    gender: _gender,
                    onGenderChanged: (g) => setState(() => _gender = g),
                  ),
                  const SizedBox(height: 20),
                  _SectionLabel('FITNESS'),
                  _FitnessCard(
                    experience: _experience,
                    onExperienceChanged: (v) => setState(() => _experience = v),
                    primaryGoal: _primaryGoal,
                    onPrimaryGoalChanged: (v) =>
                        setState(() => _primaryGoal = v),
                  ),
                  const SizedBox(height: 20),
                  _SectionLabel('PREFERENCES'),
                  _PreferencesCard(
                    units: _units,
                    onUnitsChanged: _onUnitsChanged,
                    ttsEnabled: _ttsEnabled,
                    onTtsChanged: (v) => setState(() => _ttsEnabled = v),
                    hapticsEnabled: _hapticsEnabled,
                    onHapticsChanged: (v) =>
                        setState(() => _hapticsEnabled = v),
                  ),
                ],
              ),
            ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sub-widgets
// ─────────────────────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    final ft = FiTrackColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
          color: ft.textDim,
        ),
      ),
    );
  }
}

class _IdentityCard extends StatelessWidget {
  const _IdentityCard({
    required this.nameCtrl,
    required this.avatarEmoji,
    required this.onAvatarChanged,
  });

  final TextEditingController nameCtrl;
  final String? avatarEmoji;
  final ValueChanged<String?> onAvatarChanged;

  static const List<String> _emojiOptions = [
    '💪',
    '🏋️',
    '🥊',
    '🧘',
    '🏃',
    '🚴',
    '⚡',
    '🔥',
    '🎯',
    '🦾',
  ];

  @override
  Widget build(BuildContext context) {
    final ft = FiTrackColors.of(context);
    return Container(
      decoration: ftCardDecoration(context),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: () => _pickEmoji(context),
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: ft.surface3,
                    shape: BoxShape.circle,
                    border: Border.all(color: ft.stroke),
                  ),
                  alignment: Alignment.center,
                  child: avatarEmoji != null
                      ? Text(avatarEmoji!, style: const TextStyle(fontSize: 28))
                      : Icon(Icons.add_reaction_outlined, color: ft.accent),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: TextFormField(
                  controller: nameCtrl,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Display name',
                    hintText: 'e.g. Alex',
                  ),
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) {
                      return 'Required';
                    }
                    if (v.trim().length > 40) return 'Max 40 characters';
                    return null;
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _pickEmoji(BuildContext context) async {
    final ft = FiTrackColors.of(context);
    final picked = await showModalBottomSheet<String?>(
      context: context,
      backgroundColor: ft.surface2,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Pick an avatar',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(ctx).colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final e in _emojiOptions)
                    GestureDetector(
                      onTap: () => Navigator.of(ctx).pop(e),
                      child: Container(
                        width: 48,
                        height: 48,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: ft.surface3,
                          shape: BoxShape.circle,
                          border: Border.all(color: ft.stroke),
                        ),
                        child: Text(e, style: const TextStyle(fontSize: 24)),
                      ),
                    ),
                  GestureDetector(
                    onTap: () => Navigator.of(ctx).pop(null),
                    child: Container(
                      width: 48,
                      height: 48,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: ft.surface3,
                        shape: BoxShape.circle,
                        border: Border.all(color: ft.stroke),
                      ),
                      child: Icon(Icons.close, color: ft.textMuted, size: 20),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Tap "×" to use initials instead.',
                style: TextStyle(fontSize: 12, color: ft.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
    onAvatarChanged(picked);
  }
}

class _DemographicsCard extends StatelessWidget {
  const _DemographicsCard({
    required this.ageCtrl,
    required this.heightCtrl,
    required this.weightCtrl,
    required this.units,
    required this.gender,
    required this.onGenderChanged,
  });

  final TextEditingController ageCtrl;
  final TextEditingController heightCtrl;
  final TextEditingController weightCtrl;
  final Units units;
  final Gender? gender;
  final ValueChanged<Gender?> onGenderChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: ftCardDecoration(context),
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          TextFormField(
            controller: ageCtrl,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(labelText: 'Age (years)'),
            validator: (v) {
              if (v == null || v.trim().isEmpty) return null; // optional
              final n = int.tryParse(v.trim());
              if (n == null || n < 10 || n > 120) return 'Enter 10–120';
              return null;
            },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<Gender?>(
            initialValue: gender,
            decoration: const InputDecoration(labelText: 'Gender'),
            items: [
              const DropdownMenuItem<Gender?>(
                value: null,
                child: Text('Not specified'),
              ),
              for (final g in Gender.values)
                DropdownMenuItem<Gender?>(value: g, child: Text(g.label)),
            ],
            onChanged: onGenderChanged,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: heightCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Height',
              suffixText: heightUnitLabel(units),
            ),
            validator: (v) => _validateHeight(v, units),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: weightCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Weight',
              suffixText: weightUnitLabel(units),
            ),
            validator: (v) => _validateWeight(v, units),
          ),
        ],
      ),
    );
  }

  static String? _validateHeight(String? v, Units units) {
    if (v == null || v.trim().isEmpty) return null;
    final n = double.tryParse(v.trim());
    if (n == null) return 'Enter a number';
    final cm = units == Units.metric ? n : inToCm(n);
    if (cm < 80 || cm > 250) return 'Out of range';
    return null;
  }

  static String? _validateWeight(String? v, Units units) {
    if (v == null || v.trim().isEmpty) return null;
    final n = double.tryParse(v.trim());
    if (n == null) return 'Enter a number';
    final kg = units == Units.metric ? n : lbToKg(n);
    if (kg < 20 || kg > 300) return 'Out of range';
    return null;
  }
}

class _FitnessCard extends StatelessWidget {
  const _FitnessCard({
    required this.experience,
    required this.onExperienceChanged,
    required this.primaryGoal,
    required this.onPrimaryGoalChanged,
  });

  final ExperienceLevel? experience;
  final ValueChanged<ExperienceLevel?> onExperienceChanged;
  final FitnessGoal? primaryGoal;
  final ValueChanged<FitnessGoal?> onPrimaryGoalChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: ftCardDecoration(context),
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          DropdownButtonFormField<ExperienceLevel?>(
            initialValue: experience,
            decoration: const InputDecoration(labelText: 'Experience level'),
            items: [
              const DropdownMenuItem<ExperienceLevel?>(
                value: null,
                child: Text('Not specified'),
              ),
              for (final e in ExperienceLevel.values)
                DropdownMenuItem<ExperienceLevel?>(
                  value: e,
                  child: Text(e.label),
                ),
            ],
            onChanged: onExperienceChanged,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<FitnessGoal?>(
            initialValue: primaryGoal,
            decoration: const InputDecoration(labelText: 'Primary goal'),
            items: [
              const DropdownMenuItem<FitnessGoal?>(
                value: null,
                child: Text('Not specified'),
              ),
              for (final g in FitnessGoal.values)
                DropdownMenuItem<FitnessGoal?>(value: g, child: Text(g.label)),
            ],
            onChanged: onPrimaryGoalChanged,
          ),
        ],
      ),
    );
  }
}

class _PreferencesCard extends StatelessWidget {
  const _PreferencesCard({
    required this.units,
    required this.onUnitsChanged,
    required this.ttsEnabled,
    required this.onTtsChanged,
    required this.hapticsEnabled,
    required this.onHapticsChanged,
  });

  final Units units;
  final ValueChanged<Units> onUnitsChanged;
  final bool ttsEnabled;
  final ValueChanged<bool> onTtsChanged;
  final bool hapticsEnabled;
  final ValueChanged<bool> onHapticsChanged;

  @override
  Widget build(BuildContext context) {
    final ft = FiTrackColors.of(context);
    return Container(
      decoration: ftCardDecoration(context),
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          DropdownButtonFormField<Units>(
            initialValue: units,
            decoration: const InputDecoration(labelText: 'Units'),
            items: [
              for (final u in Units.values)
                DropdownMenuItem<Units>(value: u, child: Text(u.label)),
            ],
            onChanged: (v) {
              if (v != null) onUnitsChanged(v);
            },
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Spoken coaching (TTS)'),
            subtitle: Text(
              'Audio cues during workouts',
              style: TextStyle(color: ft.textMuted, fontSize: 12),
            ),
            value: ttsEnabled,
            onChanged: onTtsChanged,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Haptic feedback'),
            subtitle: Text(
              'Vibration on rep complete + form alerts',
              style: TextStyle(color: ft.textMuted, fontSize: 12),
            ),
            value: hapticsEnabled,
            onChanged: onHapticsChanged,
          ),
        ],
      ),
    );
  }
}
