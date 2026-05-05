import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

/// FiTrack — Kinetic Cyber design tokens.
///
/// Accent: electric green #c3f400
/// Secondary: cyan #00eefc
/// Surfaces: near-black layered from #0a0a0a → #353534
class FiTrackTheme {
  // ── Color tokens ────────────────────────────────────────
  static const Color accent = Color(0xFFC3F400); // electric green
  static const Color accentDim = Color(0xFFABD600);
  static const Color accentOn = Color(0xFF161E00); // text on accent bg
  static const Color cyan = Color(0xFF00EEFC);
  static const Color cyanSoft = Color(0xFF7DF4FF);
  static const Color purple = Color(0xFFD1BCFF);
  static const Color red = Color(0xFFFFB4AB);

  static const Color bg = Color(0xFF0A0A0A);
  static const Color surface = Color(0xFF131313);
  static const Color surface1 = Color(0xFF161618);
  static const Color surface2 = Color(0xFF1C1B1B);
  static const Color surface3 = Color(0xFF201F1F);
  static const Color surface4 = Color(0xFF2A2A2A);
  static const Color surface5 = Color(0xFF353534);

  static const Color stroke = Color(0xFF2D2D30);
  static const Color strokeDim = Color(0xFF444933);

  static const Color textPrimary = Color(0xFFE5E2E1);
  static const Color textDim = Color(0xFFC4C9AC);
  static const Color textMuted = Color(0xFF8E9379);

  // ── Typography ───────────────────────────────────────────
  // Space Grotesk (display) + Lexend (body) via google_fonts.
  static TextTheme get _textTheme => TextTheme(
    // Display — equivalent to .h1 in design (36px, w700, ls -0.02em)
    displayLarge: GoogleFonts.spaceGrotesk(
      fontSize: 36,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.72,
      height: 1.05,
      color: Colors.white,
    ),
    // .h2 — 24px, w700
    displayMedium: GoogleFonts.spaceGrotesk(
      fontSize: 24,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.24,
      height: 1.15,
      color: Colors.white,
    ),
    // .h3 — 18px, w600
    displaySmall: GoogleFonts.spaceGrotesk(
      fontSize: 18,
      fontWeight: FontWeight.w600,
      height: 1.2,
      color: Colors.white,
    ),
    // .label — 11px, w700, uppercase, ls 0.12em
    labelSmall: GoogleFonts.spaceGrotesk(
      fontSize: 11,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.32,
      color: const Color(0xFFC4C9AC),
    ),
    // .body — 14px, lh 1.55
    bodyMedium: GoogleFonts.lexend(
      fontSize: 14,
      fontWeight: FontWeight.w400,
      height: 1.55,
      color: const Color(0xFFC4C9AC),
    ),
    // .small — 12px
    bodySmall: GoogleFonts.lexend(
      fontSize: 12,
      fontWeight: FontWeight.w400,
      color: const Color(0xFF8E9379),
    ),
    // .data — tabular numerals, w700, ls -0.04em
    headlineLarge: GoogleFonts.spaceGrotesk(
      fontSize: 32,
      fontWeight: FontWeight.w700,
      letterSpacing: -1.28,
      height: 1.0,
      color: Colors.white,
    ),
  );

  // ── Light-mode surface stack (warm ivory / paper palette from design) ────
  // Design tokens: --bg:#f3f2ee --surface:#faf9f6 --surface-1:#fbfaf6
  // --surface-2:#f4f2ec --surface-3:#ecebe4 --surface-4:#ddddd5 --surface-5:#ccccc3
  static const Color bgLight = Color(0xFFF3F2EE);
  static const Color surfaceLight = Color(0xFFFAF9F6);
  static const Color surface1Light = Color(0xFFFBFAF6);
  static const Color surface2Light = Color(0xFFF4F2EC);
  static const Color surface3Light = Color(0xFFECEBE4);
  static const Color surface4Light = Color(0xFFDDDDD5);
  static const Color surface5Light = Color(0xFFCCCCC3);

