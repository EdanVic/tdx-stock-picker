import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../analysis/returns.dart';
import '../app_state.dart';
import '../models/models.dart';
import '../quote/quote_provider.dart';
import '../quote/tencent_provider.dart';
import '../storage/storage.dart';
import 'kline_chart.dart';

/// 选股结果页：历史结果摘要 + 命中明细（FR-07 导出 CSV）。
/// 支持单条删除；长按进入多选模式批量删除。
class ResultsPage extends StatefulWidget {
  final AppState appState;
  const ResultsPage({super.key, required this.appState});

  @override
  State<ResultsPage> createState() => _ResultsPageState();
}

class _ResultsPageState extends State<ResultsPage> {
  final ResultStore _store = ResultStore();
  List<ScanResult> _results = [];
  bool _loading = true;

  /// 多选模式
  final Set<String> _selected = {};
  bool get _selecting => _selected.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    _results = await _store.loadAll();
    if (mounted) {
      setState(() {
        _loading = false;
        _selected.retainAll(_results.map((r) => r.id));
      });
    }
  }

  Future<void> _deleteOne(ScanResult r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除 ${r.strategyName} 的选股结果？'),
        content: Text('命中 ${r.hitCount} 只，删除后不可恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok == true) {
      await _store.delete(r.id);
      _selected.remove(r.id);
      await _refresh();
    }
  }

  Future<void> _deleteSelected() async {
    final n = _selected.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除选中的 $n 条结果？'),
        content: const Text('删除后不可恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok == true) {
      for (final id in _selected.toList()) {
        await _store.delete(id);
      }
      _selected.clear();
      await _refresh();
    }
  }

  void _exitSelection() => setState(_selected.clear);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _selecting
            ? Text('已选 ${_selected.length} 项')
            : const Text('选股结果'),
        leading: _selecting
            ? IconButton(
                tooltip: '退出多选',
                icon: const Icon(Icons.close),
                onPressed: _exitSelection,
              )
            : null,
        actions: [
          if (_selecting)
            IconButton(
              tooltip: '删除选中',
              icon: const Icon(Icons.delete_outline),
              onPressed: _deleteSelected,
            )
          else
            IconButton(
              tooltip: '刷新',
              icon: const Icon(Icons.refresh),
              onPressed: _refresh,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _results.isEmpty
              ? const Center(
                  child: Text('暂无选股结果，先到"选股"页执行一次选股'))
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: _results.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final r = _results[i];
                    final time =
                        DateFormat('MM-dd HH:mm').format(r.finishedAt);
                    final selected = _selected.contains(r.id);
                    return Card(
                      color: selected
                          ? Theme.of(context)
                              .colorScheme
                              .primaryContainer
                          : null,
                      clipBehavior: Clip.antiAlias,
                      child: ListTile(
                        leading: _selecting
                            ? Icon(selected
                                ? Icons.check_circle
                                : Icons.radio_button_unchecked)
                            : CircleAvatar(child: Text('${r.hitCount}')),
                        title: Text(r.strategyName,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600)),
                        subtitle: Text(
                            '$time · 扫描${r.totalScanned}只 · 取数失败${r.fetchFailed}只'),
                        trailing: _selecting
                            ? null
                            : IconButton(
                                tooltip: '删除',
                                icon: const Icon(Icons.delete_outline,
                                    size: 20),
                                onPressed: () => _deleteOne(r),
                              ),
                        onLongPress: () => setState(() {
                          _selected.add(r.id);
                        }),
                        onTap: () {
                          if (_selecting) {
                            setState(() {
                              if (selected) {
                                _selected.remove(r.id);
                              } else {
                                _selected.add(r.id);
                              }
                            });
                          } else {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => ResultDetailPage(
                                      result: r,
                                      appState: widget.appState)),
                            ).then((_) => _refresh());
                          }
                        },
                      ),
                    );
                  },
                ),
    );
  }
}

class ResultDetailPage extends StatefulWidget {
  final ScanResult result;
  final AppState appState;
  const ResultDetailPage({super.key, required this.result, required this.appState});

