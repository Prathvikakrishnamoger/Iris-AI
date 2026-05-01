import 'package:flutter/material.dart';
import '../theme/stitch_colors.dart';

/// Placeholder — result screen navigated from scan.
/// The actual result is shown inline from ScanScreen.
class ResultScreen extends StatelessWidget {
  const ResultScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Result')),
      body: const Center(
        child: Text('Results are shown inline after scanning.',
          style: TextStyle(color: StitchColors.textSecondary, fontSize: 16)),
      ),
    );
  }
}