  // Design: --stroke:#d8d6cd --stroke-dim:#c4c8b0
  static const Color strokeLight = Color(0xFFD8D6CD);
  static const Color strokeDimLight = Color(0xFFC4C8B0);

  // Design: --text-strong:#0d0e0a --text:#1a1c14 --text-dim:#4a4e3d --text-mute:#7a7e6a
  static const Color textStrongLight = Color(0xFF0D0E0A);
  static const Color textPrimaryLight = Color(0xFF1A1C14);
  static const Color textDimLight = Color(0xFF4A4E3D);
  static const Color textMutedLight = Color(0xFF7A7E6A);

  // Light mode accent: toned-down olive green so it reads on ivory (design: #5a8c00)
  static const Color accentLight = Color(0xFF5A8C00);
  static const Color accentDimLight = Color(0xFF4A7400);
  static const Color accentOnLight = Color(0xFFF7FFE0);
  // Light mode cyan: muted teal (design: #007a85)
  static const Color cyanLight = Color(0xFF007A85);
  static const Color cyanSoftLight = Color(0xFF0A9AA6);

  static TextTheme get _textThemeLight => TextTheme(
    // h1/h2 use text-strong (#0d0e0a) for maximum contrast on ivory
    displayLarge: GoogleFonts.spaceGrotesk(
      fontSize: 36,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.72,
      height: 1.05,
      color: textStrongLight,
    ),
    displayMedium: GoogleFonts.spaceGrotesk(
      fontSize: 24,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.24,
      height: 1.15,
      color: textStrongLight,
    ),
    displaySmall: GoogleFonts.spaceGrotesk(
      fontSize: 18,
      fontWeight: FontWeight.w600,
      height: 1.2,
      color: textStrongLight,
    ),
    labelSmall: GoogleFonts.spaceGrotesk(
      fontSize: 11,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.32,
      color: textDimLight,
    ),
    bodyMedium: GoogleFonts.lexend(
      fontSize: 14,
      fontWeight: FontWeight.w400,
      height: 1.55,
      color: textDimLight,
    ),
    bodySmall: GoogleFonts.lexend(
      fontSize: 12,
      fontWeight: FontWeight.w400,
      color: textMutedLight,
    ),
    // data numerals use text-strong for legibility
    headlineLarge: GoogleFonts.spaceGrotesk(
      fontSize: 32,
      fontWeight: FontWeight.w700,
      letterSpacing: -1.28,
      height: 1.0,
      color: textStrongLight,
    ),
  );

