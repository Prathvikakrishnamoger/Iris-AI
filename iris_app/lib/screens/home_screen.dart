import 'package:flutter/material.dart';
import '../theme/stitch_colors.dart';
import '../main.dart' show hapticService, storageService;

/// ──────────────────────────────────────────────────────────
/// IrisAI — Home Screen (Dashboard)
/// ──────────────────────────────────────────────────────────
class HomeScreen extends StatefulWidget {
  final VoidCallback onScanTap;
  const HomeScreen({super.key, required this.onScanTap});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header ──────────────────────────
              Semantics(
                label: 'IrisAI Dashboard',
                child: Row(
                  children: [
                    Container(
                      width: 48, height: 48,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(colors: [StitchColors.primary, StitchColors.accent]),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Icon(Icons.visibility, color: Colors.white, size: 28),
                    ),
                    const SizedBox(width: 14),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('IrisAI', style: Theme.of(context).textTheme.headlineMedium?.copyWith(color: StitchColors.primary)),
                        Text('Medicine Assistant', style: Theme.of(context).textTheme.bodyMedium),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 28),

              // ── Scan CTA ──────────────────────────
              Semantics(
                button: true,
                label: 'Scan Medicine. Double tap to open camera.',
                child: AnimatedBuilder(
                  animation: _pulseController,
                  builder: (context, child) {
                    final scale = 1.0 + (_pulseController.value * 0.03);
                    return Transform.scale(
                      scale: scale,
                      child: child,
                    );
                  },
                  child: GestureDetector(
                    onTap: () {
                      hapticService.confirmTap();
                      widget.onScanTap();
                    },
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 32),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [StitchColors.primary.withValues(alpha: 0.15), StitchColors.accent.withValues(alpha: 0.1)],
                        ),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: StitchColors.primary.withValues(alpha: 0.4), width: 2),
                      ),
                      child: Column(
                        children: [
                          Container(
                            width: 80, height: 80,
                            decoration: BoxDecoration(
                              color: StitchColors.primary.withValues(alpha: 0.2),
                              shape: BoxShape.circle,
                              border: Border.all(color: StitchColors.primary, width: 2),
                            ),
                            child: const Icon(Icons.document_scanner_rounded, size: 40, color: StitchColors.primary),
                          ),
                          const SizedBox(height: 16),
                          Text('Scan Medicine', style: Theme.of(context).textTheme.headlineMedium?.copyWith(color: StitchColors.primary)),
                          const SizedBox(height: 6),
                          Text('Point camera at the medicine label', style: Theme.of(context).textTheme.bodyMedium),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // ── Stats Row ──────────────────────────
              Row(
                children: [
                  _StatCard(
                    icon: Icons.history,
                    label: 'Total Scans',
                    value: '${storageService.totalScans}',
                    color: StitchColors.primary,
                  ),
                  const SizedBox(width: 12),
                  _StatCard(
                    icon: Icons.warning_amber_rounded,
                    label: 'Warnings',
                    value: '${storageService.dangerCount}',
                    color: StitchColors.danger,
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // ── Recent Scans ──────────────────────────
              Text('Recent Scans', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              ...(_buildRecentLogs()),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildRecentLogs() {
    final logs = storageService.getDoseLogs();
    if (logs.isEmpty) {
      return [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: StitchColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: StitchColors.border),
          ),
          child: Column(
            children: [
              Icon(Icons.medication_outlined, size: 48, color: StitchColors.textMuted),
              const SizedBox(height: 12),
              Text('No scans yet', style: TextStyle(color: StitchColors.textMuted, fontSize: 16)),
              const SizedBox(height: 4),
              Text('Tap "Scan Medicine" to get started', style: TextStyle(color: StitchColors.textMuted, fontSize: 13)),
            ],
          ),
        ),
      ];
    }

    return logs.take(5).map((log) {
      final severity = (log['severity'] ?? 'SAFE').toString();
      return Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: StitchColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: StitchColors.forSeverity(severity).withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Container(
              width: 8, height: 40,
              decoration: BoxDecoration(
                color: StitchColors.forSeverity(severity),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(log['drug_name'] ?? 'Unknown', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: StitchColors.textPrimary)),
                  Text('${log['dosage'] ?? ''} · ${_formatTimestamp(log['timestamp'])}', style: const TextStyle(fontSize: 13, color: StitchColors.textSecondary)),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: StitchColors.forSeverity(severity).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(severity, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: StitchColors.forSeverity(severity))),
            ),
          ],
        ),
      );
    }).toList();
  }

  String _formatTimestamp(String? ts) {
    if (ts == null) return '';
    try {
      final dt = DateTime.parse(ts);
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return ts;
    }
  }
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _StatCard({required this.icon, required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: StitchColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: StitchColors.border),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: color)),
                Text(label, style: const TextStyle(fontSize: 12, color: StitchColors.textSecondary)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
