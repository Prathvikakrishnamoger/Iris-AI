import 'dart:async';
import 'dart:collection';
import 'package:flutter_tts/flutter_tts.dart';

/// ──────────────────────────────────────────────────
/// IrisAI — Text-to-Speech Service
/// ──────────────────────────────────────────────────
/// Priority-queued TTS with urgent interrupt for safety alerts.
class TtsService {
  final FlutterTts _tts = FlutterTts();
  final Queue<_TtsMessage> _queue = Queue();
  bool _isSpeaking = false;

  Future<void> init() async {
    await _tts.setLanguage("en-US");
    await _tts.setSpeechRate(0.45); // Slower for clarity
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);

    _tts.setCompletionHandler(() {
      _isSpeaking = false;
      _processQueue();
    });
  }

  /// Speak a message (queued, non-interrupting)
  Future<void> speak(String text) async {
    _queue.add(_TtsMessage(text, false));
    if (!_isSpeaking) _processQueue();
  }

  /// Speak urgently — interrupts current speech
  Future<void> speakUrgent(String text) async {
    await _tts.stop();
    _isSpeaking = false;
    _queue.addFirst(_TtsMessage(text, true));
    _processQueue();
  }

  /// Stop all speech
  Future<void> stop() async {
    _queue.clear();
    await _tts.stop();
    _isSpeaking = false;
  }

  void _processQueue() {
    if (_queue.isEmpty || _isSpeaking) return;
    final msg = _queue.removeFirst();
    _isSpeaking = true;
    _tts.speak(msg.text);
  }

  Future<void> dispose() async {
    await _tts.stop();
  }
}

class _TtsMessage {
  final String text;
  final bool urgent;
  _TtsMessage(this.text, this.urgent);
}
