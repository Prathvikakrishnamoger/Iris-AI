import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import '../config/app_config.dart';

/// ─────────────────────────────────────────────────────────────
/// IrisAI — API Service (No Hardcoded Data)
/// ─────────────────────────────────────────────────────────────
/// All results come from the real backend pipeline.
/// URL auto-detects: localhost (web) vs Wi-Fi IP (device).
class ApiService {
  ApiService({String? baseUrl}) : baseUrl = baseUrl ?? AppConfig.backendUrl;

  final String baseUrl;
  final http.Client _client = http.Client();

  /// Health check
  Future<Map<String, dynamic>> healthCheck() async {
    try {
      final resp = await _client
          .get(Uri.parse('$baseUrl/health'))
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) return jsonDecode(resp.body);
      return {'status': 'error', 'code': resp.statusCode};
    } catch (e) {
      return {'status': 'offline', 'error': e.toString()};
    }
  }

  /// Scan medicine — sends camera frame(s) to /api/scan
  /// Returns the full pipeline result from backend.
  Future<Map<String, dynamic>> scanMedicine(List<Uint8List> frameBytes) async {
    try {
      final uri = Uri.parse('$baseUrl/api/scan');
      final request = http.MultipartRequest('POST', uri);

      for (int i = 0; i < frameBytes.length; i++) {
        request.files.add(http.MultipartFile.fromBytes(
          'files',
          frameBytes[i],
          filename: 'frame_$i.jpg',
          contentType: MediaType('image', 'jpeg'),
        ));
      }

      final streamed = await request.send().timeout(const Duration(seconds: 45));
      final resp = await http.Response.fromStream(streamed);

      if (resp.statusCode == 200) {
        return jsonDecode(resp.body);
      } else if (resp.statusCode == 400) {
        // Blank frame or hold_steady guidance
        final body = jsonDecode(resp.body);
        final detail = body['detail'] ?? body;
        return {
          'status': 'guidance',
          'error': detail['error'] ?? 'BLANK_FRAMES',
          'guidance': detail['guidance'] ?? 'hold_steady',
          'message': detail['message'] ?? 'Hold steady over the medicine label.',
        };
      } else {
        return {
          'status': 'error',
          'error': 'BACKEND_ERROR',
          'message': 'Backend returned status ${resp.statusCode}',
        };
      }
    } catch (e) {
      return {
        'status': 'error',
        'error': 'CONNECTION_FAILED',
        'message': 'Cannot reach backend: ${e.toString().split(':').first}',
      };
    }
  }

  /// Check drug interactions (no hardcoded drug names)
  Future<Map<String, dynamic>> checkDrug(String drugName) async {
    try {
      final resp = await _client
          .post(
            Uri.parse('$baseUrl/api/check'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'drug_name': drugName}),
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) return jsonDecode(resp.body);
      return {'error': 'STATUS_${resp.statusCode}'};
    } catch (e) {
      return {'error': 'CONNECTION_FAILED', 'message': e.toString()};
    }
  }

  /// Log a dose
  Future<Map<String, dynamic>> logDose(Map<String, dynamic> entry) async {
    try {
      final resp = await _client
          .post(
            Uri.parse('$baseUrl/api/log'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(entry),
          )
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) return jsonDecode(resp.body);
      return {'error': 'STATUS_${resp.statusCode}'};
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  /// Get dose history
  Future<Map<String, dynamic>> getHistory() async {
    try {
      final resp = await _client
          .get(Uri.parse('$baseUrl/api/history'))
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) return jsonDecode(resp.body);
      return {'error': 'STATUS_${resp.statusCode}'};
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  void dispose() {
    _client.close();
  }
}
