/// 本地存储：策略文件（strategies/）与选股结果摘要（results/）。
///
/// 即用即删原则：行情 K 线数据只在选股任务内存中持有，任务结束即释放，
/// 本存储层不提供任何行情落盘能力。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/models.dart';

class StrategyStore {
  Directory? _dir;

  Future<Directory> get dir async {
    if (_dir != null) return _dir!;
    final base = await getApplicationDocumentsDirectory();
    _dir = Directory('${base.path}/strategies');
    if (!await _dir!.exists()) await _dir!.create(recursive: true);
    return _dir!;
  }

  Future<List<Strategy>> loadAll() async {
    final d = await dir;
    final files =
        d.listSync().whereType<File>().where((f) => f.path.endsWith('.json'));
    final list = <Strategy>[];
    for (final f in files) {
      try {
        list.add(Strategy.fromJsonString(await f.readAsString()));
      } catch (_) {
        // 跳过损坏文件
      }
    }
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  Future<void> save(Strategy s) async {
    final d = await dir;
    s.updatedAt = DateTime.now();
    final file = File('${d.path}/${s.id}.json');
    await file.writeAsString(s.toJsonString());
  }

  Future<void> delete(String id) async {
    final d = await dir;
    final file = File('${d.path}/$id.json');
    if (await file.exists()) await file.delete();
  }

  static String newId() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'strategy_${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }
}

class ResultStore {
  Directory? _dir;

  Future<Directory> get dir async {
    if (_dir != null) return _dir!;
    final base = await getApplicationDocumentsDirectory();
    _dir = Directory('${base.path}/results');
    if (!await _dir!.exists()) await _dir!.create(recursive: true);
    return _dir!;
  }

  Future<List<ScanResult>> loadAll() async {
    final d = await dir;
    final files =
        d.listSync().whereType<File>().where((f) => f.path.endsWith('.json'));
    final list = <ScanResult>[];
    for (final f in files) {
      try {
        list.add(ScanResult.fromJsonString(await f.readAsString()));
      } catch (_) {}
    }
    list.sort((a, b) => b.finishedAt.compareTo(a.finishedAt));
    return list;
  }

  Future<File> save(ScanResult r) async {
    final d = await dir;
    final file = File('${d.path}/${r.id}.json');
    await file.writeAsString(r.toJsonString());
    return file;
  }

  Future<void> delete(String id) async {
    final d = await dir;
    final file = File('${d.path}/$id.json');
    if (await file.exists()) await file.delete();
  }

  static String newId() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'scan_${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }
}

/// 内置示例策略（首次启动时写入，对齐计划书 7.3 基准公式，Python 风格语法）。
final sampleStrategies = <Strategy>[
  Strategy(
    id: 'sample_macd_cross',
    name: 'MACD金叉',
    formula: 'dif = ema(close, 12) - ema(close, 26)\n'
        'dea = ema(dif, 9)\n'
        'xg = cross(dif, dea)',
    scope: StrategyScope(markets: {'SH_MAIN', 'SZ_MAIN', 'CYB'}),
    kline: KlineSetting(period: 'day', count: 120),
  ),
  Strategy(
    id: 'sample_kdj_oversold',
    name: 'KDJ超卖区金叉',
    formula: 'rsv = (close - llv(low, 9)) / (hhv(high, 9) - llv(low, 9)) * 100\n'
        'k = sma(rsv, 3, 1)\n'
        'd = sma(k, 3, 1)\n'
        'j = 3 * k - 2 * d\n'
        'xg = cross(k, d) and d < 20',
    scope: StrategyScope(markets: {'SH_MAIN', 'SZ_MAIN', 'CYB'}),
    kline: KlineSetting(period: 'day', count: 120),
  ),
  Strategy(
    id: 'sample_shrink_pullback',
    name: '缩量回踩20日线',
    formula: 'ma20 = ma(close, 20)\n'
        'xg = abs(close / ma20 - 1) < 0.02 and volume < ma(volume, 5) * 0.8',
    scope: StrategyScope(markets: {'SH_MAIN', 'SZ_MAIN', 'CYB'}),
    kline: KlineSetting(period: 'day', count: 120),
  ),
];

/// 应用设置（settings.json）：扫描并发数 + 行情数据源。
class SettingsStore {
  static const kMinConcurrency = 1;
  static const kMaxConcurrency = 10;
  static const kDefaultConcurrency = 2;

  static const kAuto = 'auto'; // 腾讯主源 + 东财兜底
  static const kTencent = 'tencent';
  static const kEastMoney = 'eastmoney';

  Future<File> get _file async {
    final base = await getApplicationDocumentsDirectory();
    return File('${base.path}/settings.json');
  }

  Future<Map<String, dynamic>> _loadJson() async {
    try {
      final f = await _file;
      if (await f.exists()) {
        return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      }
    } catch (_) {
      // 损坏则回退默认
    }
    return {};
  }

  Future<void> _saveJson(Map<String, dynamic> j) async {
    final f = await _file;
    await f.writeAsString(jsonEncode(j));
  }

  /// 扫描并发数（1–5，默认 2）。并发越高取数越快，但越容易触发
  /// 行情接口风控；旧版 scanSpeed 档位字段自动忽略。
  Future<int> loadConcurrency() async {
    final s = (await _loadJson())['concurrency'];
    if (s is num) {
      final v = s.toInt();
      if (v >= kMinConcurrency && v <= kMaxConcurrency) return v;
    }
    return kDefaultConcurrency;
  }

  Future<void> saveConcurrency(int concurrency) async {
    final j = await _loadJson();
    j['concurrency'] = concurrency;
    await _saveJson(j);
  }

  /// 行情数据源：auto（默认，腾讯优先东财兜底）/ tencent / eastmoney。
  Future<String> loadDataSource() async {
    final s = (await _loadJson())['dataSource'];
    return s == kTencent || s == kEastMoney ? s : kAuto;
  }

  Future<void> saveDataSource(String source) async {
    final j = await _loadJson();
    j['dataSource'] = source;
    await _saveJson(j);
  }

  // ---- AI 公式转换配置（OpenAI 兼容接口）----
  static const kDefaultAiBaseUrl = 'https://api.moonshot.cn/v1';
  static const kDefaultAiModel = 'moonshot-v1-8k';

  /// API 密钥只存本机 settings.json，不上传、不外发（仅用于请求时鉴权）。
  Future<String> loadAiBaseUrl() async =>
      ((await _loadJson())['aiBaseUrl'] ?? kDefaultAiBaseUrl).toString();

  Future<String> loadAiApiKey() async =>
      ((await _loadJson())['aiApiKey'] ?? '').toString();

  Future<String> loadAiModel() async =>
      ((await _loadJson())['aiModel'] ?? kDefaultAiModel).toString();

  Future<void> saveAiConfig(
      {String? baseUrl, String? apiKey, String? model}) async {
    final j = await _loadJson();
    if (baseUrl != null) j['aiBaseUrl'] = baseUrl.trim();
    if (apiKey != null) j['aiApiKey'] = apiKey.trim();
    if (model != null) j['aiModel'] = model.trim();
    await _saveJson(j);
  }
}
