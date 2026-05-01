import 'dart:convert';
import 'dart:typed_data';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// ─────────────────────────────────────────────────────────────────
/// IrisAI — Hive AES-256 Encrypted Storage Service
/// ─────────────────────────────────────────────────────────────────
/// Boxes: med_history, dose_logs, scan_cache, settings
/// Key is generated once and stored in platform Keystore/Keychain.
class StorageService {
  static const _keyAlias = 'iris_ai_hive_key';
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  late Box _medHistoryBox;
  late Box _doseLogBox;
  late Box _scanCacheBox;
  late Box _settingsBox;

  Future<void> init() async {
    await Hive.initFlutter();

    // Get or generate encryption key
    final encKey = await _getOrCreateKey();
    final cipher = HiveAesCipher(encKey);

    // Open encrypted boxes
    _medHistoryBox = await Hive.openBox('med_history', encryptionCipher: cipher);
    _doseLogBox = await Hive.openBox('dose_logs', encryptionCipher: cipher);
    _scanCacheBox = await Hive.openBox('scan_cache', encryptionCipher: cipher);
    _settingsBox = await Hive.openBox('settings', encryptionCipher: cipher);
  }

  Future<Uint8List> _getOrCreateKey() async {
    final stored = await _secureStorage.read(key: _keyAlias);
    if (stored != null) {
      return base64Url.decode(stored);
    }
    final key = Hive.generateSecureKey();
    await _secureStorage.write(key: _keyAlias, value: base64UrlEncode(key));
    return Uint8List.fromList(key);
  }

  // ── Medication History ──────────────────────────────────────────
  List<Map<String, dynamic>> getMedHistory() {
    final raw = _medHistoryBox.get('medications', defaultValue: []);
    if (raw is List) {
      return raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
    return [];
  }

  Future<void> saveMedHistory(List<Map<String, dynamic>> meds) async {
    await _medHistoryBox.put('medications', meds);
  }

  // ── Dose Logs ──────────────────────────────────────────────────
  List<Map<String, dynamic>> getDoseLogs() {
    final raw = _doseLogBox.get('logs', defaultValue: []);
    if (raw is List) {
      return raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
    return [];
  }

  Future<void> addDoseLog(Map<String, dynamic> entry) async {
    final logs = getDoseLogs();
    logs.insert(0, entry); // newest first
    // Keep last 500 entries
    if (logs.length > 500) logs.removeRange(500, logs.length);
    await _doseLogBox.put('logs', logs);
  }

  Future<void> clearDoseLogs() async {
    await _doseLogBox.put('logs', []);
  }

  Future<void> deleteDoseLogAt(int index) async {
    final logs = getDoseLogs();
    if (index >= 0 && index < logs.length) {
      logs.removeAt(index);
      await _doseLogBox.put('logs', logs);
    }
  }

  Future<void> insertDoseLogAt(int index, Map<String, dynamic> entry) async {
    final logs = getDoseLogs();
    final clampedIndex = index.clamp(0, logs.length);
    logs.insert(clampedIndex, entry);
    await _doseLogBox.put('logs', logs);
  }

  // ── Scan Cache ─────────────────────────────────────────────────
  Future<void> cacheScanResult(String key, Map<String, dynamic> result) async {
    await _scanCacheBox.put(key, result);
  }

  Map<String, dynamic>? getCachedScan(String key) {
    final raw = _scanCacheBox.get(key);
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return null;
  }

  // ── Settings ───────────────────────────────────────────────────
  Future<void> setSetting(String key, dynamic value) async {
    await _settingsBox.put(key, value);
  }

  dynamic getSetting(String key, {dynamic defaultValue}) {
    return _settingsBox.get(key, defaultValue: defaultValue);
  }

  // ── Stats ──────────────────────────────────────────────────────
  int get totalScans => getDoseLogs().length;

  int get dangerCount => getDoseLogs()
      .where((l) => (l['severity'] ?? '').toString().toUpperCase() == 'DANGER')
      .length;

  Future<void> dispose() async {
    await Hive.close();
  }
}
