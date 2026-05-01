import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import '../theme/stitch_colors.dart';
import '../main.dart' show storageService, hapticService, ttsService;

/// ──────────────────────────────────────────────────────────
/// IrisAI — History Screen (Swipe-to-Delete + Shake-to-Undo)
/// ──────────────────────────────────────────────────────────
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  // ── Undo state ──────────────────────────────────────────
  Map<String, dynamic>? _lastDeletedItem;
  int? _lastDeletedIndex;
  String? _lastDeletedName;
  Timer? _undoTimer;

  // ── Shake detection ─────────────────────────────────────
  StreamSubscription? _accelSub;
  static const double _shakeThreshold = 15.0;
  DateTime _lastShakeTime = DateTime(2000);

  @override
  void initState() {
    super.initState();
    ttsService.speak('Dose history. ${storageService.totalScans} entries.');
    _startShakeListener();
  }

  @override
  void dispose() {
    _accelSub?.cancel();
    _undoTimer?.cancel();
    super.dispose();
  }

  void _startShakeListener() {
    _accelSub = accelerometerEventStream().listen((event) {
      final magnitude = sqrt(
        event.x * event.x + event.y * event.y + event.z * event.z,
      );
      // Subtract gravity (~9.8) and check if remaining force exceeds threshold
      if (magnitude > _shakeThreshold) {
        final now = DateTime.now();
        // Debounce — only trigger once per 2 seconds
        if (now.difference(_lastShakeTime).inMilliseconds > 2000) {
          _lastShakeTime = now;
          _onShakeDetected();
        }
      }
    });
  }

  void _onShakeDetected() {
    if (_lastDeletedItem != null && _lastDeletedIndex != null) {
      _performUndo();
    }
  }

  Future<void> _performUndo() async {
    if (_lastDeletedItem == null || _lastDeletedIndex == null) return;

    final item = _lastDeletedItem!;
    final index = _lastDeletedIndex!;

    // Clear undo state first to prevent double-undo
    _lastDeletedItem = null;
    _lastDeletedIndex = null;
    _lastDeletedName = null;
    _undoTimer?.cancel();

    await storageService.insertDoseLogAt(index, item);

    // Double-haptic pulse for shake-undo confirmation
    await hapticService.confirmTap();
    await Future.delayed(const Duration(milliseconds: 150));
    await hapticService.confirmTap();

    ttsService.speak('Entry restored.');

    if (mounted) {
      ScaffoldMessenger.of(context).clearSnackBars();
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final logs = storageService.getDoseLogs();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dose History'),
        actions: [
          if (logs.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline, color: StitchColors.danger),
              onPressed: _showClearAllDialog,
              tooltip: 'Clear all history',
            ),
        ],
      ),
      body: logs.isEmpty
          ? _buildEmptyState()
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: logs.length,
              itemBuilder: (context, index) => _buildDismissibleCard(logs[index], index),
            ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.history, size: 64, color: StitchColors.textMuted),
          const SizedBox(height: 16),
          Text('No dose history yet', style: TextStyle(color: StitchColors.textMuted, fontSize: 18)),
          const SizedBox(height: 8),
          Text('Scan a medicine to start tracking', style: TextStyle(color: StitchColors.textMuted, fontSize: 14)),
        ],
      ),
    );
  }

  /// Wraps each log card in a Dismissible for swipe-to-delete
  Widget _buildDismissibleCard(Map<String, dynamic> log, int index) {
    final drugName = log['drug_name'] ?? 'Unknown';

    return Dismissible(
      key: ValueKey('${log['timestamp']}_$index'),
      direction: DismissDirection.endToStart,
      background: _buildSwipeBackground(),
      confirmDismiss: (_) async => true,
      onDismissed: (_) => _onEntryDeleted(index, drugName),
      child: _buildLogCard(log, index),
    );
  }

  /// Red swipe background with trash icon
  Widget _buildSwipeBackground() {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [StitchColors.danger.withValues(alpha: 0.2), StitchColors.danger.withValues(alpha: 0.6)],
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.delete_rounded, color: Colors.white, size: 28),
          const SizedBox(height: 4),
          Text('Delete', style: TextStyle(color: Colors.white.withValues(alpha: 0.9), fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  /// Called after swipe completes — store item for undo, delete, show SnackBar
  Future<void> _onEntryDeleted(int index, String drugName) async {
    // Store for undo before deleting
    final logs = storageService.getDoseLogs();
    if (index >= logs.length) return;
    final deletedItem = Map<String, dynamic>.from(logs[index]);

    await storageService.deleteDoseLogAt(index);
    hapticService.confirmTap();

    // Save undo state
    _lastDeletedItem = deletedItem;
    _lastDeletedIndex = index;
    _lastDeletedName = drugName;

    // Auto-expire undo after 5 seconds
    _undoTimer?.cancel();
    _undoTimer = Timer(const Duration(seconds: 5), () {
      _lastDeletedItem = null;
      _lastDeletedIndex = null;
      _lastDeletedName = null;
    });

    // TTS with shake guidance
    ttsService.speak('Deleted $drugName. Shake to undo.');

    if (!mounted) return;
    setState(() {});

    // Show accessible SnackBar with UNDO action
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.delete_rounded, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Deleted $drugName',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
        backgroundColor: StitchColors.surfaceElevated,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 5),
        margin: const EdgeInsets.only(bottom: 80, left: 16, right: 16),
        action: SnackBarAction(
          label: 'UNDO',
          textColor: StitchColors.primary,
          onPressed: _performUndo,
        ),
      ),
    );
  }

  Widget _buildLogCard(Map<String, dynamic> log, int index) {
    final severity = (log['severity'] ?? 'SAFE').toString();
    final sevColor = StitchColors.forSeverity(severity);
    final interactions = log['interactions'] as List? ?? [];

    return Semantics(
      label: '${log['drug_name']}, ${log['dosage']}, severity $severity. Swipe left to delete.',
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: StitchColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: sevColor.withValues(alpha: 0.25)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 10, height: 10,
                  decoration: BoxDecoration(color: sevColor, shape: BoxShape.circle),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(log['drug_name'] ?? 'Unknown',
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: StitchColors.textPrimary)),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: sevColor.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(6)),
                  child: Text(severity, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: sevColor)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                if (log['dosage'] != null && log['dosage'].toString().isNotEmpty)
                  _InfoChip(Icons.medication, log['dosage'].toString()),
                if (log['form'] != null && log['form'].toString().isNotEmpty)
                  _InfoChip(Icons.category, log['form'].toString()),
                _InfoChip(Icons.access_time, _formatTimestamp(log['timestamp'])),
              ],
            ),
            if (interactions.isNotEmpty) ...[
              const SizedBox(height: 10),
              ...interactions.take(2).map((i) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber, size: 14, color: StitchColors.forSeverity(i['severity'] ?? 'CAUTION')),
                    const SizedBox(width: 6),
                    Expanded(child: Text('${i['drug_a']} ↔ ${i['drug_b']}',
                      style: const TextStyle(fontSize: 13, color: StitchColors.textSecondary))),
                  ],
                ),
              )),
            ],
          ],
        ),
      ),
    );
  }

  String _formatTimestamp(String? ts) {
    if (ts == null) return '';
    try {
      final dt = DateTime.parse(ts);
      return '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) { return ts; }
  }

  /// "Confirm Clear All?" dialog with prominent warning
  void _showClearAllDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: StitchColors.surfaceElevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: StitchColors.danger, size: 28),
            const SizedBox(width: 10),
            const Text('Confirm Clear All?', style: TextStyle(color: StitchColors.textPrimary, fontSize: 18)),
          ],
        ),
        content: Text(
          'This will permanently delete all ${storageService.totalScans} dose log entries. This action cannot be undone.',
          style: const TextStyle(color: StitchColors.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(fontSize: 15)),
          ),
          TextButton(
            onPressed: () async {
              await storageService.clearDoseLogs();
              Navigator.pop(ctx);
              setState(() {});
              hapticService.confirmTap();
              ttsService.speak('All history cleared.');
            },
            style: TextButton.styleFrom(
              backgroundColor: StitchColors.danger.withValues(alpha: 0.1),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Clear All', style: TextStyle(color: StitchColors.danger, fontWeight: FontWeight.w700, fontSize: 15)),
          ),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InfoChip(this.icon, this.text);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: StitchColors.background,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: StitchColors.textMuted),
          const SizedBox(width: 4),
          Text(text, style: const TextStyle(fontSize: 12, color: StitchColors.textSecondary)),
        ],
      ),
    );
  }
}
