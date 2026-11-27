/// 收益测算逻辑测试：buildReport / ReturnsReport。
import 'package:flutter_test/flutter_test.dart';
import 'package:stock_picker_app/analysis/returns.dart';
import 'package:stock_picker_app/models/models.dart';

void main() {
  StockPick pick(String code, double close) => StockPick(
      code: code,
      market: 'SZ',
      name: '股$code',
      close: close,
      signalDesc: '测试',
      klineTime: '2026-11-05');

  Kline bar(String time, double close) =>
      Kline(time, close, close, close, close, 1000);

  group('buildReport / ReturnsReport', () {
    test('正常：平均收益率、正收益占比、最高最低、最新时间', () {
      final picks = [pick('000001', 10.0), pick('000002', 20.0)];
      final latest = {
        '000001': [bar('2026-11-26', 11.0), bar('2026-11-27', 12.0)],
        '000002': [bar('2026-11-27', 18.0)],
      };
      final r = buildReport(picks, latest);
      expect(r.items.length, 2);
      expect(r.failedCodes, isEmpty);
      expect(r.latestTime, '2026-11-27');
      // 000001: (12-10)/10 = +20%；000002: (18-20)/20 = -10%
      expect(r.items[0].rate, closeTo(20.0, 1e-9));
      expect(r.items[1].rate, closeTo(-10.0, 1e-9));
      expect(r.average, closeTo(5.0, 1e-9));
      expect(r.positiveRate, closeTo(50.0, 1e-9));
      expect(r.best!.pick.code, '000001');
      expect(r.worst!.pick.code, '000002');
    });

    test('取数失败的标的不计入平均，计入 failedCodes', () {
      final picks = [pick('000001', 10.0), pick('000003', 30.0)];
      final latest = {
        '000001': [bar('2026-11-27', 12.0)],
      };
      final r = buildReport(picks, latest);
      expect(r.items.length, 1);
      expect(r.failedCodes, ['000003']);
      expect(r.average, closeTo(20.0, 1e-9), reason: '只按成功的 1 只平均');
    });

    test('空列表 / 全部失败：平均为 null 而非 0', () {
      expect(buildReport([], {}).average, isNull);
      final r = buildReport([pick('000001', 10.0)], {});
      expect(r.items, isEmpty);
      expect(r.failedCodes, ['000001']);
      expect(r.average, isNull);
      expect(r.positiveRate, isNull);
    });

    test('用户手动删除后：只统计当前列表内的标的', () {
      // 原始 5 只中剩 3 只的语义：buildReport 只看传入 picks
      final picks = [
        pick('000001', 10.0),
        pick('000002', 20.0),
        pick('000003', 30.0),
      ];
      final latest = {
        '000001': [bar('2026-11-27', 11.0)],
        '000002': [bar('2026-11-27', 22.0)],
        '000003': [bar('2026-11-27', 33.0)],
        '000004': [bar('2026-11-27', 44.0)], // 已删除的标的不应混入
      };
      final r = buildReport(picks, latest);
      expect(r.items.length, 3);
      expect(r.average, closeTo(10.0, 1e-9), reason: '三只均 +10%');
      expect(r.positiveRate, closeTo(100.0, 1e-9));
    });
  });
}
