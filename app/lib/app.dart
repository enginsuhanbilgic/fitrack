import 'package:flutter/material.dart';
import 'core/theme.dart';
import 'screens/home_screen.dart';

class FiTrackApp extends StatelessWidget {
  const FiTrackApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FiTrack',
      debugShowCheckedModeBanner: false,
      theme: FiTrackTheme.dark,
      home: const HomeScreen(),
    );
  }
}
