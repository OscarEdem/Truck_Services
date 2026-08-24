// lib/theme/app_theme.dart
import 'package:flutter/material.dart';

class AppTheme {
  // Brand palette from the mock
  static const Color _seed = Color(0xFF1565C0); // header/brand blue
  static const Color _ctaBlue = Color(0xFF3D5AFE); // primary CTA
  static const Color _fieldFill = Color(0xFFF0F4FF); // light-blue inputs

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: Brightness.light,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: Colors.white,

      // AppBar
      appBarTheme: const AppBarTheme(
        backgroundColor: _seed,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
      ),

      // Buttons
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: _ctaBlue,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.symmetric(vertical: 16),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),
      ),

      // Inputs
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: _fieldFill,
        hintStyle: TextStyle(color: scheme.onSurface.withOpacity(0.6)),
        contentPadding: const EdgeInsets.symmetric(
          vertical: 16,
          horizontal: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),

      // Cards (use CardThemeData for widest compatibility)
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),

      // Chips (covers ChoiceChip too on older SDKs)
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceVariant,
        selectedColor: scheme.primaryContainer,
        disabledColor: scheme.surfaceVariant.withOpacity(0.5),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        labelStyle: TextStyle(color: scheme.onSurface),
        secondaryLabelStyle: TextStyle(color: scheme.onPrimaryContainer),
        brightness: Brightness.light,
        shape: const StadiumBorder(),
        side: BorderSide(color: scheme.outlineVariant),
      ),

      // Bottom navigation (Material 3 NavigationBar)
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.white,
        elevation: 0,
        indicatorColor: scheme.primary.withOpacity(0.15),
        iconTheme: MaterialStateProperty.resolveWith(
          (s) => IconThemeData(
            color: s.contains(MaterialState.selected)
                ? scheme.primary
                : scheme.onSurfaceVariant,
          ),
        ),
        labelTextStyle: MaterialStateProperty.resolveWith(
          (s) => TextStyle(
            fontWeight: s.contains(MaterialState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
          ),
        ),
      ),

      // Typography accents
      textTheme: const TextTheme(
        headlineSmall: TextStyle(fontWeight: FontWeight.w800),
        titleMedium: TextStyle(fontWeight: FontWeight.w700),
      ),
    );
  }

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: Brightness.dark,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,

      appBarTheme: AppBarTheme(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        elevation: 0,
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: _ctaBlue,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.symmetric(vertical: 16),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        contentPadding: const EdgeInsets.symmetric(
          vertical: 16,
          horizontal: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),

      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),

      navigationBarTheme: NavigationBarThemeData(
        indicatorColor: scheme.primary.withOpacity(0.25),
        iconTheme: MaterialStateProperty.resolveWith(
          (s) => IconThemeData(
            color: s.contains(MaterialState.selected)
                ? scheme.primary
                : scheme.onSurfaceVariant,
          ),
        ),
      ),

      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerHighest,
        selectedColor: scheme.primaryContainer,
        disabledColor: scheme.surfaceVariant.withOpacity(0.5),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        labelStyle: TextStyle(color: scheme.onSurface),
        secondaryLabelStyle: TextStyle(color: scheme.onPrimaryContainer),
        brightness: Brightness.dark,
        shape: const StadiumBorder(),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    );
  }
}
