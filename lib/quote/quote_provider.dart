/// 行情数据网关：QuoteProvider 抽象 + 东方财富公开接口实现。
///
/// 设计要点（对齐计划书 4.1/4.2）：
/// - 接口可插拔：预留局域网数据服务（方案 B）适配器；
/// - 并发控制 + 指数退避重试 3 次 + 请求限频；
/// - 数据只在内存与任务级缓存中使用，用后删除，不做持久化。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/models.dart';

/// 行情网关异常。
class QuoteException implements Exception {
  final String message;
  QuoteException(this.message);
  @override
  String toString() => '行情接口错误：$message';
}

/// 行情数据源抽象。方案 B（局域网 Python 服务）实现同一接口即可切换。
abstract class QuoteProvider {
  /// 拉取指定板块的股票基础列表（含 ST / 停牌标记）。
  Future<List<StockInfo>> fetchStockList(Set<String> boards);

  /// 拉取单只股票 K 线。period: day/week/m5/m15/m30/m60，count 为根数。
  Future<List<Kline>> fetchKline(StockInfo stock, String period, int count);

  /// 数据源显示名称。
  String get name;
}

/// 东方财富公开 HTTP 接口（个人学习研究用途）。
class EastMoneyProvider implements QuoteProvider {
  /// 东财 numbered 镜像（N.push2.eastmoney.com），主站被单边缘节点掐连时自动换镜像。
  static const _listHosts = [
    'push2.eastmoney.com',
    '92.push2.eastmoney.com',
    '91.push2.eastmoney.com',
    '90.push2.eastmoney.com',
  ];
  static const _hisHosts = [
    'push2his.eastmoney.com',
    '92.push2his.eastmoney.com',
    '91.push2his.eastmoney.com',
  ];
  final http.Client _client;
  EastMoneyProvider([http.Client? client]) : _client = client ?? http.Client();

  @override
  String get name => '东方财富公开接口';

  /// 浏览器风格请求头：东财对无 UA/异常频率的客户端会主动断连，必须带上。
  static const _headers = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
    'Referer': 'https://quote.eastmoney.com/',
  };

  /// 板块 → 东财 fs 参数。
  static const _boardFs = {
    'SH_MAIN': 'm:1+t:2',
    'KCB': 'm:1+t:23',
    'SZ_MAIN': 'm:0+t:6',
    'CYB': 'm:0+t:80',
    'BSE': 'm:0+t:81+s:2048',
  };

  /// period → 东财 klt 参数。
  static const _klt = {
    'day': '101',
    'week': '102',
    'month': '103',
    'm5': '5',
    'm15': '15',
    'm30': '30',
    'm60': '60',
  };

  @override
  Future<List<StockInfo>> fetchStockList(Set<String> boards) async {
    final fs = boards
        .where((b) => _boardFs.containsKey(b))
        .map((b) => _boardFs[b]!)
        .join(',');
    if (fs.isEmpty) return [];
    final out = <StockInfo>[];
    final seen = <String>{};
    var pn = 1;
    // 东财单页最多返回 100 条（pz 设再大也被截断），必须按 total 翻页取全
    while (true) {
      // 单页请求：重试 3 次（指数退避），每次换镜像主机，抗单节点断连
      Map<String, dynamic>? data;
      Object? lastErr;
      for (var attempt = 0; attempt < 3; attempt++) {
        if (attempt > 0) {
          await Future.delayed(Duration(seconds: 1 << (attempt - 1)));
        }
        final host = _listHosts[attempt % _listHosts.length];
        final uri = Uri.https(host, '/api/qt/clist/get', {
          'pn': '$pn',
          'pz': '100',
          'po': '1',
          'np': '1',
          'fltt': '2',
          'invt': '2',
          'fid': 'f3',
          'fs': fs,
          'fields': 'f12,f14,f2',
        });
        try {
          final resp = await _client
              .get(uri, headers: _headers)
              .timeout(const Duration(seconds: 20));
          if (resp.statusCode != 200) {
            throw QuoteException('HTTP ${resp.statusCode}');
          }
          final j = jsonDecode(resp.body) as Map<String, dynamic>;
          data = j['data'] as Map<String, dynamic>?;
          if (data == null) throw QuoteException('返回为空');
          lastErr = null;
          break;
        } catch (e) {
          lastErr = e;
          data = null;
        }
      }
      if (data == null) {
        throw QuoteException('股票列表第 $pn 页获取失败（重试 3 次）：$lastErr');
      }
      final total = (data['total'] as num?)?.toInt() ?? 0;
      final diff = (data['diff'] as List?) ?? [];
      if (diff.isEmpty) break;
      for (final item in diff) {
        final m = item as Map<String, dynamic>;
        final code = (m['f12'] ?? '').toString();
        if (code.isEmpty || !seen.add(code)) continue;
        final name = (m['f14'] ?? '').toString();
        final price = m['f2']; // '-' 表示停牌
        final market = code.startsWith('6')
            ? 'SH'
            : (code.startsWith('8') || code.startsWith('4')) ? 'BJ' : 'SZ';
        out.add(StockInfo(
          code: code,
          market: market,
          name: name,
          isST: name.toUpperCase().contains('ST'),
          isSuspended: price == '-' || price == null,
        ));
      }
      if (out.length >= total) break;
      pn++;
      await Future.delayed(const Duration(milliseconds: 500)); // 翻页限频
    }
    return out;
  }

  @override
  Future<List<Kline>> fetchKline(StockInfo stock, String period, int count) async {
    final klt = _klt[period];
    if (klt == null) throw QuoteException('不支持的周期 $period');
    // 镜像轮询：任一镜像成功即返回；全部失败抛最后错误（外层还有 3 次退避重试）
    http.Response? resp;
    Object? lastErr;
    for (final host in _hisHosts) {
      final uri = Uri.https(host, '/api/qt/stock/kline/get', {
        'secid': stock.secid,
        'klt': klt,
        'fqt': '1', // 前复权
        'lmt': '$count',
        'end': '20500101',
        'iscca': '1',
        'fields1': 'f1,f2,f3,f7',
        'fields2': 'f51,f52,f53,f54,f55,f56,f57',
      });
      try {
        final r = await _client
            .get(uri, headers: _headers)
            .timeout(const Duration(seconds: 20));
        if (r.statusCode != 200) {
          throw QuoteException('K线 HTTP ${r.statusCode}');
        }
        resp = r;
        break;
      } catch (e) {
        lastErr = e;
      }
    }
    if (resp == null) throw lastErr ?? QuoteException('K线全部镜像失败');
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    final data = j['data'];
    if (data == null) return []; // 无数据（新股、停牌等）
    final klines = (data['klines'] as List?) ?? [];
    final out = <Kline>[];
    for (final line in klines) {
      final parts = (line as String).split(',');
      if (parts.length < 6) continue;
      double d(String s) => double.tryParse(s) ?? 0;
      out.add(Kline(parts[0], d(parts[1]), d(parts[3]), d(parts[4]), d(parts[2]),
          d(parts[5])));
    }
    return out;
  }
}

