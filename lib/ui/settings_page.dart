import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../ai/ai_converter.dart';
import '../app_state.dart';
import '../storage/storage.dart';

/// 设置页：缓存清理（FR-06）、语法说明、数据来源与免责声明。
class SettingsPage extends StatefulWidget {
  final AppState appState;
  const SettingsPage({super.key, required this.appState});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String _cacheInfo = '';
  int _concurrency = SettingsStore.kDefaultConcurrency;
  String _dataSource = SettingsStore.kAuto;
  final _aiBaseUrl = TextEditingController();
  final _aiApiKey = TextEditingController();
  final _aiModel = TextEditingController();
  bool _aiConfigLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _aiBaseUrl.dispose();
    _aiApiKey.dispose();
    _aiModel.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final store = widget.appState.scanController.settingsStore;
    final concurrency = await store.loadConcurrency();
    final source = await store.loadDataSource();
    if (!mounted) return;
    setState(() {
      _concurrency = concurrency;
      _dataSource = source;
    });
    if (!_aiConfigLoaded) {
      _aiBaseUrl.text = await store.loadAiBaseUrl();
      _aiApiKey.text = await store.loadAiApiKey();
      _aiModel.text = await store.loadAiModel();
      if (mounted) setState(() => _aiConfigLoaded = true);
    }
  }

  Future<void> _setConcurrency(int concurrency) async {
    setState(() => _concurrency = concurrency);
    await widget.appState.scanController.settingsStore
        .saveConcurrency(concurrency);
  }

  Future<void> _setDataSource(String source) async {
    setState(() => _dataSource = source);
    await widget.appState.scanController.settingsStore.saveDataSource(source);
  }

  Future<void> _saveAiConfig() async {
    final store = widget.appState.scanController.settingsStore;
    await store.saveAiConfig(
      baseUrl: _aiBaseUrl.text,
      apiKey: _aiApiKey.text,
      model: _aiModel.text,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('AI 配置已保存'), behavior: SnackBarBehavior.floating));
    }
  }

  bool _testingAi = false;

  /// 连通测试：用当前输入框的配置发一个最小请求，显示结果。
  Future<void> _testAiConnection() async {
    setState(() => _testingAi = true);
    String msg;
    try {
      final converter = AiConverter(
        baseUrl: _aiBaseUrl.text,
        apiKey: _aiApiKey.text,
        model: _aiModel.text,
      );
      final reply = await converter.ping();
      msg = '连接成功 · 模型回复：$reply';
    } on AiConvertException catch (e) {
      msg = e.toString();
    } catch (e) {
      msg = '连接失败：$e';
    }
    if (mounted) {
      setState(() => _testingAi = false);
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(msg.startsWith('连接成功') ? '连通测试通过' : '连通测试失败'),
          content: SelectableText(msg, style: const TextStyle(fontSize: 13)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
          ],
        ),
      );
    }
  }

  Future<void> _clearCache() async {
    // ① 清空内存中的任务级缓存
    widget.appState.scanController.clearCache();
    // ② 兜底：确认应用目录下不存在任何行情 K 线落盘文件
    var removed = 0;
    try {
      final base = await getApplicationDocumentsDirectory();
      await for (final f in base.list(recursive: true)) {
        if (f is File) {
          final name = f.path.toLowerCase();
          if (name.endsWith('.kline') || name.contains('/cache/kline')) {
            await f.delete();
            removed++;
          }
        }
      }
    } catch (_) {}
    setState(() => _cacheInfo = '缓存已清空（删除兜底文件 $removed 个）。'
        '行情数据本就只在选股任务内存中临时存在，任务结束自动释放。');
  }

  Future<void> _clearResults() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空全部选股结果？'),
        content: const Text('仅删除结果摘要，不影响策略文件。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('清空')),
        ],
      ),
    );
    if (ok == true) {
      final base = await getApplicationDocumentsDirectory();
      final d = Directory('${base.path}/results');
      if (await d.exists()) {
        await for (final f in d.list()) {
          if (f is File) await f.delete();
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('结果摘要已清空'), behavior: SnackBarBehavior.floating));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.delete_sweep_outlined),
            title: const Text('清除全部缓存'),
            subtitle: const Text('选股任务结束会自动清理；此处为兜底按钮（FR-06）'),
            onTap: _clearCache,
          ),
          if (_cacheInfo.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(_cacheInfo,
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('清空选股结果摘要'),
            subtitle: const Text('删除 results/ 目录下全部结果文件'),
            onTap: _clearResults,
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.speed),
            title: Text('扫描并发数：$_concurrency'),
            subtitle: const Text('并发越高扫描越快（1 最稳，10 最快），'
                '只影响扫描时长，不影响选股结果。绿色为推荐区间 2–5。'),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackShape: const RecZoneTrackShape(),
                trackHeight: 6,
                // 轨道本身不着色：活动/非活动段同灰色，只留可拖动的把手
                activeTrackColor:
                    Theme.of(context).colorScheme.onSurface.withOpacity(0.12),
                inactiveTrackColor:
                    Theme.of(context).colorScheme.onSurface.withOpacity(0.12),
                tickMarkShape: SliderTickMarkShape.noTickMark,
                overlayColor:
                    Theme.of(context).colorScheme.onSurface.withOpacity(0.08),
              ),
              child: Slider(
                value: _concurrency.toDouble(),
                min: SettingsStore.kMinConcurrency.toDouble(),
                max: SettingsStore.kMaxConcurrency.toDouble(),
                divisions:
                    SettingsStore.kMaxConcurrency - SettingsStore.kMinConcurrency,
                label: '$_concurrency 并发',
                onChanged: (v) => _setConcurrency(v.round()),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              '提示：若选股过程中频繁出现"取数失败/连接被关闭"，说明当前网络出口'
              '被行情接口临时限制——可开关一次飞行模式切换 IP，并把并发调低后'
              '重新启动选股。自动模式下主源受限会自动切换备用源。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('行情数据源'),
            subtitle: const Text('自动模式：腾讯主源 + 东财兜底，主源被临时限制时自动切换。'
                '只影响取数通道，不影响选股结果。'),
          ),
          RadioListTile<String>(
            title: const Text('自动（推荐）'),
            subtitle: const Text('腾讯主源，失败自动切东财兜底'),
            value: SettingsStore.kAuto,
            groupValue: _dataSource,
            onChanged: (v) => _setDataSource(v!),
          ),
          RadioListTile<String>(
            title: const Text('仅腾讯'),
            subtitle: const Text('免费 HTTP 源，对手机客户端更友好'),
            value: SettingsStore.kTencent,
            groupValue: _dataSource,
            onChanged: (v) => _setDataSource(v!),
          ),
          RadioListTile<String>(
            title: const Text('仅东财'),
            subtitle: const Text('历史默认源，对请求频率敏感，可能被临时断连'),
            value: SettingsStore.kEastMoney,
            groupValue: _dataSource,
            onChanged: (v) => _setDataSource(v!),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.auto_awesome_outlined),
            title: const Text('AI 公式转换'),
            subtitle: const Text('在策略编辑页点右上角 ✨ 图标，粘贴任意软件的公式，'
                'AI 改写为本 APP 语法。使用 OpenAI 兼容接口，密钥只保存在本机。'),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                DropdownButtonFormField<String>(
                  initialValue: null,
                  isDense: true,
                  decoration: const InputDecoration(
                    labelText: '快速选择服务商',
                    isDense: true,
                  ),
                  hint: const Text('选择后自动填入地址与模型，只需填密钥'),
                  items: const [
                    DropdownMenuItem(
                        value: 'kimi-sub',
                        child: Text('Kimi 订阅版（会员 Coding 计划）')),
                    DropdownMenuItem(
                        value: 'moonshot',
                        child: Text('Moonshot 开放平台（按量付费）')),
                    DropdownMenuItem(value: 'deepseek', child: Text('DeepSeek')),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    final preset = switch (v) {
                      'kimi-sub' => (
                          'https://api.kimi.com/coding/v1',
                          'kimi-for-coding'
                        ),
                      'deepseek' => ('https://api.deepseek.com/v1', 'deepseek-chat'),
                      _ => ('https://api.moonshot.cn/v1', 'moonshot-v1-8k'),
                    };
                    setState(() {
                      _aiBaseUrl.text = preset.$1;
                      _aiModel.text = preset.$2;
                    });
                  },
                ),
                TextField(
                  controller: _aiBaseUrl,
                  decoration: const InputDecoration(
                    labelText: 'API 地址',
                    hintText: 'https://api.moonshot.cn/v1',
                    isDense: true,
                  ),
                  onEditingComplete: _saveAiConfig,
                ),
                TextField(
                  controller: _aiModel,
                  decoration: const InputDecoration(
                    labelText: '模型',
                    hintText: 'moonshot-v1-8k',
                    isDense: true,
                  ),
                  onEditingComplete: _saveAiConfig,
                ),
                TextField(
                  controller: _aiApiKey,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'API 密钥',
                    isDense: true,
                  ),
                  onEditingComplete: _saveAiConfig,
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _testingAi ? null : _testAiConnection,
                      child: Text(_testingAi ? '测试中…' : '测试连通'),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: _saveAiConfig,
                      child: const Text('保存 AI 配置'),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Kimi 订阅版与开放平台不通用：会员 Coding 计划选第一项'
                    '（api.kimi.com/coding/v1），按量付费用第二项。'
                    'Kimi 订阅版模型固定 temperature=1，APP 已自动适配。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.menu_book_outlined),
            title: const Text('函数与语法说明'),
            onTap: () => Navigator.pushNamed(context, '/help'),
          ),
          const Divider(),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('数据来源'),
            subtitle: Text('腾讯 / 东方财富公开行情 HTTP 接口，仅作个人学习研究用途，'
                '不做数据转发服务。选股数据按需临时拉取、用后删除，不做持久化。'),
          ),
          const ListTile(
            leading: Icon(Icons.gavel_outlined),
            title: Text('免责声明'),
            subtitle: Text('本 APP 不提供交易功能，不接入券商接口，不构成任何投资'
                '建议。股市有风险，投资需谨慎。'),
          ),
          const ListTile(
            leading: Icon(Icons.tag),
            title: Text('版本'),
            subtitle: Text('V2.2.2 · tdx选股药丸'),
          ),
        ],
      ),
    );
  }
}

