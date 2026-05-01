import '../services/haptic_service.dart';
import '../services/tts_service.dart';
import '../services/storage_service.dart';
import '../services/api_service.dart';

/// ────────────────────────────────────────────────────────────────
/// IrisAI — Scan Complete Handler
/// ────────────────────────────────────────────────────────────────
/// The SINGLE output orchestrator for a successful scan.
/// Triggers ALL three output channels SIMULTANEOUSLY:
///   1. Audio   → TTS with drug name + dosage + severity
///   2. Haptic  → Pattern mapped to severity (DANGER/CAUTION/SAFE)
///   3. Log     → Encrypted Hive + backend sync
///
/// Chain: haptic + TTS (parallel) → Hive log → POST /api/log → callback
class ScanCompleteHandler {
  final HapticService haptic;
  final TtsService tts;
  final StorageService storage;
  final ApiService api;

  /// Called after log is saved — used by UI to show toast/banner
  /// Parameters: severity, drugName, smsNotified
  void Function(String severity, String drugName, bool smsNotified)? onOutputComplete;

  ScanCompleteHandler({
    required this.haptic,
    required this.tts,
    required this.storage,
    required this.api,
  });

  Future<void> handleResult(Map<String, dynamic> result) async {
    final drugInfo = result['drug_info'] as Map<String, dynamic>? ?? {};
    final interactions = result['interactions'] as Map<String, dynamic>? ?? {};
    final severity = (interactions['severity'] ?? 'SAFE').toString();
    final drugName = drugInfo['drug_name'] ?? 'Unknown medicine';
    final dosage = drugInfo['dosage'] ?? '';
    final genericName = drugInfo['generic_name'] ?? '';

    // Check if backend sent an SMS alert for this DANGER result
    final smsAlert = result['sms_alert'] as Map<String, dynamic>? ?? {};
    final smsNotified = smsAlert['sent'] == true;

    // ── 1. HAPTIC — Severity-mapped patterns (fire immediately) ────
    final hapticFuture = _triggerHaptic(severity);

    // ── 2. TTS — Full announcement with severity ───────────────────
    final ttsFuture = _announceResult(
      drugName: drugName,
      dosage: dosage,
      genericName: genericName,
      severity: severity,
      interactions: interactions,
    );

    // Fire haptic + TTS in parallel for instant feedback
    await Future.wait([hapticFuture, ttsFuture]);

    // ── 3. LOG — Encrypted Hive + backend sync ─────────────────────
    final logEntry = {
      'drug_name': drugName,
      'dosage': dosage,
      'form': drugInfo['form'] ?? '',
      'generic_name': genericName,
      'severity': severity,
      'timestamp': DateTime.now().toIso8601String(),
      'interactions': interactions['interactions'] ?? [],
    };
    await storage.addDoseLog(logEntry);

    // Fire-and-forget POST to backend
    try {
      await api.logDose(logEntry);
    } catch (_) {
      // Offline — already saved locally in Hive
    }

    // Notify UI that all output channels are complete
    onOutputComplete?.call(severity, drugName, smsNotified);
  }

  /// Severity-mapped haptic patterns:
  ///   DANGER  → Intense rapid bursts (4x heavy pulse)
  ///   CAUTION → Double-pulse warning
  ///   SAFE    → Single short confirmation pulse
  Future<void> _triggerHaptic(String severity) async {
    switch (severity.toUpperCase()) {
      case 'DANGER':
        await haptic.dangerWarning(); // 4x heavy burst pattern
        break;
      case 'CAUTION':
        await haptic.confirmTap(); // Double-tap warning
        break;
      case 'SAFE':
      default:
        await haptic.scanComplete(); // Single confirmation
        break;
    }
  }

  /// Build and speak the full TTS announcement:
  ///   "Dolo-650 detected, 650 milligram. Paracetamol.
  ///    [WARNING! Dangerous interaction / Caution / No interactions]"
  Future<void> _announceResult({
    required String drugName,
    required String dosage,
    required String genericName,
    required String severity,
    required Map<String, dynamic> interactions,
  }) async {
    // Drug name + dosage
    String announcement = '$drugName detected';
    if (dosage.isNotEmpty) {
      final dosageSpoken = dosage
          .replaceAll('mg', ' milligram')
          .replaceAll('ml', ' milliliter')
          .replaceAll('mcg', ' microgram');
      announcement += ', $dosageSpoken';
    }
    if (genericName.isNotEmpty && genericName.toLowerCase() != drugName.toLowerCase()) {
      announcement += '. Generic name: $genericName';
    }
    announcement += '.';

    // Severity-specific suffix
    if (severity == 'DANGER') {
      final interactionList = interactions['interactions'] as List? ?? [];
      final conflicts = interactionList
          .map((i) => '${i['drug_a']} and ${i['drug_b']}')
          .join(', ');
      await tts.speakUrgent(
        '$announcement WARNING! Dangerous interaction detected. '
        '$drugName conflicts with $conflicts. '
        'Contact your healthcare provider immediately.',
      );
    } else if (severity == 'CAUTION') {
      await tts.speak(
        '$announcement Caution: mild interaction detected. Consult your doctor.',
      );
    } else {
      await tts.speak(
        '$announcement No dangerous interactions found. Safe to take.',
      );
    }
  }
}
