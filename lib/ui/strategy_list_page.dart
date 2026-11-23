import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../app_state.dart';
import '../models/models.dart';
import '../storage/storage.dart';
import 'strategy_edit_page.dart';

/// 策略列表页（FR-01）。
class StrategyListPage extends StatefulWidget {
  final AppState appState;
  const StrategyListPage({super.key, required this.appState});

  @override
  State<StrategyListPage> createState() => _StrategyListPageState();
}

class _StrategyListPageState extends State<StrategyListPage> {
  @override
  void initState() {
    super.initState();
    widget.appState.loadStrategies();
  }

  Future<void> _refresh() async => widget.appState.loadStrategies();

  @override
  Widget build(BuildContext context) {
    final strategies = widget.appState.strategies;
    return Scaffold(
      appBar: AppBar(
        title: const Text('选股策略'),
        actions: [
          IconButton(
            tooltip: '语法与函数说明',
            icon: const Icon(Icons.help_outline),
            onPressed: () => Navigator.pushNamed(context, '/help'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final s = Strategy(
            id: StrategyStore.newId(),
            name: '新策略',
            formula: 'xg = cross(ma(close, 5), ma(close, 10))',
            scope: StrategyScope(),
            kline: KlineSetting(),
          );
          await _edit(s, isNew: true);
        },
        icon: const Icon(Icons.add),
        label: const Text('新建策略'),
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: strategies.isEmpty
            ? ListView(children: const [
                SizedBox(height: 120),
                Center(child: Text('暂无策略，点击右下角新建')),
              ])
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
                itemCount: strategies.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, i) {
                  final s = strategies[i];
                  return Card(
                    clipBehavior: Clip.antiAlias,
                    child: ListTile(
                      title: Text(s.name,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(
                        '${KlineSetting.periodNames[s.kline.period]} · '
                        '${s.kline.count}根 · 更新于 '
                        '${s.updatedAt.toString().substring(0, 16)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: PopupMenuButton<String>(
                        onSelected: (v) async {
                          switch (v) {
                            case 'edit':
                              await _edit(s);
                            case 'copy':
                              final c = s.copy()
                                ..id = StrategyStore.newId()
                                ..name = '${s.name} 副本';
                              await widget.appState.strategyStore.save(c);
                              await _refresh();
                            case 'export':
                              await Share.shareXFiles(
                                [XFile.fromData(
                                  Uint8List.fromList(
                                      utf8.encode(s.toJsonString())),
                                  name: '${s.name}.json',
                                  mimeType: 'application/json',
                                )],
                                subject: s.name,
                              );
                            case 'delete':
                              final ok = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: Text('删除策略 ${s.name}？'),
                                  content: const Text('删除后不可恢复。'),
                                  actions: [
                                    TextButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, false),
                                        child: const Text('取消')),
                                    FilledButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, true),
                                        child: const Text('删除')),
                                  ],
                                ),
                              );
                              if (ok == true) {
                                await widget.appState.strategyStore
                                    .delete(s.id);
                                await _refresh();
                              }
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'edit', child: Text('编辑')),
                          PopupMenuItem(value: 'copy', child: Text('复制')),
                          PopupMenuItem(value: 'export', child: Text('导出/分享')),
                          PopupMenuItem(value: 'delete', child: Text('删除')),
                        ],
                      ),
                      onTap: () => _edit(s),
                    ),
                  );
                },
              ),
      ),
    );
  }

  Future<void> _edit(Strategy s, {bool isNew = false}) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
          builder: (_) => StrategyEditPage(
              appState: widget.appState, strategy: s, isNew: isNew)),
    );
    if (saved == true) await _refresh();
  }
}
