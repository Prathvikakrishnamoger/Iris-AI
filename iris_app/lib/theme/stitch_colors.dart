import 'package:flutter/material.dart';

/// ─────────────────────────────────────────────────────────────────────
/// IrisAI — Stitch-Inspired Color Palette
/// ─────────────────────────────────────────────────────────────────────
/// High-contrast dark theme optimized for visually impaired users.
/// All foreground/background combos target WCAG AAA (7:1+) ratio.
class StitchColors {
  StitchColors._();

  // ── Core Background ──────────────────────────────────────────────
  static const Color background = Color(0xFF0A0A0F);      // Near-black
  static const Color surface = Color(0xFF14141F);          // Card surface
  static const Color surfaceElevated = Color(0xFF1E1E2E);  // Elevated cards

  // ── Primary: Neon Cyan ───────────────────────────────────────────
  static const Color primary = Color(0xFF00D4FF);          // Main accent
  static const Color primaryDim = Color(0xFF0099BB);       // Dimmed variant
  static const Color primaryGlow = Color(0x3300D4FF);      // Glow effect (20%)

  // ── Accent: Bright Orange ────────────────────────────────────────
  static const Color accent = Color(0xFFFF6B35);           // Secondary accent
  static const Color accentDim = Color(0xFFCC5529);        // Dimmed variant

  // ── Semantic Colors ──────────────────────────────────────────────
  static const Color success = Color(0xFF00E676);          // Safe / confirmed
  static const Color warning = Color(0xFFFFD600);          // Caution
  static const Color danger = Color(0xFFFF1744);           // Danger / critical
  static const Color info = Color(0xFF448AFF);             // Informational

  // ── Text ─────────────────────────────────────────────────────────
  static const Color textPrimary = Color(0xFFF5F5F5);      // Main text
  static const Color textSecondary = Color(0xFFB0B0B0);    // Secondary text
  static const Color textMuted = Color(0xFF707070);        // Muted/disabled

  // ── Borders / Dividers ───────────────────────────────────────────
  static const Color border = Color(0xFF2A2A3A);           // Card borders
  static const Color divider = Color(0xFF1E1E2E);          // Divider lines

  // ── Severity-mapped gradients ────────────────────────────────────
  static const List<Color> safeGradient = [Color(0xFF00E676), Color(0xFF00C853)];
  static const List<Color> cautionGradient = [Color(0xFFFFD600), Color(0xFFFFAB00)];
  static const List<Color> dangerGradient = [Color(0xFFFF1744), Color(0xFFD50000)];

  /// Get color for severity level
  static Color forSeverity(String severity) {
    switch (severity.toUpperCase()) {
      case 'DANGER':
        return danger;
      case 'CAUTION':
        return warning;
      case 'SAFE':
        return success;
      default:
        return textSecondary;
    }
  }
}
