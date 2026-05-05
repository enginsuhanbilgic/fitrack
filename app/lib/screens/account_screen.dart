import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../services/database/user_repository.dart';

class AccountScreen extends StatefulWidget {
  const AccountScreen({
    super.key,
    required this.currentUser,
  });

  final AppUser currentUser;

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final UserRepository _repository = UserRepository();
  bool _isBusy = false;
  late Future<List<AppUser>> _usersFuture;

  @override
  void initState() {
    super.initState();
    _usersFuture = _repository.getAllUsers();
  }

  void _reload() {
    setState(() {
      _usersFuture = _repository.getAllUsers();
    });
  }

  Future<void> _activateUser(AppUser user) async {
    if (_isBusy || user.id == widget.currentUser.id) {
      return;
    }

    setState(() => _isBusy = true);
    try {
      await _repository.setActiveUser(user.id);
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to switch user: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  Future<void> _signOut() async {
    if (_isBusy) {
      return;
    }

    setState(() => _isBusy = true);
    try {
      await _repository.signOutAllUsers();
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to sign out: $e')),
      );
      setState(() => _isBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Active user',
                        style: TextStyle(color: Colors.white70),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        widget.currentUser.displayName ??
                            widget.currentUser.email ??
                            'User #${widget.currentUser.id}',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton.icon(
                  onPressed: _isBusy ? null : _signOut,
                  icon: const Icon(Icons.logout),
                  label: const Text('Sign out'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: FutureBuilder<List<AppUser>>(
              future: _usersFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }

                if (snapshot.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('Failed to load users: ${snapshot.error}'),
                    ),
                  );
                }

                final users = snapshot.data ?? const <AppUser>[];
                if (users.isEmpty) {
                  return const Center(child: Text('No users found.'));
                }

                return RefreshIndicator(
                  onRefresh: () async => _reload(),
                  child: ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: users.length,
                    separatorBuilder: (_, index) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final user = users[index];
                      final name = user.displayName ??
                          user.email ??
                          'User #${user.id}';

                      return ListTile(
                        leading: Icon(
                          user.isActive ? Icons.check_circle : Icons.person,
                          color:
                              user.isActive ? const Color(0xFF00E676) : null,
                        ),
                        title: Text(name),
                        subtitle: Text(
                          '${user.authMode.dbValue} · ${user.localUuid.substring(0, 8)}',
                        ),
                        trailing: user.id == widget.currentUser.id
                            ? const Text('Current')
                            : TextButton(
                                onPressed:
                                    _isBusy ? null : () => _activateUser(user),
                                child: const Text('Switch'),
                              ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