  static ThemeData get light {
    return ThemeData(
      brightness: Brightness.light,
      scaffoldBackgroundColor: bgLight,
      colorScheme: const ColorScheme.light(
        // In light mode the accent is olive-green (#5a8c00) so it stays readable
        // on the warm ivory background — neon #c3f400 would bloom on white.
        primary: accentLight,
        secondary: cyanLight,
        surface: surface1Light,
        onPrimary: accentOnLight,
        onSecondary: Colors.white,
        onSurface: textPrimaryLight,
        outline: strokeLight,
        outlineVariant: strokeLight,
      ),
      textTheme: _textThemeLight,
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: accentDimLight,
      ),
      appBarTheme: const AppBarTheme(
        // Warm ivory header to match --bg in light mode
        backgroundColor: bgLight,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        iconTheme: IconThemeData(color: textPrimaryLight),
        titleTextStyle: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.44,
          color: textPrimaryLight,
        ),
        systemOverlayStyle: SystemUiOverlayStyle.dark,
      ),
      cardTheme: CardThemeData(
        // Cards use --surface (#faf9f6), slightly warmer than bg
        color: surfaceLight,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
          side: BorderSide(color: strokeLight),
        ),
      ),
      dividerColor: strokeLight,
      dividerTheme: const DividerThemeData(
        color: strokeLight,
        thickness: 1,
        space: 0,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: surface3Light,
        labelStyle: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
          color: textDimLight,
        ),
        side: const BorderSide(color: strokeLight),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        shape: const StadiumBorder(),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accentLight,
          foregroundColor: accentOnLight,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          textStyle: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.04,
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textPrimaryLight,
          side: const BorderSide(color: strokeLight),
          backgroundColor: surface3Light,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          textStyle: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.04,
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: accentDimLight,
          textStyle: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.0,
          ),
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: surface2Light,
        border: UnderlineInputBorder(
          borderSide: BorderSide(color: strokeLight),
        ),
        enabledBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: strokeLight),
        ),
        focusedBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: accentDimLight),
        ),
        hintStyle: TextStyle(color: textMutedLight, fontSize: 15),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) =>
              s.contains(WidgetState.selected) ? accentOnLight : textMutedLight,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? accentLight : surface5Light,
        ),
      ),
      iconTheme: const IconThemeData(color: textMutedLight, size: 20),
      navigationBarTheme: NavigationBarThemeData(
        // Tabbar uses rgba(250,249,246,0.95) — the warm ivory at high opacity
        backgroundColor: const Color(0xF2FAF9F6),
        indicatorColor: const Color(0x385A8C00), // accentLight at ~22% opacity
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (s) => TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.4,
            color: s.contains(WidgetState.selected)
                ? accentDimLight
                : textMutedLight,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(
            color: s.contains(WidgetState.selected)
                ? accentDimLight
                : textMutedLight,
            size: 22,
          ),
        ),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: accentLight,
        linearTrackColor: surface4Light,
      ),
    );
  }

  static ThemeData get dark {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bg,
      colorScheme: const ColorScheme.dark(
        primary: accent,
        secondary: cyan,
        surface: surface1,
        onPrimary: accentOn,
        onSecondary: Colors.black,
        onSurface: textPrimary,
      ),
      textTheme: _textTheme,
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: FiTrackTheme.accent,
      ),
      // AppBar
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xD90A0A0A), // ~85% opacity
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        iconTheme: IconThemeData(color: textPrimary),
        titleTextStyle: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.44,
          color: textPrimary,
        ),
        systemOverlayStyle: SystemUiOverlayStyle.light,
      ),
      // Cards
      cardTheme: CardThemeData(
        color: surface1,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
          side: BorderSide(color: stroke),
        ),
      ),
      // Dividers
      dividerColor: stroke,
      dividerTheme: const DividerThemeData(
        color: stroke,
        thickness: 1,
        space: 0,
      ),
      // Chips
      chipTheme: ChipThemeData(
        backgroundColor: surface3,
        labelStyle: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
          color: textDim,
        ),
        side: const BorderSide(color: stroke),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        shape: const StadiumBorder(),
      ),
      // Buttons
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: accentOn,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          textStyle: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.04,
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textPrimary,
          side: const BorderSide(color: stroke),
          backgroundColor: surface3,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          textStyle: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.04,
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: accent,
          textStyle: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.0,
          ),
        ),
      ),
      // Input decoration
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: surface2,
        border: UnderlineInputBorder(borderSide: BorderSide(color: stroke)),
        enabledBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: stroke),
        ),
        focusedBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: accent),
        ),
        hintStyle: TextStyle(color: textMuted, fontSize: 15),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
      // Switch (used in Settings/Profile toggles)
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? accentOn : textMuted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? accent : surface5,
        ),
      ),
      // Icon
      iconTheme: const IconThemeData(color: textMuted, size: 20),
      // BottomNavigationBar / NavigationBar
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xF20A0A0A),
        indicatorColor: const Color(0x38C3F400), // accent @ ~22% opacity
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (s) => TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.4,
            color: s.contains(WidgetState.selected) ? accent : textMuted,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(
            color: s.contains(WidgetState.selected) ? accent : textMuted,
            size: 22,
          ),
        ),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      // Progress indicators
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: accent,
        linearTrackColor: surface4,
      ),
    );
  }
}

