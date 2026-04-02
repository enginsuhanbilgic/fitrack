import 'package:flutter/material.dart';

import '../models/user_remote_identity.dart';
import '../services/database/user_repository.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.onUserCreated});

  final VoidCallback onUserCreated;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _displayNameController = TextEditingController();
  final _emailController = TextEditingController();
  final _remoteUserIdController = TextEditingController();
  final _remoteEmailController = TextEditingController();

  final UserRepository _repository = UserRepository();

  bool _isLoading = false;
  bool _isRemote = false;
  RemoteProviderType _provider = RemoteProviderType.customBackend;

  @override
  void dispose() {
    _displayNameController.dispose();
    _emailController.dispose();
    _remoteUserIdController.dispose();
    _remoteEmailController.dispose();
    super.dispose();
  }

  Future<void> _createUser() async {
    final isValid = _formKey.currentState?.validate() ?? false;
    if (!isValid) {
      return;
    }

    setState(() => _isLoading = true);

    try {
      final displayName = _displayNameController.text.trim().isEmpty
          ? null
          : _displayNameController.text.trim();
      final email = _emailController.text.trim().isEmpty
          ? null
          : _emailController.text.trim();
      final remoteEmail = _remoteEmailController.text.trim().isEmpty
          ? null
          : _remoteEmailController.text.trim();

      if (_isRemote) {
        await _repository.createRemoteUser(
          providerType: _provider,
          remoteUserId: _remoteUserIdController.text.trim(),
          displayName: displayName,
          email: email,
          remoteEmail: remoteEmail,
        );
      } else {
        await _repository.createLocalUser(
          displayName: displayName,
          email: email,
        );
      }

      if (!mounted) {
        return;
      }
      widget.onUserCreated();
    } catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to create user: $e')),
      );
      setState(() => _isLoading = false);
      return;
    }

    if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sign In / Register')),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[
              Color(0xFF0B1020),
              Color(0xFF121A33),
              Color(0xFF0A1F2B),
            ],
          ),
        ),
        child: SafeArea(
          child: Stack(
            children: [
              Positioned(
                top: -70,
                right: -40,
                child: Container(
                  width: 220,
                  height: 220,
                  decoration: BoxDecoration(
                    color: const Color(0xFF00E676).withValues(alpha: 0.14),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              Positioned(
                bottom: -90,
                left: -40,
                child: Container(
                  width: 240,
                  height: 240,
                  decoration: BoxDecoration(
                    color: const Color(0xFF26C6DA).withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.14),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            'Create your FiTrack profile',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            'Choose local or remote mode and create the user manually.',
                            style: TextStyle(color: Colors.white70),
                          ),
                          const SizedBox(height: 20),
                          SwitchListTile.adaptive(
                            value: _isRemote,
                            title: const Text('Create remote account'),
                            subtitle: Text(_isRemote ? 'Enabled' : 'Disabled'),
                            onChanged: _isLoading
                                ? null
                                : (value) {
                                    setState(() => _isRemote = value);
                                  },
                          ),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: _displayNameController,
                            enabled: !_isLoading,
                            decoration: const InputDecoration(
                              labelText: 'Display name',
                              hintText: 'Example: Kadir',
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _emailController,
                            enabled: !_isLoading,
                            keyboardType: TextInputType.emailAddress,
                            decoration: const InputDecoration(
                              labelText: 'Email (optional)',
                            ),
                          ),
                          if (_isRemote) ...[
                            const SizedBox(height: 16),
                            DropdownButtonFormField<RemoteProviderType>(
                              initialValue: _provider,
                              decoration: const InputDecoration(
                                labelText: 'Remote provider',
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value: RemoteProviderType.customBackend,
                                  child: Text('CUSTOM_BACKEND'),
                                ),
                                DropdownMenuItem(
                                  value: RemoteProviderType.google,
                                  child: Text('GOOGLE'),
                                ),
                                DropdownMenuItem(
                                  value: RemoteProviderType.apple,
                                  child: Text('APPLE'),
                                ),
                              ],
                              onChanged: _isLoading
                                  ? null
                                  : (value) {
                                      if (value == null) {
                                        return;
                                      }
                                      setState(() => _provider = value);
                                    },
                            ),
                            const SizedBox(height: 12),
                            TextFormField(
                              controller: _remoteUserIdController,
                              enabled: !_isLoading,
                              decoration: const InputDecoration(
                                labelText: 'Remote user ID',
                              ),
                              validator: (value) {
                                if (!_isRemote) {
                                  return null;
                                }
                                if (value == null || value.trim().isEmpty) {
                                  return 'Remote user ID is required';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 12),
                            TextFormField(
                              controller: _remoteEmailController,
                              enabled: !_isLoading,
                              keyboardType: TextInputType.emailAddress,
                              decoration: const InputDecoration(
                                labelText: 'Remote email (optional)',
                              ),
                            ),
                          ],
                          const SizedBox(height: 24),
                          FilledButton(
                            onPressed: _isLoading ? null : _createUser,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: _isLoading
                                  ? const SizedBox(
                                      height: 20,
                                      width: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Text('Create User and Continue'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
            
          ),
        ),
      ),
    );
  }
}
