/// 数据模型：策略、K线、选股结果。
library;

import 'dart:convert';

/// 股票基础信息（来自行情接口）。
class StockInfo {
  final String code; // 600000
  final String market; // SH / SZ / BJ
  final String name;
  final bool isST;
  final bool isSuspended;
  StockInfo({
    required this.code,
    required this.market,
    required this.name,
    this.isST = false,
    this.isSuspended = false,
  });

  /// 东财 secid（如 1.600000）。
  String get secid {
    final prefix = (market == 'SH') ? '1' : '0';
    return '$prefix.$code';
  }

  Map<String, dynamic> toJson() => {
        'code': code,
        'market': market,
        'name': name,
        'isST': isST,
        'isSuspended': isSuspended,
      };
}

/// 单根 K 线。
class Kline {
  final String time; // YYYY-MM-DD 或 YYYY-MM-DD HH:MM
  final double open, high, low, close, vol;
  Kline(this.time, this.open, this.high, this.low, this.close, this.vol);

  Map<String, dynamic> toJson() =>
      {'time': time, 'o': open, 'h': high, 'l': low, 'c': close, 'v': vol};
}

/// 选股策略（对应 strategies/ 下一份 JSON 文件）。
class Strategy {
  String id;
  String name;
  String version;
  String formula;
  StrategyScope scope;
  KlineSetting kline;
  String signal; // LAST_BAR / RECENT_N
  int recentN;
  DateTime createdAt;
  DateTime updatedAt;

  Strategy({
    required this.id,
    required this.name,
    this.version = '1.0',
    required this.formula,
    required this.scope,
    required this.kline,
    this.signal = 'LAST_BAR',
    this.recentN = 3,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'version': version,
        'formula': formula,
        'scope': scope.toJson(),
        'kline': kline.toJson(),
        'signal': signal,
        'recentN': recentN,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory Strategy.fromJson(Map<String, dynamic> j) => Strategy(
        id: j['id'] ?? '',
        name: j['name'] ?? '',
        version: j['version'] ?? '1.0',
        formula: j['formula'] ?? '',
        scope: StrategyScope.fromJson(j['scope'] ?? {}),
        kline: KlineSetting.fromJson(j['kline'] ?? {}),
        signal: j['signal'] ?? 'LAST_BAR',
        recentN: j['recentN'] ?? 3,
        createdAt: DateTime.tryParse(j['createdAt'] ?? '') ?? DateTime.now(),
        updatedAt: DateTime.tryParse(j['updatedAt'] ?? '') ?? DateTime.now(),
      );

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());

  factory Strategy.fromJsonString(String s) =>
      Strategy.fromJson(jsonDecode(s) as Map<String, dynamic>);

  Strategy copy() => Strategy.fromJsonString(toJsonString());
}

/// 选股范围设置。
class StrategyScope {
  static const boardNames = {
    'SH_MAIN': '沪主板',
    'SZ_MAIN': '深主板',
    'CYB': '创业板',
    'KCB': '科创板',
    'BSE': '北交所',
  };

  Set<String> markets; // SH_MAIN / SZ_MAIN / CYB / KCB / BSE
  bool excludeST;
  bool excludeSuspended;
  bool excludeDelisting; // 剔除退市整理（名称含 退）

  StrategyScope({
    Set<String>? markets,
    this.excludeST = true,
    this.excludeSuspended = true,
    this.excludeDelisting = true,
  }) : markets = markets ?? {'SH_MAIN', 'SZ_MAIN', 'CYB'};

  Map<String, dynamic> toJson() => {
        'markets': markets.toList(),
        'excludeST': excludeST,
        'excludeSuspended': excludeSuspended,
        'excludeDelisting': excludeDelisting,
      };

  factory StrategyScope.fromJson(Map<String, dynamic> j) => StrategyScope(
        markets: (j['markets'] as List?)?.cast<String>().toSet(),
        excludeST: j['excludeST'] ?? true,
        excludeSuspended: j['excludeSuspended'] ?? true,
        excludeDelisting: j['excludeDelisting'] ?? true,
      );
}

/// K 线周期设置。
class KlineSetting {
  static const periodNames = {
    'day': '日线',
    'week': '周线',
    'm5': '5分钟',
    'm15': '15分钟',
    'm30': '30分钟',
    'm60': '60分钟',
  };

  String period; // day / week / m5 / m15 / m30 / m60
  int count; // K 线根数，默认 120

  KlineSetting({this.period = 'day', this.count = 120});

  Map<String, dynamic> toJson() => {'period': period, 'count': count};

  factory KlineSetting.fromJson(Map<String, dynamic> j) =>
      KlineSetting(period: j['period'] ?? 'day', count: j['count'] ?? 120);
}

/// 单只股票选股结果。
class StockPick {
  final String code, market, name;
  final double close;
  final String signalDesc;
  final String klineTime; // 触发所在 K 线时间
  StockPick({
    required this.code,
    required this.market,
    required this.name,
    required this.close,
    required this.signalDesc,
    required this.klineTime,
  });

  Map<String, dynamic> toJson() => {
        'code': code,
        'market': market,
        'name': name,
        'close': close,
        'signalDesc': signalDesc,
        'klineTime': klineTime,
      };

  factory StockPick.fromJson(Map<String, dynamic> j) => StockPick(
        code: j['code'] ?? '',
        market: j['market'] ?? '',
        name: j['name'] ?? '',
        close: (j['close'] ?? 0).toDouble(),
        signalDesc: j['signalDesc'] ?? '',
        klineTime: j['klineTime'] ?? '',
      );
}

/// 一次选股任务的结果摘要（results/ 下落盘，原始 K 线不落盘）。
class ScanResult {
  final String id; // scan_20261119_001
  final String strategyId;
  final String strategyName;
  final DateTime finishedAt;
  final int totalScanned; // 扫描股票数
  final int fetchFailed; // 取数失败数
  final int hitCount;
  final List<StockPick> picks;

  ScanResult({
    required this.id,
    required this.strategyId,
    required this.strategyName,
    required this.finishedAt,
    required this.totalScanned,
    required this.fetchFailed,
    required this.hitCount,
    required this.picks,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'strategyId': strategyId,
        'strategyName': strategyName,
        'finishedAt': finishedAt.toIso8601String(),
        'totalScanned': totalScanned,
        'fetchFailed': fetchFailed,
        'hitCount': hitCount,
        'picks': picks.map((p) => p.toJson()).toList(),
      };

  factory ScanResult.fromJson(Map<String, dynamic> j) => ScanResult(
        id: j['id'] ?? '',
        strategyId: j['strategyId'] ?? '',
        strategyName: j['strategyName'] ?? '',
        finishedAt: DateTime.tryParse(j['finishedAt'] ?? '') ?? DateTime.now(),
        totalScanned: j['totalScanned'] ?? 0,
        fetchFailed: j['fetchFailed'] ?? 0,
        hitCount: j['hitCount'] ?? 0,
        picks: (j['picks'] as List? ?? [])
            .map((e) => StockPick.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());

  factory ScanResult.fromJsonString(String s) =>
      ScanResult.fromJson(jsonDecode(s) as Map<String, dynamic>);
}