/// Context-aware color resolver. Use instead of FiTrackTheme static constants
/// so light/dark modes each get the correct token.
///
/// Example: FiTrackColors.of(context).accent
class FiTrackColors {
  FiTrackColors._(this._light);
  final bool _light;

  static FiTrackColors of(BuildContext context) =>
      FiTrackColors._(Theme.of(context).brightness == Brightness.light);

  Color get accent => _light ? FiTrackTheme.accentLight : FiTrackTheme.accent;
  Color get accentDim =>
      _light ? FiTrackTheme.accentDimLight : FiTrackTheme.accentDim;
  Color get accentOn =>
      _light ? FiTrackTheme.accentOnLight : FiTrackTheme.accentOn;
  Color get cyan => _light ? FiTrackTheme.cyanLight : FiTrackTheme.cyan;
  Color get cyanSoft =>
      _light ? FiTrackTheme.cyanSoftLight : FiTrackTheme.cyanSoft;
  Color get purple => FiTrackTheme.purple;
  Color get red => FiTrackTheme.red;

  Color get bg => _light ? FiTrackTheme.bgLight : FiTrackTheme.bg;
  Color get surface =>
      _light ? FiTrackTheme.surfaceLight : FiTrackTheme.surface;
  Color get surface1 =>
      _light ? FiTrackTheme.surface1Light : FiTrackTheme.surface1;
  Color get surface2 =>
      _light ? FiTrackTheme.surface2Light : FiTrackTheme.surface2;
  Color get surface3 =>
      _light ? FiTrackTheme.surface3Light : FiTrackTheme.surface3;
  Color get surface4 =>
      _light ? FiTrackTheme.surface4Light : FiTrackTheme.surface4;
  Color get surface5 =>
      _light ? FiTrackTheme.surface5Light : FiTrackTheme.surface5;

  Color get stroke => _light ? FiTrackTheme.strokeLight : FiTrackTheme.stroke;
  Color get strokeDim =>
      _light ? FiTrackTheme.strokeDimLight : FiTrackTheme.strokeDim;

  Color get textStrong => _light ? FiTrackTheme.textStrongLight : Colors.white;
  Color get textPrimary =>
      _light ? FiTrackTheme.textPrimaryLight : FiTrackTheme.textPrimary;
  Color get textDim =>
      _light ? FiTrackTheme.textDimLight : FiTrackTheme.textDim;
  Color get textMuted =>
      _light ? FiTrackTheme.textMutedLight : FiTrackTheme.textMuted;
}

/// Shared card decoration matching the design's `.card` style.
///
/// When [borderAccent] is set, use [FtAccentCard] instead of a raw Container —
/// Flutter forbids borderRadius on a Border with non-uniform side colors.
BoxDecoration ftCardDecoration(BuildContext context, {double radius = 12}) {
  final cs = Theme.of(context).colorScheme;
  return BoxDecoration(
    color: cs.surface,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: cs.outlineVariant),
  );
}

/// Card with a colored left-accent strip.  Use this instead of passing
/// [borderAccent] to a Container — Flutter disallows borderRadius on borders
/// with non-uniform side colors.
class FtAccentCard extends StatelessWidget {
  const FtAccentCard({
    super.key,
    required this.child,
    required this.accentColor,
    this.padding = const EdgeInsets.all(16),
    this.radius = 12.0,
  });

  final Widget child;
  final Color accentColor;
  final EdgeInsetsGeometry padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: Container(width: 3, color: accentColor),
            ),
            Padding(
              padding: padding.add(const EdgeInsets.only(left: 3)),
              child: child,
            ),
          ],
        ),
      ),
    );
  }
}

/// Accent-tinted pill chip — maps to design's `.chip-accent`.
class FtChip extends StatelessWidget {
  const FtChip({
    super.key,
    required this.label,
    this.tone = FtChipTone.neutral,
    this.dot = false,
    this.icon,
  });

