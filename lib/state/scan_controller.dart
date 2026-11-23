/// 选股任务调度器：任务状态机 + 进度回调 + 取消 + 临时缓存管理。
///
/// 状态机（对齐计划书 7.2(4)）：
///   idle → fetchingList → fetchingKlines → computing → done / failed / cancelled
///
/// 即用即删：K 线缓存只存在于本对象内存（_cache），任务结束（含异常/取消）
/// 由 [clearCache] 无条件清空；结果仅保存摘要（ScanResult）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../engine/formula.dart';
import '../models/models.dart';
import '../quote/quote_provider.dart';
import '../quote/tencent_provider.dart';
import '../storage/storage.dart';

enum ScanStatus { idle, fetchingList, fetchingKlines, computing, done, failed, cancelled }

class ScanProgress {
  final ScanStatus status;
  final int total; // 待处理股票总数
  final int done; // 已取数完成
  final int ok; // 取数成功
  final int failed; // 取数失败
  final int computed; // 已计算
  final int hit; // 已命中
  final String? error;
  final DateTime? startedAt;

  ScanProgress({
    required this.status,
    this.total = 0,
    this.done = 0,
    this.ok = 0,
    this.failed = 0,
    this.computed = 0,
    this.hit = 0,
    this.error,
    this.startedAt,
  });

  /// 预计剩余时间（秒），数据不足时返回 null。
  int? get etaSeconds {
    if (startedAt == null || done == 0 || done >= total) return null;
    final elapsed = DateTime.now().difference(startedAt!).inSeconds;
    final per = elapsed / done;
    return (per * (total - done)).round();
  }

  ScanProgress copyWith({
    ScanStatus? status,
    int? total,
    int? done,
    int? ok,
    int? failed,
    int? computed,
    int? hit,
    String? error,
  }) =>
      ScanProgress(
        status: status ?? this.status,
        total: total ?? this.total,
        done: done ?? this.done,
        ok: ok ?? this.ok,
        failed: failed ?? this.failed,
        computed: computed ?? this.computed,
        hit: hit ?? this.hit,
        error: error ?? this.error,
        startedAt: startedAt,
      );
}

class ScanController extends ChangeNotifier {
  final ResultStore resultStore;
  final SettingsStore settingsStore;

  ScanController({ResultStore? resultStore, SettingsStore? settingsStore})
      : resultStore = resultStore ?? ResultStore(),
        settingsStore = settingsStore ?? SettingsStore();

  /// 数据源设置 → 行情 provider。auto（默认）：腾讯主源 + 东财兜底自动切换。
  QuoteProvider _buildProvider(String source) => switch (source) {
        SettingsStore.kTencent => TencentProvider(),
        SettingsStore.kEastMoney => EastMoneyProvider(),
        _ => MultiSourceProvider(TencentProvider(), EastMoneyProvider()),
      };

  /// 停牌判定（腾讯股票列表无停牌标记）：按 K 线新旧估计。
  /// 日线末根早于 7 个自然日、分钟线末根早于 2 个自然日视为停牌/长期无成交。
  bool _suspendedByKline(List<Kline> k, String period) {
    if (k.isEmpty) return false;
    final dt = DateTime.tryParse(k.last.time);
    if (dt == null) return false;
    final limit = period.startsWith('m')
        ? const Duration(days: 2)
        : const Duration(days: 7);
    return DateTime.now().difference(dt) > limit;
  }

  /// 并发数 → (并发数, 请求最小间隔)：每并发约 1 次/秒（1000/concurrency ms）。
  /// 并发越高扫描越快，但越容易被行情接口临时限制；只影响扫描时长，
  /// 不影响选股结果。
  (int, Duration) _pacing(int concurrency) {
    final c = concurrency.clamp(SettingsStore.kMinConcurrency,
        SettingsStore.kMaxConcurrency);
    return (c, Duration(milliseconds: (1000 / c).round()));
  }

  ScanProgress _progress =
      ScanProgress(status: ScanStatus.idle);
  ScanProgress get progress => _progress;

  /// 任务级临时缓存：code → K线，任务结束无条件清空（FR-06）。
  final Map<String, List<Kline>> _cache = {};
  bool _cancelled = false;

  /// 最近一次选股结果（done 状态后可用）。
  ScanResult? lastResult;

  bool get isRunning =>
      _progress.status == ScanStatus.fetchingList ||
      _progress.status == ScanStatus.fetchingKlines ||
      _progress.status == ScanStatus.computing;

  void _set(ScanProgress p) {
    _progress = p;
    notifyListeners();
  }

  void cancel() {
    if (isRunning) _cancelled = true;
  }

