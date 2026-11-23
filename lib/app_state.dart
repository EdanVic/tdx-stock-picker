import 'package:flutter/foundation.dart';

import 'models/models.dart';
import 'state/scan_controller.dart';
import 'storage/storage.dart';

/// 全局应用状态：策略存储 + 选股调度器。
class AppState extends ChangeNotifier {
  final StrategyStore strategyStore = StrategyStore();
  final ScanController scanController = ScanController();

  List<Strategy> strategies = [];

  Future<void> loadStrategies() async {
    strategies = await strategyStore.loadAll();
    notifyListeners();
  }
}
