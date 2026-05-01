import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme/stitch_theme.dart';
import 'theme/stitch_colors.dart';
import 'services/haptic_service.dart';
import 'services/tts_service.dart';
import 'services/storage_service.dart';
import 'services/api_service.dart';
import 'services/scan_complete_handler.dart';
import 'screens/home_screen.dart';
import 'screens/scan_screen.dart';
import 'screens/history_screen.dart';

/// ── Global service instances ─────────────────────────────────────
final hapticService = HapticService();
final ttsService = TtsService();
final storageService = StorageService();
final apiService = ApiService();
late final ScanCompleteHandler scanCompleteHandler;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Force portrait
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  // Initialize services
  await hapticService.init();
  await ttsService.init();
  await storageService.init();

  scanCompleteHandler = ScanCompleteHandler(
    haptic: hapticService,
    tts: ttsService,
    storage: storageService,
    api: apiService,
  );

  // Launch pulse + welcome
  hapticService.launchPulse();
  ttsService.speak('Welcome to IrisAI. Your medicine assistant is ready.');

  runApp(const IrisApp());
}

class IrisApp extends StatelessWidget {
  const IrisApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'IrisAI',
      debugShowCheckedModeBanner: false,
      theme: StitchTheme.dark,
      home: const _AppShell(),
    );
  }
}

class _AppShell extends StatefulWidget {
  const _AppShell();

  @override
  State<_AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<_AppShell> with WidgetsBindingObserver {
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ttsService.dispose();
    storageService.dispose();
    apiService.dispose();
    super.dispose();
  }

  void _onTabTap(int index) {
    hapticService.confirmTap();
    setState(() => _currentIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: [
          HomeScreen(onScanTap: () => _onTabTap(1)),
          const ScanScreen(),
          const HistoryScreen(),
        ],
      ),
      bottomNavigationBar: Semantics(
        label: 'Navigation bar',
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: _onTabTap,
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.home_rounded),
              label: 'Home',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.document_scanner_rounded),
              label: 'Scan',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.history_rounded),
              label: 'History',
            ),
          ],
        ),
      ),
    );
  }
}
