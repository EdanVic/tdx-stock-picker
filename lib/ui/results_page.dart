import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../app_state.dart';
import '../models/models.dart';
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
                                  builder: (_) =>
                                      ResultDetailPage(result: r)),
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
  const ResultDetailPage({super.key, required this.result});

  @override
  State<ResultDetailPage> createState() => _ResultDetailPageState();
}

class _ResultDetailPageState extends State<ResultDetailPage> {
  final _store = ResultStore();
  late final List<StockPick> _picks = List.of(widget.result.picks);

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