  @override
  State<ResultDetailPage> createState() => _ResultDetailPageState();
}

class _ResultDetailPageState extends State<ResultDetailPage> {
  final _store = ResultStore();
  late final List<StockPick> _picks = List.of(widget.result.picks);

  // ---- 收益测算状态 ----
  bool _measuring = false;
  bool _cancelMeasure = false;
  bool _measureDialogOpen = false;
  final _measureProgress = ValueNotifier<String>('准备中…');

  @override
  void dispose() {
    _measureProgress.dispose();
    super.dispose();
  }

  /// 删除单个标的并落盘；SnackBar 提供撤销。
  Future<void> _removePick(int index) async {
    final p = _picks[index];
    setState(() => _picks.removeAt(index));
    await _persist();
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context)
      ..clearSnackBars();
    messenger.showSnackBar(SnackBar(
      content: Text('已删除 ${p.name} (${p.code})'),
      behavior: SnackBarBehavior.floating,
      action: SnackBarAction(
        label: '撤销',
        onPressed: () async {
          setState(() => _picks.insert(index.clamp(0, _picks.length), p));
          await _persist();
        },
      ),
    ));
  }

  /// 将当前（可能被删改过的）列表写回结果文件，hitCount 同步更新。
  Future<void> _persist() async {
    final r = widget.result;
    await _store.save(ScanResult(
      id: r.id,
      strategyId: r.strategyId,
      strategyName: r.strategyName,
      finishedAt: r.finishedAt,
      totalScanned: r.totalScanned,
      fetchFailed: r.fetchFailed,
      hitCount: _picks.length,
      picks: List.of(_picks),
    ));
  }

  QuoteProvider _providerFor(String source) => switch (source) {
        SettingsStore.kTencent => TencentProvider(),
        SettingsStore.kEastMoney => EastMoneyProvider(),
        _ => MultiSourceProvider(TencentProvider(), EastMoneyProvider()),
      };

  /// 收益测算：当前列表 → 最新行情，弹窗展示平均收益与逐只明细。
  Future<void> _calcReturns() async {
    if (_measuring) return;
    if (_picks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('列表为空，没有可测算的标的'),
          behavior: SnackBarBehavior.floating));
      return;
    }
    setState(() => _measuring = true);
    _cancelMeasure = false;
    _measureProgress.value = '准备中…';
    _measureDialogOpen = true;
    // 进度对话框（可取消，不随点击外部关闭）
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('收益测算'),
        content: ValueListenableBuilder<String>(
          valueListenable: _measureProgress,
          builder: (_, text, __) => Text(text),
        ),
        actions: [
          TextButton(
            onPressed: () => _cancelMeasure = true,
            child: const Text('取消'),
          ),
        ],
      ),
    );
    ReturnsReport? report;
    String? error;
    try {
      final store = widget.appState.scanController.settingsStore;
      final conc = await store.loadConcurrency();
      final source = await store.loadDataSource();
      final client = QuoteClient(_providerFor(source),
          concurrency: conc,
          minInterval: Duration(milliseconds: (1000 / conc).round()));
      final stocks = _picks
          .map((p) => StockInfo(code: p.code, market: p.market, name: p.name))
          .toList();
      final klines = await client.fetchKlines(stocks, 'day', 5,
          isCancelled: () => _cancelMeasure,
          onProgress: (done, ok, failed) => _measureProgress.value =
              '拉取最新行情：$done/${stocks.length}（失败 $failed）');
      if (!_cancelMeasure) report = buildReport(_picks, klines);
    } catch (e) {
      error = e.toString();
    } finally {
      if (_measureDialogOpen && mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      _measureDialogOpen = false;
      if (mounted) setState(() => _measuring = false);
    }
    if (!mounted || _cancelMeasure) return;
    if (error != null) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('收益测算失败'),
          content: SelectableText(error!),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('知道了'))
          ],
        ),
      );
    } else if (report != null) {
      _showReport(report);
    }
  }

  /// 展示收益报告：平均收益率 + 正收益占比 + 逐只明细。
  void _showReport(ReturnsReport r) {
    final baseDate = DateFormat('yyyy-MM-dd').format(widget.result.finishedAt);
    final avg = r.average;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('策略收益测算'),
        content: SizedBox(
          width: 480,
          child: ListView(
            shrinkWrap: true,
            children: [
              Text('区间：$baseDate（选股）→ ${r.latestTime}（最新行情）',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 8),
              Text(
                avg == null
                    ? '无有效标的'
                    : '平均收益率 ${avg >= 0 ? '+' : ''}${avg.toStringAsFixed(2)}%',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: avg == null
                      ? null
                      : (avg >= 0 ? Colors.red : Colors.green),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '正收益 ${r.items.where((e) => e.rate > 0).length}/${r.items.length} 只'
                '${r.failedCodes.isNotEmpty ? ' · 取数失败 ${r.failedCodes.length} 只（未计入平均）' : ''}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (r.best != null && r.items.length > 1)
                Text(
                  '最高 ${r.best!.pick.name} ${r.best!.rate.toStringAsFixed(2)}% · '
                  '最低 ${r.worst!.pick.name} ${r.worst!.rate.toStringAsFixed(2)}%',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              const Divider(height: 20),
              ...r.items.map((e) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${e.pick.name}  ${e.baseClose.toStringAsFixed(2)} → ${e.latestClose.toStringAsFixed(2)}',
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                        Text(
                          '${e.rate >= 0 ? '+' : ''}${e.rate.toStringAsFixed(2)}%',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: e.rate >= 0 ? Colors.red : Colors.green,
                          ),
                        ),
                      ],
                    ),
                  )),
              const Divider(height: 16),
              Text(
                '基准价=选股信号 K 线收盘价；最新价=最新日线收盘价（盘中为实时价）。'
                '仅供评估策略历史表现，不构成投资建议。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了'))
        ],
      ),
    );
  }

  /// 导出 CSV（UTF-8 with BOM，Excel 兼容）并分享。导出当前列表（含手动删除后的）。
  Future<void> _exportCsv(BuildContext context) async {
    final buf = StringBuffer('﻿代码,名称,收盘价,信号说明,信号时间\n');
    // 注意：字符串首字符为 ﻿ BOM，保证 Excel 正确识别 UTF-8
    for (final p in _picks) {
      buf.writeln('${p.code},${p.name},${p.close},${p.signalDesc},${p.klineTime}');
    }
    final dir = await getTemporaryDirectory();
    final file = File(
        '${dir.path}/${widget.result.strategyName}_${widget.result.id}.csv');
    await file.writeAsBytes(Uint8List.fromList(utf8.encode(buf.toString())));
    if (context.mounted) {
      await Share.shareXFiles([XFile(file.path)],
          subject: '选股结果：${widget.result.strategyName}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.result.strategyName} · 命中${_picks.length}只'),
        actions: [
          IconButton(
            tooltip: '收益测算（列表至今平均收益）',
            icon: const Icon(Icons.percent),
            onPressed: _measuring ? null : _calcReturns,
          ),
          IconButton(
            tooltip: '导出 CSV / 分享',
            icon: const Icon(Icons.ios_share),
            onPressed: () => _exportCsv(context),
          ),
        ],
      ),
      body: _picks.isEmpty
          ? const Center(child: Text('列表已清空（全部手动删除）'))
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: _picks.length,
              separatorBuilder: (_, __) => const SizedBox(height: 6),
              itemBuilder: (context, i) {
                final p = _picks[i];
                return Card(
                  child: ListTile(
                    title: Text('${p.name} (${p.code})'),
                    subtitle: Text('${p.signalDesc} · ${p.klineTime}'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          p.close.toStringAsFixed(2),
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 16),
                        ),
                        IconButton(
                          tooltip: '从结果中删除',
                          icon: const Icon(Icons.remove_circle_outline,
                              size: 20),
                          onPressed: () => _removePick(i),
                        ),
                      ],
                    ),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => KlineChartPage(
                            stock: StockInfo(
                                code: p.code, market: p.market, name: p.name),
                            period: 'day',
                            count: 120,
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
    );
  }
}
