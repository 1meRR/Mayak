import 'package:flutter/material.dart';

ThemeData buildAppTheme() {
  const background = Color(0xFF070B14);
  const surface = Color(0xFF101827);
  const surfaceAlt = Color(0xFF162238);
  const primary = Color(0xFF5D7CFF);
  const secondary = Color(0xFF24D1C7);
  const success = Color(0xFF22C55E);
  const danger = Color(0xFFFF5C7A);
  const text = Color(0xFFF4F7FF);
  const muted = Color(0xFF9AA8C7);

  final scheme = ColorScheme.fromSeed(
    seedColor: primary,
    brightness: Brightness.dark,
    primary: primary,
    secondary: secondary,
    surface: surface,
    error: danger,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: background,
    colorScheme: scheme,
    textTheme: const TextTheme(
      headlineLarge: TextStyle(
        color: text,
        fontWeight: FontWeight.w800,
        fontSize: 38,
        letterSpacing: -1.0,
      ),
      headlineMedium: TextStyle(
        color: text,
        fontWeight: FontWeight.w700,
        fontSize: 28,
      ),
      titleLarge: TextStyle(
        color: text,
        fontWeight: FontWeight.w700,
        fontSize: 20,
      ),
      titleMedium: TextStyle(
        color: text,
        fontWeight: FontWeight.w600,
        fontSize: 16,
      ),
      bodyLarge: TextStyle(
        color: text,
        fontSize: 16,
      ),
      bodyMedium: TextStyle(
        color: muted,
        fontSize: 14,
      ),
    ),
    cardTheme: CardThemeData(
      color: surface.withValues(alpha: 0.92),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(28),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surfaceAlt.withValues(alpha: 0.82),
      labelStyle: const TextStyle(color: muted),
      hintStyle: const TextStyle(color: muted),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: const BorderSide(color: primary, width: 1.3),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: surfaceAlt,
      contentTextStyle: const TextStyle(color: text),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      behavior: SnackBarBehavior.floating,
    ),
    appBarTheme: const AppBarTheme(
      centerTitle: false,
      backgroundColor: Colors.transparent,
      foregroundColor: text,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: primary,
      foregroundColor: Colors.white,
    ),
    iconTheme: const IconThemeData(color: text),
    dividerColor: Colors.white12,
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: surface,
      selectedItemColor: primary,
      unselectedItemColor: muted,
      type: BottomNavigationBarType.fixed,
      elevation: 0,
    ),
    extensions: const <ThemeExtension<dynamic>>[
      AppColors(
        background: background,
        surface: surface,
        surfaceAlt: surfaceAlt,
        primary: primary,
        secondary: secondary,
        success: success,
        danger: danger,
        text: text,
        muted: muted,
      ),
    ],
  );
}

@immutable
class AppColors extends ThemeExtension<AppColors> {
  final Color background;
  final Color surface;
  final Color surfaceAlt;
  final Color primary;
  final Color secondary;
  final Color success;
  final Color danger;
  final Color text;
  final Color muted;

  const AppColors({
    required this.background,
    required this.surface,
    required this.surfaceAlt,
    required this.primary,
    required this.secondary,
    required this.success,
    required this.danger,
    required this.text,
    required this.muted,
  });

  @override
  AppColors copyWith({
    Color? background,
    Color? surface,
    Color? surfaceAlt,
    Color? primary,
    Color? secondary,
    Color? success,
    Color? danger,
    Color? text,
    Color? muted,
  }) {
    return AppColors(
      background: background ?? this.background,
      surface: surface ?? this.surface,
      surfaceAlt: surfaceAlt ?? this.surfaceAlt,
      primary: primary ?? this.primary,
      secondary: secondary ?? this.secondary,
      success: success ?? this.success,
      danger: danger ?? this.danger,
      text: text ?? this.text,
      muted: muted ?? this.muted,
    );
  }

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) {
      return this;
    }

    return AppColors(
      background: Color.lerp(background, other.background, t) ?? background,
      surface: Color.lerp(surface, other.surface, t) ?? surface,
      surfaceAlt: Color.lerp(surfaceAlt, other.surfaceAlt, t) ?? surfaceAlt,
      primary: Color.lerp(primary, other.primary, t) ?? primary,
      secondary: Color.lerp(secondary, other.secondary, t) ?? secondary,
      success: Color.lerp(success, other.success, t) ?? success,
      danger: Color.lerp(danger, other.danger, t) ?? danger,
      text: Color.lerp(text, other.text, t) ?? text,
      muted: Color.lerp(muted, other.muted, t) ?? muted,
    );
  }
}