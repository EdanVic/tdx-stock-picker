import 'package:flutter/material.dart';

import 'app_state.dart';
import 'storage/storage.dart';
import 'ui/help_page.dart';
import 'ui/results_page.dart';
import 'ui/scan_page.dart';
import 'ui/settings_page.dart';
import 'ui/strategy_list_page.dart';

void main() {
  runApp(const StockPickerApp());
}

class StockPickerApp extends StatefulWidget {
  const StockPickerApp({super.key});

  @override
  State<StockPickerApp> createState() => _StockPickerAppState();
}

class _StockPickerAppState extends State<StockPickerApp> {
  late final AppState appState;

  @override
  void initState() {
    super.initState();
    appState = AppState();
    _init();
  }

  Future<void> _init() async {
    final existing = await appState.strategyStore.loadAll();
    if (existing.isEmpty) {
      // 首次启动：写入示例策略
      for (final s in sampleStrategies) {
        await appState.strategyStore.save(s);
      }
    }
    await appState.loadStrategies();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        return MaterialApp(
          title: 'tdx选股药丸',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF1B5E20),
              brightness: Brightness.light,
            ),
            useMaterial3: true,
            scaffoldBackgroundColor: const Color(0xFFF6F7F9),
          ),
          home: HomePage(appState: appState),
          routes: {
            '/help': (_) => const HelpPage(),
            '/settings': (_) => SettingsPage(appState: appState),
          },
        );
      },
    );
  }
}

class HomePage extends StatefulWidget {
  final AppState appState;
  const HomePage({super.key, required this.appState});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      StrategyListPage(appState: widget.appState),
      ScanPage(appState: widget.appState),
      ResultsPage(appState: widget.appState),
      SettingsPage(appState: widget.appState),
    ];
    return Scaffold(
      body: pages[_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.folder_outlined), label: '策略'),
          NavigationDestination(icon: Icon(Icons.play_circle_outline), label: '选股'),
          NavigationDestination(icon: Icon(Icons.fact_check_outlined), label: '结果'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), label: '设置'),
        ],
      ),
    );
  }
}
