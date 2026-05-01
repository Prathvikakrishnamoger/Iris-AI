import 'package:flutter/foundation.dart' show kIsWeb, kReleaseMode;

/// ─────────────────────────────────────────────────────────────
/// IrisAI — Network Configuration
/// ─────────────────────────────────────────────────────────────
/// Automatically selects the correct backend URL:
///   - Web (Chrome debug):  http://localhost:8000
///   - Physical device:     http://<laptop-wifi-ip>:8000
///   - Production:          https://iris-ai-backend.onrender.com
///
/// IMPORTANT: Update [_deviceBackendIp] to your laptop's Wi-Fi IP
/// before deploying to a physical device. Find it with:
///   Windows: ipconfig | findstr "IPv4"
///   macOS/Linux: ifconfig | grep "inet "
class AppConfig {
  AppConfig._();

  // ── ENVIRONMENT TOGGLE ──────────────────────────────────
  /// Set to true to use the cloud-hosted backend (e.g. Render)
  /// Set to false to use your local laptop backend
  static const bool useProductionBackend = false;

  /// ── PRODUCTION URL ──────────────────────────────────────
  /// Your deployed backend URL (Render, Railway, Cloud Run, etc.)
  static const String _productionUrl = 'https://iris-ai-xvj5.onrender.com';

  /// ── YOUR LAPTOP'S WI-FI IP ──────────────────────────────
  /// Change this to match your network before device deployment
  static const String _deviceBackendIp = '10.23.46.220';

  /// Backend port (must match uvicorn --port)
  static const int _backendPort = 8000;

  /// Auto-detected backend URL
  static String get backendUrl {
    if (useProductionBackend) {
      return _productionUrl;
    }
    if (kIsWeb) {
      // Web browser on same machine → use localhost
      return 'http://localhost:$_backendPort';
    } else {
      // Physical device on same Wi-Fi → use laptop's IP
      return 'http://$_deviceBackendIp:$_backendPort';
    }
  }

  /// Encryption passphrase for local dose log (matches backend .env)
  static const String encryptionPassphrase = 'IrisAI_Secure_2026_Project_X';

  /// Scan settings
  static const double confidenceThreshold = 0.5;
  static const Duration scanTimeout = Duration(seconds: 15);
  static const Duration healthTimeout = Duration(seconds: 5);
}