  final String label;
  final FtChipTone tone;
  final bool dot;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final accentCol = isLight ? FiTrackTheme.accentLight : FiTrackTheme.accent;
    final cyanCol = isLight ? FiTrackTheme.cyanLight : FiTrackTheme.cyan;
    final surf3 = isLight ? FiTrackTheme.surface3Light : FiTrackTheme.surface3;
    final textD = isLight ? FiTrackTheme.textDimLight : FiTrackTheme.textDim;
    final strokeC = isLight ? FiTrackTheme.strokeLight : FiTrackTheme.stroke;
    final (bg, fg, border) = switch (tone) {
      FtChipTone.accent => (
        accentCol.withAlpha(0x1F),
        accentCol,
        accentCol.withAlpha(0x66),
      ),
      FtChipTone.cyan => (
        cyanCol.withAlpha(0x1F),
        cyanCol,
        cyanCol.withAlpha(0x66),
      ),
      FtChipTone.neutral => (surf3, textD, strokeC),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: fg, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
          ],
          if (icon != null) ...[
            Icon(icon, size: 12, color: fg),
            const SizedBox(width: 6),
          ],
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}

enum FtChipTone { accent, cyan, neutral }

/// Small sparkline drawn as a CustomPainter — maps to design's `FtSpark`.
class FtSparkline extends StatelessWidget {
  const FtSparkline({
    super.key,
    required this.data,
    this.color = FiTrackTheme.cyan,
    this.width = 80,
    this.height = 28,
  });

  final List<double> data;
  final Color color;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) return SizedBox(width: width, height: height);
    return CustomPaint(
      size: Size(width, height),
      painter: _SparklinePainter(data: data, color: color),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({required this.data, required this.color});
  final List<double> data;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;
    final max = data.reduce((a, b) => a > b ? a : b);
    final min = data.reduce((a, b) => a < b ? a : b);
    final range = max - min == 0 ? 1.0 : max - min;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    final path = Path();
    for (var i = 0; i < data.length; i++) {
      final x = (i / (data.length - 1)) * size.width;
      final y = size.height - ((data[i] - min) / range) * size.height;
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.data != data || old.color != color;
}

/// Progress ring — maps to design's `FtRing`.
class FtRing extends StatelessWidget {
  const FtRing({
    super.key,
    required this.value,
    this.size = 180,
    this.strokeWidth = 12,
    this.sublabel,
    this.color = FiTrackTheme.accent,
  });

  final double value; // 0–100
  final double size;
  final double strokeWidth;
  final String? sublabel;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size(size, size),
            painter: _RingPainter(
              value: value,
              strokeWidth: strokeWidth,
              color: color,
              trackColor: Theme.of(context).brightness == Brightness.light
                  ? FiTrackTheme.surface4Light
                  : FiTrackTheme.surface4,
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RichText(
                text: TextSpan(
                  children: [
                    TextSpan(
                      text: value.toInt().toString(),
                      style: TextStyle(
                        fontSize: size * 0.28,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -1,
                        color: color,
                        height: 1,
                      ),
                    ),
                    TextSpan(
                      text: '%',
                      style: TextStyle(
                        fontSize: size * 0.13,
                        fontWeight: FontWeight.w700,
                        color: color,
                      ),
                    ),
                  ],
                ),
              ),
              if (sublabel != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    sublabel!.toUpperCase(),
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.0,
                      color: Theme.of(context).brightness == Brightness.light
                          ? FiTrackTheme.textDimLight
                          : FiTrackTheme.textDim,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.value,
    required this.strokeWidth,
    required this.color,
    required this.trackColor,
  });

  final double value;
  final double strokeWidth;
  final Color color;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - strokeWidth) / 2;

    final track = Paint()
      ..color = trackColor
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(center, radius, track);

    final arc = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final sweep = (value / 100) * 2 * 3.14159265;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -3.14159265 / 2,
      sweep,
      false,
      arc,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.value != value || old.color != color || old.trackColor != trackColor;
}
