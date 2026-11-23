import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../engine/formula.dart';
import '../models/models.dart';
import '../state/scan_controller.dart';

/// 选股执行页（FR-05）：选策略 → 执行 → 进度/取消 → 跳转结果。
class ScanPage extends StatefulWidget {
  final AppState appState;
  const ScanPage({super.key, required this.appState});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  Strategy? _selected;

  @override
  void initState() {
    super.initState();
    widget.appState.loadStrategies();
  }

  Future<void> _run() async {
    final s = _selected;
    if (s == null) return;
    await widget.appState.scanController.run(s);
  }

  /// 策略公式是否含未来函数（解析失败按无处理，执行时会另行报错）。
  bool _hasFutureFunc(Strategy s) {
    try {
      return CompiledFormula.compile(s.formula).hasFutureFunctions;
    } on FormulaException {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final strategies = widget.appState.strategies;
    final controller = widget.appState.scanController;
    if (_selected == null && strategies.isNotEmpty) {
      _selected = strategies.first;
    }

    return Scaffold(
      appBar: AppBar(title: const Text('执行选股')),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final p = controller.progress;
          final running = controller.isRunning;
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Text('选择策略', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              DropdownButtonFormField<Strategy>(
                initialValue: _selected,
                decoration: const InputDecoration(border: OutlineInputBorder()),
                items: strategies
                    .map((s) => DropdownMenuItem(value: s, child: Text(s.name)))
                    .toList(),
                onChanged: running
                    ? null
                    : (v) => setState(() => _selected = v),
              ),
              const SizedBox(height: 12),
              if (_selected != null)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${KlineSetting.periodNames[_selected!.kline.period]} · '
                          '${_selected!.kline.count}根 · '
                          '${_selected!.scope.markets.map((m) => StrategyScope.boardNames[m]).join('/')} · '
                          '${_selected!.scope.excludeST ? "剔除ST" : "含ST"}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 6),
                        Text(_selected!.formula,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontFamily: 'monospace', fontSize: 12)),
                      ],
                    ),
                  ),
                ),
              if (_selected != null && _hasFutureFunc(_selected!)) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.amber.shade50,
                    border: Border.all(color: Colors.amber.shade300),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '⚠️ 该策略含未来函数，信号可能漂移/重绘，结果仅供参考',
                    style: TextStyle(fontSize: 12.5, color: Colors.amber.shade900),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              // ---- 任务状态机展示 ----
              _buildStatusCard(context, p, running),
              const SizedBox(height: 16),
              if (!running)
                FilledButton.icon(
                  onPressed: (_selected == null || strategies.isEmpty)
                      ? null
                      : _run,
                  icon: const Icon(Icons.play_arrow),
                  label: Text(strategies.isEmpty
                      ? '请先到"策略"页创建策略'
                      : (p.status == ScanStatus.done
                          ? '再次执行选股'
                          : '开始选股')),
                ),
              if (p.status == ScanStatus.done && controller.lastResult != null)
                Card(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  child: ListTile(
                    leading: const Icon(Icons.check_circle),
                    title: Text('选股完成：命中 ${controller.lastResult!.hitCount} 只'),
                    subtitle: Text(
                        '扫描 ${controller.lastResult!.totalScanned} 只，'
                        '取数失败 ${controller.lastResult!.fetchFailed} 只；'
                        '请到下方"结果"页查看明细'),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildStatusCard(BuildContext context, ScanProgress p, bool running) {
    final theme = Theme.of(context);
    String statusText;
    switch (p.status) {
      case ScanStatus.idle:
        statusText = '待开始';
      case ScanStatus.fetchingList:
        statusText = '正在获取股票列表…';
      case ScanStatus.fetchingKlines:
        statusText = '正在拉取 K 线数据…';
      case ScanStatus.computing:
        statusText = '正在执行公式计算…';
      case ScanStatus.done:
        statusText = '任务完成';
      case ScanStatus.failed:
        statusText = '任务失败';
      case ScanStatus.cancelled:
        statusText = '已取消，临时缓存已清理';
    }
    final progressValue = p.total == 0
        ? null
        : (p.status == ScanStatus.computing
            ? (p.computed / p.total).clamp(0.0, 1.0)
            : (p.done / p.total).clamp(0.0, 1.0));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (running)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                if (running) const SizedBox(width: 8),
                Expanded(
                  child: Text(statusText,
                      style: theme.textTheme.bodyMedium,
                      overflow: TextOverflow.ellipsis),
                ),
                if (running)
                  TextButton.icon(
                    onPressed: _cancel,
                    icon: const Icon(Icons.stop, size: 18),
                    label: const Text('取消'),
                  ),
              ],
            ),
            if (p.total > 0) ...[
              const SizedBox(height: 10),
              LinearProgressIndicator(value: progressValue),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  Text('总数 ${p.total}'),
                  Text('已取数 ${p.done}'),
                  Text('成功 ${p.ok}'),
                  Text('失败 ${p.failed}'),
                  if (p.status == ScanStatus.computing)
                    Text('已计算 ${p.computed}'),
                  if (p.hit > 0) Text('命中 ${p.hit}'),
                  if (p.etaSeconds != null && running)
                    Text('预计剩余 ${p.etaSeconds}s'),
                ],
              ),
            ],
            // 失败时完整展示错误信息（可复制），不再截断
            if (p.status == ScanStatus.failed && p.error != null) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '错误详情（可长按选择复制）',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.onErrorContainer,
                            ),
                          ),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.copy, size: 16),
                          tooltip: '复制错误信息',
                          onPressed: () async {
                            await Clipboard.setData(
                                ClipboardData(text: p.error!));
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text('错误信息已复制'),
                                      behavior: SnackBarBehavior.floating));
                            }
                          },
                        ),
                      ],
                    ),
                    SelectableText(
                      p.error!,
                      style: TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _cancel() => widget.appState.scanController.cancel();
}
