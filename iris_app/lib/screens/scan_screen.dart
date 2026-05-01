import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:camera/camera.dart';
import '../theme/stitch_colors.dart';
import '../main.dart' show hapticService, ttsService, apiService, scanCompleteHandler, storageService;

/// ──────────────────────────────────────────────────────────
/// IrisAI — Scan Screen (NO HARDCODED DATA)
/// ──────────────────────────────────────────────────────────
/// All results come from the real backend pipeline:
///   Camera → OpenCV Stitch → YOLOv11 → TrOCR → Gemini → Interactions
///
/// If confidence < 0.5 → "Unknown Medicine - Please Rescan"
/// If backend unreachable → TTS: "Scanning failed..."
/// If blank frame → Haptic guidance: hold_steady
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> with TickerProviderStateMixin, WidgetsBindingObserver {
  bool _isScanning = false;
  bool _hasResult = false;
  bool _hasError = false;
  Map<String, dynamic>? _scanResult;
  String _statusText = 'Position medicine label in frame';
  String _errorText = '';
  late AnimationController _scanLineController;
  late AnimationController _pulseController;

  // Warning banner state
  String? _warningSeverity;
  String? _warningDrugName;
  bool _smsNotified = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scanLineController = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat();
    _pulseController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))..repeat(reverse: true);
    ttsService.speak('Scan screen ready. Tap the scan button and hold camera over a medicine label.');

    // Wire up the scan complete handler's callback for toast/banner
    scanCompleteHandler.onOutputComplete = _onScanOutputComplete;

    // Init camera immediately on device so preview shows
    if (!kIsWeb) _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scanLineController.dispose();
    _pulseController.dispose();
    _disposeCamera();
    super.dispose();
  }

  /// Handle app lifecycle — dispose camera when backgrounded to prevent
  /// FlutterJNI crash on Android 16 (CameraX ImageReader callback race)
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      _disposeCamera();
    } else if (state == AppLifecycleState.resumed) {
      if (!kIsWeb && !_cameraReady) _initCamera();
    }
  }

  void _disposeCamera() {
    final controller = _cameraController;
    _cameraController = null;
    _cameraReady = false;
    controller?.dispose();
  }

  /// ── THE REAL SCAN PIPELINE ──────────────────────────────
  /// Captures frame → sends to /api/scan → waits for real AI result.
  /// NO mock data. NO hardcoded drug names.
  Future<void> _startScan() async {
    setState(() {
      _isScanning = true;
      _hasResult = false;
      _hasError = false;
      _errorText = '';
      _statusText = 'Scanning... Hold steady.';
    });

    // Haptic: hold steady guidance
    await hapticService.provideHapticGuidance('hold_steady');
    await ttsService.speak('Scanning medicine label. Please hold steady.');

    try {

      // 2. Capture camera frame
      final frameBytes = await _captureFrame();
      if (frameBytes == null || frameBytes.isEmpty) {
        await _handleScanError(
          'Camera capture failed. Please ensure camera permissions are granted.',
        );
        return;
      }

      // 3. Send to real backend pipeline — NO FAKE DATA
      final result = await apiService.scanMedicine(frameBytes);

      // 4. Handle backend response — use YOLO bounding box guidance
      final guidance = result['guidance'] ?? 'hold_steady';

      if (result['status'] == 'error') {
        await _handleScanError(
          result['message'] ?? 'Scanning failed, please check your internet and try again.',
        );
        return;
      }

      if (result['status'] == 'guidance') {
        // Backend says: blank frame — use YOLO directional guidance
        await hapticService.provideHapticGuidance(guidance);
        setState(() {
          _isScanning = false;
          _statusText = result['message'] ?? 'Hold steady over the medicine label.';
        });
        await ttsService.speak(result['message'] ?? 'Please hold camera steady over the label.');
        return;
      }

      if (result['status'] == 'blurry') {
        // Blurry scan — directional haptic + TTS error
        await hapticService.provideHapticGuidance(guidance);
        setState(() {
          _isScanning = false;
          _statusText = 'Blurry scan. Adjust lighting and try again.';
        });
        await ttsService.speak('Blurry scan detected. Please adjust lighting and hold steady.');
        return;
      }

      if (result['status'] == 'no_medicine') {
        // Use directional haptic from YOLO tracking
        await hapticService.provideHapticGuidance(guidance);
        setState(() {
          _isScanning = false;
          _statusText = 'No medicine detected. Reposition and try again.';
        });
        await ttsService.speak('No medicine detected. Please reposition the label and try again.');
        return;
      }

      // 4b. Vision Guidance — YOLO low-confidence coaching for visually impaired
      // If YOLO detected something but confidence < 0.3, the label isn't well-aligned.
      // Trigger gentle repeating haptics to guide the user to reposition.
      final detections = result['detections'] as List? ?? [];
      if (detections.isNotEmpty) {
        final yoloConf = (detections[0]['confidence'] ?? 1.0);
        final yoloConfVal = yoloConf is num ? yoloConf.toDouble() : 1.0;
        if (yoloConfVal < 0.3) {
          await hapticService.visionGuidance();
          setState(() {
            _statusText = 'Move camera slightly to focus on the label...';
          });
          await ttsService.speak('Label partially visible. Move the camera slightly to center it.');
          // Don't return — let the pipeline continue if Gemini still identified it
        }
      }

      // 5. Check confidence — reject low confidence guesses
      final drugInfo = result['drug_info'] as Map<String, dynamic>? ?? {};
      final confidence = (drugInfo['confidence'] ?? 0.0);
      final confidenceVal = confidence is num ? confidence.toDouble() : 0.0;

      if (drugInfo['drug_name'] == null || confidenceVal < 0.5) {
        setState(() {
          _isScanning = false;
          _hasResult = true;
          _scanResult = {
            'status': 'low_confidence',
            'drug_info': {
              'drug_name': 'Unknown Medicine - Please Rescan',
              'confidence': confidenceVal,
            },
            'interactions': {},
          };
          _statusText = 'Low confidence. Please rescan.';
        });
        await hapticService.scanFailed();
        await ttsService.speak(
          'Unable to identify medicine with sufficient confidence. '
          'Score was ${(confidenceVal * 100).toInt()} percent. Please rescan.',
        );
        return;
      }

      // 6. SUCCESS — Real identification from backend
      setState(() {
        _isScanning = false;
        _hasResult = true;
        _scanResult = result;
        _statusText = 'Scan complete!';
        _warningSeverity = null; // Reset banner, handler will set it
        _warningDrugName = null;
      });

      // Delegate ALL output (haptic + TTS + log) to ScanCompleteHandler
      // It fires haptic + TTS in parallel, then logs to Hive + backend
      // The onOutputComplete callback triggers the toast/banner in the UI
      await scanCompleteHandler.handleResult(result);

    } catch (e) {
      await _handleScanError(
        'Scanning failed, please check your internet and try again.',
      );
    }
  }

  /// Called by ScanCompleteHandler after all output channels fire.
  /// Triggers the visual warning banner + "Log Updated" toast.
  void _onScanOutputComplete(String severity, String drugName, bool smsNotified) {
    if (!mounted) return;

    // Show warning banner for DANGER and CAUTION
    if (severity == 'DANGER' || severity == 'CAUTION') {
      setState(() {
        _warningSeverity = severity;
        _warningDrugName = drugName;
        _smsNotified = smsNotified;
      });

      // Auto-dismiss banner after 8 seconds
      Future.delayed(const Duration(seconds: 8), () {
        if (mounted) setState(() => _warningSeverity = null);
      });
    }

    // Show "Log Updated" toast
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.check_circle_outline, color: StitchColors.success, size: 20),
              const SizedBox(width: 8),
              Text(
                '$drugName logged to history',
                style: const TextStyle(color: StitchColors.textPrimary, fontWeight: FontWeight.w500),
              ),
            ],
          ),
          backgroundColor: StitchColors.surfaceElevated,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          duration: const Duration(seconds: 3),
          margin: const EdgeInsets.only(bottom: 80, left: 16, right: 16),
        ),
      );
    }
  }

  /// ── ERROR HANDLER — TTS + Haptic alert ──────────────────
  Future<void> _handleScanError(String message) async {
    setState(() {
      _isScanning = false;
      _hasError = true;
      _errorText = message;
      _statusText = 'Scan failed';
    });
    await hapticService.scanFailed();
    // TTS error alert — required by spec
    await ttsService.speakUrgent(message);
  }

  /// ── CAMERA CAPTURE ──────────────────────────────────────
  /// On device: captures high-res frame from real camera
  /// On web: sends solid gray test frame (blank detection)
  Future<List<Uint8List>?> _captureFrame() async {
    if (kIsWeb) {
      // Web mode: solid gray frame → backend detects blank → "hold_steady"
      return [_createTestFrame()];
    }

    // ── REAL CAMERA CAPTURE (Android/iOS) ──────────────────
    try {
      if (_cameraController == null || !_cameraController!.value.isInitialized) {
        await _initCamera();
      }
      if (_cameraController == null) return null;

      final image = await _cameraController!.takePicture();
      final bytes = await File(image.path).readAsBytes();
      return [bytes];
    } catch (e) {
      debugPrint('Camera capture failed: $e');
      return null;
    }
  }

  /// ── CAMERA INITIALIZATION ──────────────────────────────
  CameraController? _cameraController;
  bool _cameraReady = false;

  Future<void> _initCamera() async {
    if (kIsWeb) return; // No camera init needed on web

    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        await ttsService.speak('No camera found on this device.');
        return;
      }

      // Prefer back camera for medicine scanning
      final backCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        backCamera,
        ResolutionPreset.high, // High-res for OCR accuracy
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await _cameraController!.initialize();
      if (mounted) {
        setState(() => _cameraReady = true);
      }
    } catch (e) {
      debugPrint('Camera init failed: $e');
      await ttsService.speak('Camera initialization failed. Please check permissions.');
    }
  }

  /// Creates a minimal BMP image for web pipeline testing.
  /// On web: sends a SOLID GRAY frame → backend detects blank → returns "hold_steady"
  Uint8List _createTestFrame() {
    final width = 320;
    final height = 240;
    final pixels = Uint8List(width * height * 3);
    for (int i = 0; i < pixels.length; i += 3) {
      pixels[i] = 128;
      pixels[i + 1] = 128;
      pixels[i + 2] = 128;
    }

    final bmpHeaderSize = 54;
    final dataSize = width * height * 3;
    final fileSize = bmpHeaderSize + dataSize;
    final bmp = Uint8List(fileSize);

    bmp[0] = 0x42; bmp[1] = 0x4D;
    bmp[2] = fileSize & 0xFF; bmp[3] = (fileSize >> 8) & 0xFF;
    bmp[4] = (fileSize >> 16) & 0xFF; bmp[5] = (fileSize >> 24) & 0xFF;
    bmp[10] = bmpHeaderSize;

    bmp[14] = 40;
    bmp[18] = width & 0xFF; bmp[19] = (width >> 8) & 0xFF;
    bmp[22] = height & 0xFF; bmp[23] = (height >> 8) & 0xFF;
    bmp[26] = 1;
    bmp[28] = 24;
    bmp[34] = dataSize & 0xFF; bmp[35] = (dataSize >> 8) & 0xFF;

    for (int i = 0; i < dataSize && i < pixels.length; i++) {
      bmp[bmpHeaderSize + i] = pixels[i];
    }

    return bmp;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan Medicine')),
      body: Column(
        children: [
          // ── Camera Preview Area ──────────────────
          Expanded(
            flex: 3,
            child: Container(
              margin: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: StitchColors.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: _hasError
                      ? StitchColors.danger.withValues(alpha: 0.5)
                      : StitchColors.primary.withValues(alpha: 0.3),
                  width: 2,
                ),
              ),
              child: Stack(
                children: [
                  // ── Live Camera Preview or Placeholder ──
                  if (!kIsWeb && _cameraReady && _cameraController != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: SizedBox.expand(
                        child: FittedBox(
                          fit: BoxFit.cover,
                          child: SizedBox(
                            width: _cameraController!.value.previewSize?.height ?? 1,
                            height: _cameraController!.value.previewSize?.width ?? 1,
                            child: CameraPreview(_cameraController!),
                          ),
                        ),
                      ),
                    )
                  else
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AnimatedBuilder(
                            animation: _pulseController,
                            builder: (context, child) {
                              return Opacity(opacity: 0.5 + _pulseController.value * 0.5, child: child);
                            },
                            child: Icon(
                              _hasError
                                  ? Icons.error_outline
                                  : (_isScanning ? Icons.document_scanner : Icons.camera_alt_outlined),
                              size: 64,
                              color: _hasError ? StitchColors.danger : StitchColors.primary,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            !kIsWeb && !_cameraReady && !_hasError
                                ? 'Initializing camera...'
                                : _statusText,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: _hasError ? StitchColors.danger : StitchColors.textSecondary,
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),
                    ),
                  // ── Status overlay on camera ──
                  if (_cameraReady && (_hasError || _hasResult || _isScanning))
                    Positioned(
                      bottom: 12, left: 12, right: 12,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.7),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          _statusText,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: _hasError ? StitchColors.danger : Colors.white,
                            fontSize: 14, fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  if (_hasError && _errorText.isNotEmpty)
                    Positioned(
                      bottom: 50, left: 12, right: 12,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _errorText,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: StitchColors.textMuted, fontSize: 12),
                        ),
                      ),
                    ),
                  ..._buildCornerGuides(),
                  if (_isScanning)
                    AnimatedBuilder(
                      animation: _scanLineController,
                      builder: (context, _) {
                        return Positioned(
                          top: _scanLineController.value * (MediaQuery.of(context).size.height * 0.4),
                          left: 20, right: 20,
                          child: Container(
                            height: 2,
                            decoration: const BoxDecoration(
                              gradient: LinearGradient(
                                colors: [Colors.transparent, StitchColors.primary, Colors.transparent],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
          ),

          // ── Warning Banner (DANGER / CAUTION) ────────
          if (_warningSeverity != null) _buildWarningBanner(),

          // ── Result Card ──────────────────────────
          if (_hasResult && _scanResult != null) _buildResultCard(),

          // ── Scan Button ──────────────────────────
          Padding(
            padding: const EdgeInsets.all(20),
            child: Semantics(
              button: true,
              label: _isScanning ? 'Scanning in progress' : 'Start scan',
              child: ElevatedButton.icon(
                onPressed: _isScanning ? null : _startScan,
                icon: Icon(_isScanning ? Icons.hourglass_top : Icons.document_scanner_rounded),
                label: Text(_isScanning ? 'Scanning...' : 'Start Scan'),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 64),
                  backgroundColor: _isScanning ? StitchColors.primaryDim : StitchColors.primary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Prominent animated warning banner for DANGER / CAUTION results
  Widget _buildWarningBanner() {
    final isDanger = _warningSeverity == 'DANGER';
    final bannerColor = isDanger ? StitchColors.danger : StitchColors.warning;
    final gradient = isDanger ? StitchColors.dangerGradient : StitchColors.cautionGradient;
    final icon = isDanger ? Icons.dangerous_rounded : Icons.warning_amber_rounded;
    final title = isDanger ? '⚠ DANGER!' : '⚠ CAUTION';
    final subtitle = isDanger
        ? 'Dangerous interaction detected with ${_warningDrugName ?? "medicine"}!'
        : 'Mild interaction found. Consult your doctor.';

    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, child) {
        final opacity = isDanger ? (0.85 + _pulseController.value * 0.15) : 1.0;
        return Opacity(opacity: opacity, child: child);
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [gradient[0].withValues(alpha: 0.9), gradient[1].withValues(alpha: 0.9)],
          ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: bannerColor.withValues(alpha: 0.4),
              blurRadius: 16,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Row(
          children: [
            Icon(icon, color: Colors.white, size: 36),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.9),
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  // Show "Emergency Contact Notified" for DANGER with SMS sent
                  if (isDanger && _smsNotified) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(Icons.phone_forwarded_rounded, color: Colors.white.withValues(alpha: 0.85), size: 16),
                        const SizedBox(width: 6),
                        Text(
                          'Emergency Contact Notified',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.85),
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            // Dismiss button
            GestureDetector(
              onTap: () => setState(() => _warningSeverity = null),
              child: Icon(Icons.close, color: Colors.white.withValues(alpha: 0.7), size: 22),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultCard() {
    final drugInfo = _scanResult!['drug_info'] is Map ? Map<String, dynamic>.from(_scanResult!['drug_info'] as Map) : <String, dynamic>{};
    final interactions = _scanResult!['interactions'] is Map ? Map<String, dynamic>.from(_scanResult!['interactions'] as Map) : <String, dynamic>{};
    final severity = (interactions['severity'] ?? 'SAFE').toString();
    final isLowConfidence = _scanResult!['status'] == 'low_confidence';
    final sevColor = isLowConfidence ? StitchColors.warning : StitchColors.forSeverity(severity);
    final interactionList = interactions['interactions'] as List? ?? [];
    final drugName = drugInfo['drug_name'] ?? 'Unknown';
    final confidence = drugInfo['confidence'];

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: StitchColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: sevColor.withValues(alpha: 0.5), width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: sevColor.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  isLowConfidence ? 'RESCAN' : severity,
                  style: TextStyle(color: sevColor, fontWeight: FontWeight.w700, fontSize: 14),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  drugName,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: StitchColors.textPrimary),
                ),
              ),
            ],
          ),
          if (confidence != null) ...[
            const SizedBox(height: 6),
            Text(
              'Confidence: ${(confidence is num ? (confidence * 100).toInt() : 0)}%',
              style: TextStyle(color: sevColor, fontSize: 13),
            ),
          ],
          if (drugInfo['generic_name'] != null) ...[
            const SizedBox(height: 4),
            Text('Generic: ${drugInfo['generic_name']}', style: const TextStyle(color: StitchColors.primary, fontSize: 14)),
          ],
          if (drugInfo['dosage'] != null) ...[
            const SizedBox(height: 4),
            Text('Dosage: ${drugInfo['dosage']}', style: const TextStyle(color: StitchColors.textSecondary, fontSize: 15)),
          ],
          if (drugInfo['form'] != null) ...[
            const SizedBox(height: 4),
            Text('Form: ${drugInfo['form']}', style: const TextStyle(color: StitchColors.textSecondary, fontSize: 14)),
          ],
          if (interactionList.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Divider(color: StitchColors.border),
            const SizedBox(height: 8),
            ...interactionList.take(3).map((i) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, size: 18, color: StitchColors.forSeverity(i['severity'] ?? 'CAUTION')),
                  const SizedBox(width: 8),
                  Expanded(child: Text('${i['drug_a']} + ${i['drug_b']}', style: const TextStyle(fontSize: 14, color: StitchColors.textPrimary))),
                ],
              ),
            )),
          ],
        ],
      ),
    );
  }

  List<Widget> _buildCornerGuides() {
    const size = 24.0;
    const thickness = 3.0;
    final color = _hasError ? StitchColors.danger : StitchColors.primary;
    const offset = 12.0;
    return [
      Positioned(top: offset, left: offset, child: _Corner(size: size, thickness: thickness, color: color, topLeft: true)),
      Positioned(top: offset, right: offset, child: _Corner(size: size, thickness: thickness, color: color, topRight: true)),
      Positioned(bottom: offset, left: offset, child: _Corner(size: size, thickness: thickness, color: color, bottomLeft: true)),
      Positioned(bottom: offset, right: offset, child: _Corner(size: size, thickness: thickness, color: color, bottomRight: true)),
    ];
  }
}