/// 滑条轨道：在推荐区间（2–5 并发）上叠加绿色高亮段。
///
/// 先由父类绘制默认轨道，再用 [getPreferredRect] 得到的真实轨道矩形
/// 按值域比例定位绿色区段——把手中心严格落在轨道矩形内线性插值，
/// 因此推荐区与刻度 2–5 精确对齐。
class RecZoneTrackShape extends RoundedRectSliderTrackShape {
  const RecZoneTrackShape();

  static const _min = 1.0;
  static const _max = 10.0;
  static const _recLo = 2.0;
  static const _recHi = 5.0;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = true,
    double additionalActiveTrackHeight = 2,
  }) {
    super.paint(
      context,
      offset,
      parentBox: parentBox,
      sliderTheme: sliderTheme,
      enableAnimation: enableAnimation,
      textDirection: textDirection,
      thumbCenter: thumbCenter,
      secondaryOffset: secondaryOffset,
      isDiscrete: isDiscrete,
      isEnabled: isEnabled,
      additionalActiveTrackHeight: additionalActiveTrackHeight,
    );
    // 真实轨道矩形（已扣除把手/水波纹占位），值→x 在其中线性映射
    final track = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    double t(double v) => (v - _min) / (_max - _min);
    final left = track.left + t(_recLo) * track.width;
    final zoneWidth = (t(_recHi) - t(_recLo)) * track.width;
    final rect =
        Rect.fromLTWH(left, track.top, zoneWidth, track.height);
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(track.height / 2)),
      Paint()..color = const Color(0xFF4CAF50).withOpacity(0.45),
    );
  }
}
