// apps/desktop/lib/ui/theme.dart
import 'package:flutter/material.dart';

/// "Darkroom": ink-teal surfaces lit by an amber safelight. Amber marks the
/// one thing that is active right now; cyan marks what is verified and safe.
class LrColors {
  LrColors._();

  static const ink = Color(0xFF0F1B1D);
  static const surface = Color(0xFF152427);
  static const raised = Color(0xFF1C3135);
  static const line = Color(0xFF2A4246);
  static const safelight = Color(0xFFFFB547);
  static const verified = Color(0xFF5FD4C4);
  static const text = Color(0xFFE6EFEC);
  static const muted = Color(0xFF8EA6A2);
  static const danger = Color(0xFFFF6B5E);
}

ThemeData buildLrTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: LrColors.safelight,
    onPrimary: Color(0xFF2B1A00),
    primaryContainer: Color(0xFF4A3410),
    onPrimaryContainer: Color(0xFFFFDDB0),
    secondary: LrColors.verified,
    onSecondary: Color(0xFF00201C),
    secondaryContainer: Color(0xFF12403B),
    onSecondaryContainer: Color(0xFFB8F2E9),
    tertiary: LrColors.verified,
    onTertiary: Color(0xFF00201C),
    error: LrColors.danger,
    onError: Color(0xFF2D0500),
    errorContainer: Color(0xFF5C1A13),
    onErrorContainer: Color(0xFFFFDAD4),
    surface: LrColors.ink,
    onSurface: LrColors.text,
    onSurfaceVariant: LrColors.muted,
    surfaceContainerLowest: Color(0xFF0B1517),
    surfaceContainerLow: LrColors.surface,
    surfaceContainer: LrColors.surface,
    surfaceContainerHigh: LrColors.raised,
    surfaceContainerHighest: Color(0xFF233B40),
    outline: LrColors.line,
    outlineVariant: Color(0xFF223538),
    inverseSurface: LrColors.text,
    onInverseSurface: LrColors.ink,
    inversePrimary: Color(0xFF7A5300),
  );

  const family = 'Segoe UI Variable Text';
  const fallback = ['Segoe UI', 'Microsoft YaHei UI', 'Yu Gothic UI', 'Malgun Gothic', 'sans-serif'];

  final base = ThemeData(colorScheme: scheme, useMaterial3: true, fontFamily: family, fontFamilyFallback: fallback);
  final text = base.textTheme.copyWith(
    headlineSmall: const TextStyle(fontSize: 28, fontWeight: FontWeight.w600, letterSpacing: -0.4, height: 1.2),
    titleLarge: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, letterSpacing: -0.2),
    titleMedium: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
    bodyMedium: const TextStyle(fontSize: 14, height: 1.45),
    bodySmall: const TextStyle(fontSize: 13, height: 1.4, color: LrColors.muted),
  ).apply(bodyColor: LrColors.text, displayColor: LrColors.text);

  return base.copyWith(
    scaffoldBackgroundColor: LrColors.ink,
    textTheme: text,
    cardTheme: CardThemeData(
      color: LrColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: LrColors.line),
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: LrColors.ink,
      foregroundColor: LrColors.text,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    dividerTheme: const DividerThemeData(color: LrColors.line, space: 1, thickness: 1),
    dialogTheme: DialogThemeData(
      backgroundColor: LrColors.raised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: LrColors.line),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: LrColors.text,
        side: const BorderSide(color: LrColors.line),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: LrColors.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: LrColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: LrColors.line),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: LrColors.raised,
      contentTextStyle: TextStyle(color: LrColors.text),
      behavior: SnackBarBehavior.floating,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: LrColors.raised, borderRadius: BorderRadius.circular(6)),
      textStyle: const TextStyle(color: LrColors.text, fontSize: 12),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: LrColors.safelight, linearTrackColor: LrColors.raised),
    sliderTheme: const SliderThemeData(activeTrackColor: LrColors.safelight, thumbColor: LrColors.safelight),
  );
}
