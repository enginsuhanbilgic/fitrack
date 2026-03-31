import 'package:flutter/material.dart';

/// FiTrack app theme — dark, gym-friendly.
class FiTrackTheme {
  static const _primary = Color(0xFF00E676); // green accent
  static const _bg = Color(0xFF121212);
  static const _surface = Color(0xFF1E1E1E);

  static ThemeData get dark => ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: _bg,
        colorScheme: const ColorScheme.dark(
          primary: _primary,
          surface: _surface,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: _surface,
          elevation: 0,
          centerTitle: true,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: _primary,
            foregroundColor: Colors.black,
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      );
}
