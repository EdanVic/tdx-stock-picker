/// 策略收益测算：以选股时的信号收盘价为基准，计算到最新行情的收益率。
///
/// 纯逻辑模块（零 UI 依赖），行情拉取由 UI 层完成后喂给 [buildReport]。
library;

import '../models/models.dart';

/// 单只标的的收益。
class PickReturn {
  final StockPick pick;
  final double baseClose; // 选股信号 K 线收盘价（基准）
  final double latestClose; // 最新日线收盘价（盘中为实时价）
  final String latestTime; // 最新 K 线时间

  const PickReturn({
    required this.pick,
    required this.baseClose,
    required this.latestClose,
    required this.latestTime,
  });

  /// 收益率（%）。基准价为 0 时返回 NaN（数据异常）。
  double get rate => baseClose > 0
      ? (latestClose - baseClose) / baseClose * 100
      : double.nan;
}

/// 一批标的的收益统计。
class ReturnsReport {
  /// 取数成功、已计算收益的标的。
  final List<PickReturn> items;

  /// 取数失败的标的代码（未计入平均）。
  final List<String> failedCodes;

  /// 最新行情时间（各标的最新 K 线时间的最大值，通常相同）。
  final String latestTime;

  const ReturnsReport({
    required this.items,
    required this.failedCodes,
    required this.latestTime,
  });

  /// 平均收益率（%）；无有效标的时为 null。
  double? get average {
    if (items.isEmpty) return null;
    final valid = items.map((e) => e.rate).where((r) => !r.isNaN);
    if (valid.isEmpty) return null;
    return valid.reduce((a, b) => a + b) / valid.length;
  }

  /// 正收益占比（%）；无有效标的时为 null。
  double? get positiveRate {
    if (items.isEmpty) return null;
    final wins = items.where((e) => e.rate > 0).length;
    return wins / items.length * 100;
  }

  /// 最高/最低收益率标的（无有效标的时为 null）。
  PickReturn? get best => items.isEmpty
      ? null
      : items.reduce((a, b) => a.rate >= b.rate ? a : b);
  PickReturn? get worst => items.isEmpty
      ? null
      : items.reduce((a, b) => a.rate <= b.rate ? a : b);
}

/// 由「最新 K 线」映射构建统计报告。
///
/// [picks] 为当前列表（用户可能已手动删除过标的），只统计这些股票；
/// [latest] 为 code → 最近几根日 K（取最后一根为最新价），取数失败的不在
/// 映射中，计入 failedCodes。
ReturnsReport buildReport(
  List<StockPick> picks,
  Map<String, List<Kline>> latest,
) {
  final items = <PickReturn>[];
  final failed = <String>[];
  var latestTime = '';
  for (final p in picks) {
    final k = latest[p.code];
    if (k == null || k.isEmpty) {
      failed.add(p.code);
      continue;
    }
    final last = k.last;
    items.add(PickReturn(
      pick: p,
      baseClose: p.close,
      latestClose: last.close,
      latestTime: last.time,
    ));
    if (last.time.compareTo(latestTime) > 0) latestTime = last.time;
  }
  return ReturnsReport(
      items: items, failedCodes: failed, latestTime: latestTime);
}
