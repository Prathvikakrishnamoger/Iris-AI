import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'stitch_colors.dart';

/// ──────────────────────────────────────────────────────────────────
/// IrisAI — Stitch Dark Theme
/// ──────────────────────────────────────────────────────────────────
/// Accessibility-first: 56dp+ touch targets, WCAG AAA contrast,
/// screen-reader friendly semantics.
class StitchTheme {
  StitchTheme._();

  static ThemeData get dark {
    final baseText = GoogleFonts.interTextTheme(ThemeData.dark().textTheme);

    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: StitchColors.background,
      colorScheme: const ColorScheme.dark(
        primary: StitchColors.primary,
        secondary: StitchColors.accent,
        surface: StitchColors.surface,
        error: StitchColors.danger,
        onPrimary: StitchColors.background,
        onSecondary: StitchColors.background,
        onSurface: StitchColors.textPrimary,
        onError: Colors.white,
      ),

      // ── Typography ───────────────────────────────────────────────
      textTheme: baseText.copyWith(
        headlineLarge: baseText.headlineLarge?.copyWith(
          color: StitchColors.textPrimary,
          fontSize: 32,
          fontWeight: FontWeight.w700,
        ),
        headlineMedium: baseText.headlineMedium?.copyWith(
          color: StitchColors.textPrimary,
          fontSize: 24,
          fontWeight: FontWeight.w600,
        ),
        titleLarge: baseText.titleLarge?.copyWith(
          color: StitchColors.textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
        titleMedium: baseText.titleMedium?.copyWith(
          color: StitchColors.textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w500,
        ),
        bodyLarge: baseText.bodyLarge?.copyWith(
          color: StitchColors.textPrimary,
          fontSize: 16,
        ),
        bodyMedium: baseText.bodyMedium?.copyWith(
          color: StitchColors.textSecondary,
          fontSize: 14,
        ),
        labelLarge: baseText.labelLarge?.copyWith(
          color: StitchColors.textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),

      // ── App Bar ────────────────────────────────────────────────
      appBarTheme: AppBarTheme(
        backgroundColor: StitchColors.background,
        foregroundColor: StitchColors.textPrimary,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: GoogleFonts.inter(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: StitchColors.primary,
        ),
      ),

      // ── Cards ──────────────────────────────────────────────────
      cardTheme: CardThemeData(
        color: StitchColors.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: StitchColors.border, width: 1),
        ),
        margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 0),
      ),

      // ── Buttons — 56dp minimum touch target ───────────────────
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: StitchColors.primary,
          foregroundColor: StitchColors.background,
          minimumSize: const Size(double.infinity, 56),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w700),
        ),
      ),

      // ── Bottom Navigation ──────────────────────────────────────
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: StitchColors.surface,
        selectedItemColor: StitchColors.primary,
        unselectedItemColor: StitchColors.textMuted,
        type: BottomNavigationBarType.fixed,
        selectedLabelStyle: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        unselectedLabelStyle: TextStyle(fontSize: 12),
      ),

      // ── Dividers ───────────────────────────────────────────────
      dividerTheme: const DividerThemeData(
        color: StitchColors.divider,
        thickness: 1,
      ),

      // ── Icon Theme ─────────────────────────────────────────────
      iconTheme: const IconThemeData(
        color: StitchColors.primary,
        size: 28,
      ),
    );
  }
}