  /// 手动清理全部缓存（设置页兜底按钮，FR-06）。
  void clearCache() {
    _cache.clear();
  }

  /// 执行选股任务。返回任务结果；被取消时返回 null。
  Future<ScanResult?> run(Strategy strategy) async {
    if (isRunning) return null;
    _cancelled = false;
    _cache.clear();
    lastResult = null;
    final startedAt = DateTime.now();
    _set(ScanProgress(status: ScanStatus.fetchingList, startedAt: startedAt));

    try {
      // 0) 读取设置：扫描并发数 + 数据源，并构建本次任务专用的行情客户端
      final (conc, interval) = _pacing(await settingsStore.loadConcurrency());
      final source = await settingsStore.loadDataSource();
      final client = QuoteClient(_buildProvider(source),
          concurrency: conc, minInterval: interval);

      // ① 拉取股票基础列表并按范围过滤
      final all = await client.stockList(strategy.scope.markets);
      final stocks = all.where((s) {
        if (strategy.scope.excludeST && s.isST) return false;
        if (strategy.scope.excludeSuspended && s.isSuspended) return false;
        if (strategy.scope.excludeDelisting && s.name.contains('退')) return false;
        return true;
      }).toList();

      if (_cancelled) {
        _set(ScanProgress(status: ScanStatus.cancelled));
        return null;
      }

      // ② 编译公式（任务级编译一次，逐只复用）
      final CompiledFormula formula;
      try {
        formula = CompiledFormula.compile(strategy.formula);
      } on FormulaException catch (e) {
        _set(ScanProgress(status: ScanStatus.failed, error: e.toString()));
        return null;
      }

      // ③ 并发拉取 K 线 → 任务级临时缓存（内存），速度档位决定并发与限频
      _set(_progress.copyWith(
          status: ScanStatus.fetchingKlines, total: stocks.length));
      final klines = await client.fetchKlines(
        stocks,
        strategy.kline.period,
        strategy.kline.count,
        isCancelled: () => _cancelled,
        concurrency: conc,
        minInterval: interval,
        onProgress: (done, ok, failed) => _set(_progress.copyWith(
            done: done, ok: ok, failed: failed)),
      );
      if (_cancelled) {
        clearCache();
        _set(ScanProgress(status: ScanStatus.cancelled));
        return null;
      }

      // ④ 引擎逐只计算
      _set(_progress.copyWith(status: ScanStatus.computing));
      final picks = <StockPick>[];
      var computed = 0;
      for (final stock in stocks) {
        if (_cancelled) {
          clearCache();
          _set(ScanProgress(status: ScanStatus.cancelled));
          return null;
        }
        final k = klines[stock.code];
        if (k == null || k.isEmpty) {
          computed++;
          continue; // 取数失败或无数据，标记后跳过
        }
        // 腾讯源列表不带停牌标记：剔除停牌时按 K 线新旧补判（主源数据一样公平）
        if (strategy.scope.excludeSuspended &&
            _suspendedByKline(k, strategy.kline.period)) {
          computed++;
          continue;
        }
        final data = KlineData(
          k.map((e) => e.open).toList(),
          k.map((e) => e.high).toList(),
          k.map((e) => e.low).toList(),
          k.map((e) => e.close).toList(),
          k.map((e) => e.vol).toList(),
          k.map((e) => e.time).toList(),
        );
        try {
          final desc = formula.evalSignal(data,
              mode: strategy.signal, recentN: strategy.recentN);
          if (desc != null) {
            picks.add(StockPick(
              code: stock.code,
              market: stock.market,
              name: stock.name,
              close: data.close.last,
              signalDesc: desc,
              klineTime: data.time.last,
            ));
          }
        } catch (_) {
          // 单只计算异常不中断任务
        }
        computed++;
        if (computed % 10 == 0 || computed == stocks.length) {
          _set(_progress.copyWith(computed: computed, hit: picks.length));
        }
      }

      // ⑤ 结果摘要落盘，原始 K 线全部释放删除（即用即删）
      final result = ScanResult(
        id: ResultStore.newId(),
        strategyId: strategy.id,
        strategyName: strategy.name,
        finishedAt: DateTime.now(),
        totalScanned: stocks.length,
        fetchFailed: _progress.failed,
        hitCount: picks.length,
        picks: picks,
      );
      await resultStore.save(result);
      clearCache();
      lastResult = result;
      _set(ScanProgress(status: ScanStatus.done));
      return result;
    } catch (e) {
      clearCache();
      _set(ScanProgress(status: ScanStatus.failed, error: '$e'));
      return null;
    }
  }
}
