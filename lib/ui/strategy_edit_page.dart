import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../ai/ai_converter.dart';
import '../app_state.dart';
import '../engine/formula.dart';
import '../models/models.dart';
import '../storage/storage.dart';

/// 策略编辑页（FR-02 / FR-03 / FR-04）。
class StrategyEditPage extends StatefulWidget {
  final AppState appState;
  final Strategy strategy;
  final bool isNew;
  const StrategyEditPage({
    super.key,
    required this.appState,
    required this.strategy,
    this.isNew = false,
  });

  @override
  State<StrategyEditPage> createState() => _StrategyEditPageState();
}

class _StrategyEditPageState extends State<StrategyEditPage> {
  late final TextEditingController _name;
  late final TextEditingController _formula;
  late StrategyScope _scope;
  late KlineSetting _kline;
  late String _signal;
  late int _recentN;
  String? _syntaxError;
  bool _checking = false;

  static const _funcSnippets = [
    'ma(close, 20)', 'ema(close, 12)', 'ref(close, 1)', 'cross(a, b)',
    'llv(low, 9)', 'hhv(high, 9)', 'sum(volume, 5)', 'count(cond, 10)',
    'sma(x, 3, 1)', 'if(cond, a, b)', 'abs(x)', 'max(a, b)', 'min(a, b)',
    'zig(close, 5)', 'peak(close, 5, 1)', 'troughbars(low, 5, 1)',
    'backset(cond, 3)', 'filter(cond, 5)',
  ];

  /// 当前公式是否含未来函数（解析失败时不提示，交给语法检查报错）。
  bool get _hasFutureFunc {
    try {
      return CompiledFormula.compile(_formula.text).hasFutureFunctions;
    } on FormulaException {
      return false;
    }
  }

  static const _futureWarning = '⚠️ 该策略包含未来函数（如 zig/peak/backset/ref 负偏移），'
      '信号可能随行情漂移或重绘，选股结果仅供参考，请勿直接作为买卖依据。';

  @override
  void initState() {
    super.initState();
    final s = widget.strategy;
    _name = TextEditingController(text: s.name);
    _formula = TextEditingController(text: s.formula);
    _scope = s.scope;
    _kline = s.kline;
    _signal = s.signal;
    _recentN = s.recentN;
  }

  @override
  void dispose() {
    _name.dispose();
    _formula.dispose();
    super.dispose();
  }