/// 带并发、重试、限频的行情客户端。
class QuoteClient {
  final QuoteProvider provider;
  final int concurrency; // 并发数
  final int maxRetry; // 重试次数（计划书：3 次指数退避）
  final Duration minInterval; // 请求最小间隔（限频）

  QuoteClient(
    this.provider, {
    this.concurrency = 6,
    this.maxRetry = 3,
    this.minInterval = const Duration(milliseconds: 100),
  });

  Future<List<StockInfo>> stockList(Set<String> boards) =>
      provider.fetchStockList(boards);

  /// 对股票列表并发拉取 K 线。
  ///
  /// [onProgress] 回调 (已完成数, 成功数, 失败数)；[isCancelled] 返回 true 时中止。
  /// [concurrency] / [minInterval] 可覆盖构造默认值（扫描速度档位）。
  /// 返回 code → K线 的映射；失败的股票不在结果中，由调用方按失败数统计。
  Future<Map<String, List<Kline>>> fetchKlines(
    List<StockInfo> stocks,
    String period,
    int count, {
    void Function(int done, int ok, int failed)? onProgress,
    bool Function()? isCancelled,
    int? concurrency,
    Duration? minInterval,
  }) async {
    final conc = concurrency ?? this.concurrency;
    final interval = minInterval ?? this.minInterval;
    final result = <String, List<Kline>>{};
    final queue = List<StockInfo>.from(stocks);
    var done = 0, ok = 0, failed = 0;
    var lastRequest = DateTime.fromMillisecondsSinceEpoch(0);

    Future<void> worker() async {
      while (true) {
        if (isCancelled?.call() ?? false) return;
        // Dart 单线程事件循环：removeAt 与计数更新均为原子操作
        if (queue.isEmpty) return;
        final stock = queue.removeAt(0);
        List<Kline>? k;
        var attempt = 0;
        while (true) {
          // 限频：保证请求最小间隔
          final now = DateTime.now();
          final wait = interval - now.difference(lastRequest);
          if (wait > Duration.zero) await Future.delayed(wait);
          lastRequest = DateTime.now();
          try {
            k = await provider.fetchKline(stock, period, count);
            break;
          } catch (_) {
            attempt++;
            if (attempt > maxRetry) {
              k = null;
              break;
            }
            // 指数退避：1s, 2s, 4s...
            await Future.delayed(Duration(seconds: 1 << (attempt - 1)));
          }
        }
        if (isCancelled?.call() ?? false) return;
        done++;
        if (k == null) {
          failed++;
        } else {
          ok++;
          result[stock.code] = k;
        }
        onProgress?.call(done, ok, failed);
      }
    }

    final workers = List.generate(conc, (_) => worker());
    await Future.wait(workers);
    return result;
  }
}
