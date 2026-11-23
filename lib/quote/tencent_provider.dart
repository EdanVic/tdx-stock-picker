/// 腾讯行情 provider（免费 HTTP 源）：股票列表 + 日/周/分钟 K 线。
///
/// 接口（个人学习研究用途）：
/// - 列表：proxy.finance.qq.com/cgi/cgi-bin/rank/hs/getBoardRankList
///   （board_code=aStock，每页 200，沪深 A 含 ST/创业板，不含科创板）
/// - 日/周 K（前复权）：web.ifzq.gtimg.cn/appstock/app/fqkline/get
///   行格式：[date, open, close, high, low, volume]（注意 close 在第 3 位）
/// - 分钟 K：ifzq.gtimg.cn/appstock/app/kline/mkline
///   行格式：[YYYYMMDDHHMM, open, close, high, low, volume]
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/models.dart';
import 'quote_provider.dart';

class TencentProvider implements QuoteProvider {
  static const _rankHost = 'proxy.finance.qq.com';
  static const _fqHost = 'web.ifzq.gtimg.cn';
  static const _mHost = 'ifzq.gtimg.cn';
  static const _headers = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
    'Referer': 'https://gu.qq.com/',
  };

  final http.Client _client;
  TencentProvider([http.Client? client]) : _client = client ?? http.Client();

  @override
  String get name => '腾讯行情';

  /// 板块 → 腾讯代码前缀（科创板 sh68 不在 aStock 列表内，需东财兜底）。
  static const _boardPrefixes = {
    'SH_MAIN': ['sh60'],
    'SZ_MAIN': ['sz00'],
    'CYB': ['sz30'],
  };

  @override
  Future<List<StockInfo>> fetchStockList(Set<String> boards) async {
    final wanted = <String>[];
    for (final b in boards) {
      wanted.addAll(_boardPrefixes[b] ?? const []);
    }
    if (wanted.isEmpty) {
      throw QuoteException('腾讯源不支持所选板块（科创板/北交所请用自动或东财源）');
    }
    final out = <StockInfo>[];
    final seen = <String>{};
    var offset = 0;
    var total = -1;
    while (total < 0 || offset < total) {
      final uri = Uri.https(_rankHost,
          '/cgi/cgi-bin/rank/hs/getBoardRankList', {
        'board_code': 'aStock',
        'sort_type': 'Price',
        'direct': 'down',
        'offset': '$offset',
        'count': '200',
      });
      Map<String, dynamic>? data;
      Object? lastErr;
      for (var attempt = 0; attempt < 3; attempt++) {
        if (attempt > 0) {
          await Future.delayed(Duration(seconds: 1 << (attempt - 1)));
        }
        try {
          final resp = await _client
              .get(uri, headers: _headers)
              .timeout(const Duration(seconds: 20));
          if (resp.statusCode != 200) {
            throw QuoteException('HTTP ${resp.statusCode}');
          }
          final j = jsonDecode(resp.body) as Map<String, dynamic>;
          data = j['data'] as Map<String, dynamic>?;
          if (data == null || data['rank_list'] == null) {
            throw QuoteException('返回为空');
          }
          break;
        } catch (e) {
          lastErr = e;
          data = null;
        }
      }
      if (data == null) {
        throw QuoteException('腾讯列表 offset=$offset 获取失败：$lastErr');
      }
      total = (data['total'] as num?)?.toInt() ?? 0;
      final rl = (data['rank_list'] as List).cast<Map<String, dynamic>>();
      if (rl.isEmpty) break;
      for (final m in rl) {
        final full = (m['code'] ?? '').toString(); // sh600519 / sz300750
        if (full.length < 8) continue;
        final prefix = full.substring(0, 2);
        final code = full.substring(2);
        if (!wanted.any((p) => full.startsWith(p))) continue;
        if (!seen.add(code)) continue;
        final name = (m['name'] ?? '').toString();
        out.add(StockInfo(
          code: code,
          market: prefix.toUpperCase() == 'SH' ? 'SH' : 'SZ',
          name: name,
          isST: name.toUpperCase().contains('ST'),
          isSuspended: false, // 腾讯列表无停牌标记，由扫描时按 K 线新旧判定
        ));
      }
      offset += rl.length;
      await Future.delayed(const Duration(milliseconds: 400)); // 翻页限频
    }
    return out;
  }

  @override
  Future<List<Kline>> fetchKline(StockInfo stock, String period, int count) async {
    final sym = '${stock.market.toLowerCase()}${stock.code}';
    if (period == 'day' || period == 'week') {
      return _fetchFqKline(sym, period, count);
    }
    if (period.startsWith('m')) {
      return _fetchMinuteKline(sym, period, count);
    }
    throw QuoteException('腾讯源不支持的周期 $period');
  }

  /// 日/周线（前复权）。
  Future<List<Kline>> _fetchFqKline(String sym, String period, int count) async {
    final fqPeriod = period == 'week' ? 'week' : 'day';
    final uri = Uri.https(_fqHost, '/appstock/app/fqkline/get', {
      'param': '$sym,$fqPeriod,,,$count,qfq',
    });
    final resp = await _client
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      throw QuoteException('腾讯K线 HTTP ${resp.statusCode}');
    }
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    final data = j['data'];
    if (data is! Map<String, dynamic>) return [];
    final d = data[sym];
    if (d is! Map<String, dynamic>) return [];
    // 前复权键：qfqday/qfqweek；无复权数据时回退 day/week
    final rows = (d['qfq$fqPeriod'] ?? d[fqPeriod]) as List?;
    if (rows == null) return [];
    return rows.map(_parseDailyRow).whereType<Kline>().toList();
  }

  /// 分钟线（5/15/30/60）。param 的周期键为 m5/m15/m30/m60。
  Future<List<Kline>> _fetchMinuteKline(
      String sym, String period, int count) async {
    final uri = Uri.https(_mHost, '/appstock/app/kline/mkline', {
      'param': '$sym,$period,,$count',
    });
    final resp = await _client
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      throw QuoteException('腾讯分钟K线 HTTP ${resp.statusCode}');
    }
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    final data = j['data'];
    if (data is! Map<String, dynamic>) return [];
    final d = data[sym];
    if (d is! Map<String, dynamic>) return [];
    final rows = d[period] as List?;
    if (rows == null) return [];
    final out = <Kline>[];
    for (final r in rows) {
      if (r is! List || r.length < 6) continue;
      final k = _parseDailyRow(r); // 行格式一致：[dt, open, close, high, low, vol]
      if (k == null) continue;
      // 分钟时间戳 YYYYMMDDHHMM → YYYY-MM-DD HH:MM
      final dt = k.time;
      if (dt.length == 12) {
        out.add(Kline(
            '${dt.substring(0, 4)}-${dt.substring(4, 6)}-${dt.substring(6, 8)} '
            '${dt.substring(8, 10)}:${dt.substring(10, 12)}',
            k.open,
            k.high,
            k.low,
            k.close,
            k.vol));
      } else {
        out.add(k);
      }
    }
    return out;
  }

  /// 腾讯行格式：[date, open, close, high, low, volume, …]
  Kline? _parseDailyRow(dynamic r) {
    if (r is! List || r.length < 6) return null;
    double d(dynamic v) => double.tryParse('${v ?? ""}') ?? 0;
    return Kline(
        '${r[0]}', d(r[1]), d(r[3]), d(r[4]), d(r[2]), d(r[5]));
  }
}

