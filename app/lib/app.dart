import 'package:flutter/material.dart';
import 'core/theme.dart';
import 'models/app_user.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'services/database/user_repository.dart';

class FiTrackApp extends StatelessWidget {
  const FiTrackApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FiTrack',
      debugShowCheckedModeBanner: false,
      theme: FiTrackTheme.dark,
      home: const _AuthGate(),
    );
  }
}

class _AuthGate extends StatefulWidget {
  const _AuthGate();

  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  final UserRepository _repository = UserRepository();
  late Future<AppUser?> _activeUserFuture;

  @override
  void initState() {
    super.initState();
    _activeUserFuture = _repository.getFirstActiveUser();
  }

  void _reloadUser() {
    setState(() {
      _activeUserFuture = _repository.getFirstActiveUser();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AppUser?>(
      future: _activeUserFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (snapshot.data == null) {
          return LoginScreen(onUserCreated: _reloadUser);
        }

        return HomeScreen(
          currentUser: snapshot.data!,
          onSessionChanged: _reloadUser,
        );
      },
    );
  }
}
