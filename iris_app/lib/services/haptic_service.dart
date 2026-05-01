import 'package:flutter/services.dart';
import 'package:vibration/vibration.dart';

/// ──────────────────────────────────────────────────────
/// IrisAI — Haptic Feedback Service (Device-Native)
/// ──────────────────────────────────────────────────────
/// Direction-based guidance patterns for visually impaired users.
/// Uses the `vibration` package for real device vibration motors.
class HapticService {
  bool _hasVibrator = false;
  bool _hasAmplitudeControl = false;

  Future<void> init() async {
    try {
      _hasVibrator = await Vibration.hasVibrator() ?? false;
      _hasAmplitudeControl = await Vibration.hasAmplitudeControl() ?? false;
    } catch (_) {
      _hasVibrator = false;
      _hasAmplitudeControl = false;
    }
  }

  /// ── Direction-Based Haptic Guidance ──────────────────
  /// Called by the scan screen based on label position analysis.
  Future<void> provideHapticGuidance(String direction) async {
    switch (direction.toLowerCase()) {
      case 'too_far':
        // Rapid short pulses — "move closer"
        if (_hasVibrator) {
          Vibration.vibrate(pattern: [0, 40, 60, 40, 60, 40, 60, 40]);
        } else {
          for (int i = 0; i < 4; i++) {
            HapticFeedback.lightImpact();
            await Future.delayed(const Duration(milliseconds: 60));
          }
        }
        break;

      case 'too_close':
        // One long sustained pulse — "move back"
        if (_hasVibrator) {
          Vibration.vibrate(duration: 600);
        } else {
          HapticFeedback.heavyImpact();
        }
        break;

      case 'centered':
      case 'hold':
      case 'hold_steady':
        // Constant light vibration — "perfect, hold still"
        if (_hasVibrator) {
          if (_hasAmplitudeControl) {
            Vibration.vibrate(duration: 1000, amplitude: 64);
          } else {
            Vibration.vibrate(duration: 1000);
          }
        } else {
          HapticFeedback.mediumImpact();
        }
        break;

      case 'move_left':
        // Two short pulses — "shift left"
        if (_hasVibrator) {
          Vibration.vibrate(pattern: [0, 80, 100, 80]);
        } else {
          HapticFeedback.lightImpact();
          await Future.delayed(const Duration(milliseconds: 100));
          HapticFeedback.lightImpact();
        }
        break;

      case 'move_right':
        // Three short pulses — "shift right"
        if (_hasVibrator) {
          Vibration.vibrate(pattern: [0, 80, 80, 80, 80, 80]);
        } else {
          for (int i = 0; i < 3; i++) {
            HapticFeedback.lightImpact();
            await Future.delayed(const Duration(milliseconds: 80));
          }
        }
        break;

      default:
        HapticFeedback.selectionClick();
        break;
    }
  }

  /// ── Vision Guidance — Low YOLO Confidence Coaching ──────
  /// Continuous light pulse telling the user to slowly reposition
  /// the camera until the object detector locks onto the label.
  /// Pattern: gentle repeating nudges (light-pause-light-pause)
  Future<void> visionGuidance() async {
    if (_hasVibrator) {
      if (_hasAmplitudeControl) {
        // Gentle repeating pulse at low amplitude
        Vibration.vibrate(
          pattern: [0, 100, 150, 100, 150, 100, 150, 100],
          amplitude: 48,
        );
      } else {
        Vibration.vibrate(pattern: [0, 100, 150, 100, 150, 100, 150, 100]);
      }
    } else {
      for (int i = 0; i < 4; i++) {
        HapticFeedback.lightImpact();
        await Future.delayed(const Duration(milliseconds: 150));
      }
    }
  }

  /// App launch — single warm pulse
  Future<void> launchPulse() async {
    if (_hasVibrator) {
      Vibration.vibrate(duration: 200);
    } else {
      HapticFeedback.heavyImpact();
    }
  }

  /// Confirmation — double tap
  Future<void> confirmTap() async {
    HapticFeedback.mediumImpact();
    await Future.delayed(const Duration(milliseconds: 100));
    HapticFeedback.mediumImpact();
  }

  /// Scan complete — distinct TRIPLE-PULSE on successful identification
  Future<void> scanComplete() async {
    if (_hasVibrator) {
      Vibration.vibrate(pattern: [0, 150, 100, 150, 100, 300]);
    } else {
      for (int i = 0; i < 3; i++) {
        HapticFeedback.heavyImpact();
        await Future.delayed(const Duration(milliseconds: 120));
      }
    }
  }

  /// DANGER warning — intense rapid bursts
  Future<void> dangerWarning() async {
    if (_hasVibrator) {
      Vibration.vibrate(pattern: [0, 250, 100, 250, 100, 250, 100, 500]);
    } else {
      for (int i = 0; i < 4; i++) {
        HapticFeedback.heavyImpact();
        await Future.delayed(const Duration(milliseconds: 150));
      }
    }
  }

  /// Scan failed — two long pulses
  Future<void> scanFailed() async {
    if (_hasVibrator) {
      Vibration.vibrate(pattern: [0, 400, 200, 400]);
    } else {
      HapticFeedback.heavyImpact();
      await Future.delayed(const Duration(milliseconds: 300));
      HapticFeedback.heavyImpact();
    }
  }
}