/// 多源自动切换：主源失败自动切备用源（熔断记忆，避免每次请求都撞死源）。
///
/// 列表按板块拆分：非科创板走主源，科创板走备用源（腾讯列表缺科创板）。
/// K 线：主源 → 备用源逐只降级；主源连续失败达到阈值后熔断一段时间。
class MultiSourceProvider implements QuoteProvider {
  final QuoteProvider primary;
  final QuoteProvider fallback;
  final int circuitThreshold; // 连续失败多少次后熔断主源
  final Duration circuitCooldown;

  int _consecutiveFails = 0;
  DateTime? _primaryDisabledUntil;

  MultiSourceProvider(this.primary, this.fallback,
      {this.circuitThreshold = 5, this.circuitCooldown = const Duration(minutes: 5)});

  @override
  String get name => '${primary.name}（${fallback.name}兜底）';

  bool get _primaryOk =>
      _primaryDisabledUntil == null ||
      DateTime.now().isAfter(_primaryDisabledUntil!);

  void _recordPrimaryOk() => _consecutiveFails = 0;

  void _recordPrimaryFail() {
    _consecutiveFails++;
    if (_consecutiveFails >= circuitThreshold) {
      _primaryDisabledUntil = DateTime.now().add(circuitCooldown);
    }
  }

  @override
  Future<List<StockInfo>> fetchStockList(Set<String> boards) async {
    final out = <StockInfo>[];
    final seen = <String>{};
    final nonKcb = boards.where((b) => b != 'KCB').toSet();
    if (nonKcb.isNotEmpty) {
      try {
        final list = await primary.fetchStockList(nonKcb);
        for (final s in list) {
          if (seen.add(s.code)) out.add(s);
        }
      } catch (_) {
        // 主源列表失败：整段交备用源
        return fallback.fetchStockList(boards);
      }
    }
    if (boards.contains('KCB')) {
      // 腾讯 aStock 列表不含科创板，科创板列表固定走备用源
      final kcb = await fallback.fetchStockList({'KCB'});
      for (final s in kcb) {
        if (seen.add(s.code)) out.add(s);
      }
    }
    return out;
  }

  @override
  Future<List<Kline>> fetchKline(
      StockInfo stock, String period, int count) async {
    if (_primaryOk) {
      try {
        final k = await primary.fetchKline(stock, period, count);
        _recordPrimaryOk();
        return k;
      } catch (_) {
        _recordPrimaryFail();
      }
    }
    return fallback.fetchKline(stock, period, count);
  }
}