class _Corner extends StatelessWidget {
  final double size, thickness;
  final Color color;
  final bool topLeft, topRight, bottomLeft, bottomRight;

  const _Corner({required this.size, required this.thickness, required this.color,
    this.topLeft = false, this.topRight = false, this.bottomLeft = false, this.bottomRight = false});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size, height: size,
      child: CustomPaint(painter: _CornerPainter(thickness: thickness, color: color,
        topLeft: topLeft, topRight: topRight, bottomLeft: bottomLeft, bottomRight: bottomRight)),
    );
  }
}

class _CornerPainter extends CustomPainter {
  final double thickness;
  final Color color;
  final bool topLeft, topRight, bottomLeft, bottomRight;

  _CornerPainter({required this.thickness, required this.color,
    this.topLeft = false, this.topRight = false, this.bottomLeft = false, this.bottomRight = false});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color..strokeWidth = thickness..style = PaintingStyle.stroke..strokeCap = StrokeCap.round;
    if (topLeft) {
      canvas.drawLine(Offset(0, size.height * 0.5), const Offset(0, 0), paint);
      canvas.drawLine(const Offset(0, 0), Offset(size.width * 0.5, 0), paint);
    } else if (topRight) {
      canvas.drawLine(Offset(size.width * 0.5, 0), Offset(size.width, 0), paint);
      canvas.drawLine(Offset(size.width, 0), Offset(size.width, size.height * 0.5), paint);
    } else if (bottomLeft) {
      canvas.drawLine(Offset(0, size.height * 0.5), Offset(0, size.height), paint);
      canvas.drawLine(Offset(0, size.height), Offset(size.width * 0.5, size.height), paint);
    } else if (bottomRight) {
      canvas.drawLine(Offset(size.width * 0.5, size.height), Offset(size.width, size.height), paint);
      canvas.drawLine(Offset(size.width, size.height), Offset(size.width, size.height * 0.5), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