  Future<void> _checkSyntax() async {
    setState(() {
      _checking = true;
      _syntaxError = null;
    });
    await Future.delayed(const Duration(milliseconds: 100)); // 让 UI 刷新
    try {
      final compiled = CompiledFormula.compile(_formula.text);
      setState(() {
        _syntaxError = null;
        _checking = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(compiled.hasFutureFunctions ? '语法检查通过 ✓（含未来函数，信号可能漂移）' : '语法检查通过 ✓'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } on FormulaException catch (e) {
      setState(() {
        _syntaxError = e.toString();
        _checking = false;
      });
    }
  }

  Future<void> _save() async {
    final s = widget.strategy;
    s.name = _name.text.trim().isEmpty ? '未命名策略' : _name.text.trim();
    s.formula = _formula.text;
    s.scope = _scope;
    s.kline = _kline;
    s.signal = _signal;
    s.recentN = _recentN;
    try {
      CompiledFormula.compile(s.formula);
    } on FormulaException catch (e) {
      setState(() => _syntaxError = e.toString());
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('公式有误，未保存：$e'), behavior: SnackBarBehavior.floating));
      return;
    }
    await widget.appState.strategyStore.save(s);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isNew ? '新建策略' : '编辑策略'),
        actions: [
          IconButton(
            tooltip: 'AI 转换填入',
            icon: const Icon(Icons.auto_awesome_outlined),
            onPressed: () async {
              final code = await showDialog<String>(
                context: context,
                builder: (_) => AiConvertDialog(settingsStore: widget.appState.scanController.settingsStore),
              );
              if (code != null && mounted) {
                setState(() {
                  _formula.text = code;
                  _syntaxError = null;
                });
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('AI 公式已填入，可点"语法检查"验证'),
                    behavior: SnackBarBehavior.floating));
              }
            },
          ),
          IconButton(
            tooltip: '语法检查',
            icon: const Icon(Icons.fact_check_outlined),
            onPressed: _checking ? null : _checkSyntax,
          ),
          IconButton(tooltip: '保存', icon: const Icon(Icons.save), onPressed: _save),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: '策略名称',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          // ---- 公式编辑 ----
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('选股公式', style: Theme.of(context).textTheme.titleSmall),
              TextButton.icon(
                onPressed: _checkSyntax,
                icon: const Icon(Icons.check_circle_outline, size: 18),
                label: const Text('语法检查'),
              ),
            ],
          ),
          TextField(
            controller: _formula,
            maxLines: null,
            minLines: 6,
            style: const TextStyle(
                fontFamily: 'monospace', fontSize: 13),
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              hintText: 'dif = ema(close, 12) - ema(close, 26)\n'
                  'dea = ema(dif, 9)\n'
                  'xg = cross(dif, dea)',
              errorText: _syntaxError,
              helperText: 'Python 风格：一行一条，最后一条为信号（兼容通达信写法）',
            ),
            onChanged: (_) => setState(() => _syntaxError = null),
          ),
          if (_hasFutureFunc) ...[
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
                _futureWarning,
                style: TextStyle(fontSize: 12, color: Colors.amber.shade900),
              ),
            ),
          ],
          const SizedBox(height: 6),
          SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: _funcSnippets
                  .map((f) => Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ActionChip(
                          label: Text(f, style: const TextStyle(fontSize: 11)),
                          onPressed: () {
                            final text = _formula.text;
                            final sel = _formula.selection;
                            final pos = sel.isValid ? sel.start : text.length;
                            final newText =
                                text.substring(0, pos) + f + text.substring(pos);
                            _formula.value = TextEditingValue(
                              text: newText,
                              selection:
                                  TextSelection.collapsed(offset: pos + f.length),
                            );
                          },
                        ),
                      ))
                  .toList(),
            ),
          ),
          const SizedBox(height: 16),
          // ---- 选股范围（FR-03）----
          Text('选股范围', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            children: StrategyScope.boardNames.entries.map((e) {
              final selected = _scope.markets.contains(e.key);
              return FilterChip(
                label: Text(e.value),
                selected: selected,
                onSelected: (v) => setState(() {
                  if (v) {
                    _scope.markets.add(e.key);
                  } else {
                    _scope.markets.remove(e.key);
                  }
                }),
              );
            }).toList(),
          ),
          SwitchListTile(
            title: const Text('剔除 ST'),
            value: _scope.excludeST,
            onChanged: (v) => setState(() => _scope.excludeST = v),
          ),
          SwitchListTile(
            title: const Text('剔除停牌'),
            value: _scope.excludeSuspended,
            onChanged: (v) => setState(() => _scope.excludeSuspended = v),
          ),
          SwitchListTile(
            title: const Text('剔除退市整理股'),
            value: _scope.excludeDelisting,
            onChanged: (v) => setState(() => _scope.excludeDelisting = v),
          ),
          const SizedBox(height: 16),
          // ---- 周期与跨度（FR-04）----
          Text('周期与跨度', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          DropdownButtonFormField<String>(
            initialValue: _kline.period,
            decoration: const InputDecoration(border: OutlineInputBorder()),
            items: KlineSetting.periodNames.entries
                .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                .toList(),
            onChanged: (v) => setState(() => _kline.period = v!),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Text('K线根数：${_kline.count}'),
              Expanded(
                child: Slider(
                  value: _kline.count.toDouble(),
                  min: 30,
                  max: 250,
                  divisions: 44,
                  label: '${_kline.count}',
                  onChanged: (v) => setState(() => _kline.count = v.round()),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // ---- 信号判定 ----
          Text('信号判定', style: Theme.of(context).textTheme.titleSmall),
          RadioListTile<String>(
            title: const Text('最后一根 K 线为信号'),
            value: 'LAST_BAR',
            groupValue: _signal,
            onChanged: (v) => setState(() => _signal = v!),
          ),
          RadioListTile<String>(
            title: const Text('最近 N 根内存在信号'),
            value: 'RECENT_N',
            groupValue: _signal,
            onChanged: (v) => setState(() => _signal = v!),
          ),
          if (_signal == 'RECENT_N')
            Row(
              children: [
                Text('N = $_recentN'),
                Expanded(
                  child: Slider(
                    value: _recentN.toDouble(),
                    min: 2,
                    max: 20,
                    divisions: 18,
                    label: '$_recentN',
                    onChanged: (v) => setState(() => _recentN = v.round()),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save),
            label: const Text('保存策略'),
          ),
        ],
      ),
    );
  }
}

/// AI 公式转换对话框：粘贴任意软件的公式 → AI 改写为本 APP 语法 → 采用填入。
class AiConvertDialog extends StatefulWidget {
  final SettingsStore settingsStore;
  const AiConvertDialog({super.key, required this.settingsStore});

  @override
  State<AiConvertDialog> createState() => _AiConvertDialogState();
}

class _AiConvertDialogState extends State<AiConvertDialog> {
  final _input = TextEditingController();
  String _reply = ''; // 模型原始回复（说明 + 代码块）
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _convert() async {
    setState(() {
      _busy = true;
      _error = null;
      _reply = '';
    });
    try {
      final store = widget.settingsStore;
      final guide = await rootBundle.loadString('assets/ai_syntax.md');
      final converter = AiConverter(
        baseUrl: await store.loadAiBaseUrl(),
        apiKey: await store.loadAiApiKey(),
        model: await store.loadAiModel(),
      );
      final reply = await converter.convert(
          foreignCode: _input.text, syntaxGuide: guide);
      setState(() => _reply = reply);
    } on AiConvertException catch (e) {
      setState(() => _error = e.toString());
    } catch (e) {
      setState(() => _error = 'AI 转换失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 校验并采用：编译通过直接返回；不通过给出错误，仍允许强制填入。
  void _adopt({required bool force}) {
    final code = AiConverter.extractCode(_reply);
    try {
      CompiledFormula.compile(code);
    } on FormulaException catch (e) {
      if (!force) {
        setState(() => _error = '转换结果语法有误：$e\n可点"仍要填入"后手动修改。');
        return;
      }
    }
    Navigator.pop(context, code);
  }

  @override
  Widget build(BuildContext context) {
    final note = AiConverter.extractNote(_reply);
    final code = _reply.isEmpty ? '' : AiConverter.extractCode(_reply);
    return AlertDialog(
      title: const Text('AI 公式转换'),
      content: SizedBox(
        width: 480,
        child: ListView(
          shrinkWrap: true,
          children: [
            const Text('粘贴其他软件（通达信/同花顺/聚宽等）的公式或策略代码：'),
            const SizedBox(height: 8),
            TextField(
              controller: _input,
              maxLines: null,
              minLines: 4,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'MA5:=MA(C,5);\nMA10:=MA(C,10);\nXG:CROSS(MA5,MA10);',
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _busy ? null : _convert,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.auto_awesome, size: 18),
              label: Text(_busy ? '转换中…' : 'AI 转换'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  border: Border.all(color: Colors.red.shade200),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(_error!,
                    style: TextStyle(fontSize: 12, color: Colors.red.shade900)),
              ),
            ],
            if (_reply.isNotEmpty) ...[
              const Divider(height: 20),
              if (note.isNotEmpty && note != '无')
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text('说明：$note',
                      style: Theme.of(context).textTheme.bodySmall),
                ),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SelectableText(
                  code,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('取消')),
        if (_reply.isNotEmpty) ...[
          TextButton(
              onPressed: _busy ? null : () => _adopt(force: true),
              child: const Text('仍要填入')),
          FilledButton(
              onPressed: _busy ? null : () => _adopt(force: false),
              child: const Text('校验并填入')),
        ],
      ],
    );
  }
}
