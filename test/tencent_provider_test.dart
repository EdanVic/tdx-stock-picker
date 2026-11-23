/// 腾讯行情 provider 测试：列表板块过滤/翻页、日周 K 行格式、分钟 K 时间戳。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:stock_picker_app/models/models.dart';
import 'package:stock_picker_app/quote/quote_provider.dart';
import 'package:stock_picker_app/quote/tencent_provider.dart';

StockInfo stock(String code) =>
    StockInfo(code: code, market: 'SZ', name: '测试', isST: false);

/// 可控成功/失败的假数据源，用于多源切换测试。
class FakeProvider implements QuoteProvider {
  final String label;
  int klineCalls = 0;
  int listCalls = 0;
  bool failKline = false;
  bool failList = false;
  FakeProvider(this.label);

  @override
  String get name => label;

  @override
  Future<List<StockInfo>> fetchStockList(Set<String> boards) async {
    listCalls++;
    if (failList) throw QuoteException('$label 列表失败');
    return [
      StockInfo(
          code: boards.contains('KCB') ? '688001' : '300750',
          market: 'SH',
          name: label,
          isST: false)
    ];
  }

  @override
  Future<List<Kline>> fetchKline(
      StockInfo stock, String period, int count) async {
    klineCalls++;
    if (failKline) throw QuoteException('$label K线失败');
    return [Kline('2026-11-20', 1, 2, 3, 4, 5)];
  }
}

void main() {
  group('TencentProvider.fetchStockList', () {
    http.Response rankBody(List<Map<String, Object?>> items, int total) =>
        http.Response.bytes(
            utf8.encode(jsonEncode({
              'code': 0,
              'data': {'total': total, 'rank_list': items}
            })),
            200);

    test('按板块前缀过滤（CYB 只留 sz30）并翻页取全', () async {
      final page1 = [
        {'code': 'sh600519', 'name': '贵州茅台'},
        {'code': 'sz000001', 'name': '平安银行'},
        {'code': 'sz300750', 'name': '宁德时代'},
      ];
      final page2 = [
        {'code': 'sz300001', 'name': '特锐德'},
        {'code': 'sz300750', 'name': '宁德时代'}, // 重复应去重
      ];
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        // offset=0 第 1 页，offset=3 第 2 页
        return calls == 1 ? rankBody(page1, 5) : rankBody(page2, 5);
      });
      final list =
          await TencentProvider(client).fetchStockList({'CYB', 'SH_MAIN'});
      expect(calls, 2, reason: 'total=5 未取全应翻页');
      expect(list.length, 3, reason: 'SH_MAIN 留 sh60、CYB 留 sz30、去重后 3 只');
      expect(list.any((s) => s.code == '300750'), isTrue);
      expect(list.any((s) => s.code == '600519'), isTrue);
      expect(list.any((s) => s.code == '000001'), isFalse);
    });

    test('ST 名称标记', () async {
      final client = MockClient((request) async => rankBody(
          [{'code': 'sz300002', 'name': '*ST测试'}], 1));
      final list = await TencentProvider(client).fetchStockList({'CYB'});
      expect(list.single.isST, isTrue);
    });

    test('不支持的板块（科创板/北交所）抛 QuoteException', () async {
      final client = MockClient((request) async => rankBody([], 0));
      expect(TencentProvider(client).fetchStockList({'KCB'}),
          throwsA(isA<QuoteException>()));
    });
  });

  group('TencentProvider.fetchKline', () {
    test('日线：qfqday 行格式 [date,open,close,high,low,vol]，close 在第 3 位',
        () async {
      // 真实腾讯行：开盘 10，收盘 12，最高 13，最低 9，量 1000
      final body = jsonEncode({
        'code': 0,
        'data': {
          'sz300750': {
            'qfqday': [
              ['2026-11-20', '10', '12', '13', '9', '1000'],
            ]
          }
        }
      });
      final client = MockClient((request) async =>
          http.Response.bytes(utf8.encode(body), 200));
      final k = await TencentProvider(client)
          .fetchKline(stock('300750'), 'day', 140);
      expect(k.length, 1);
      expect(k.single.open, 10);
      expect(k.single.close, 12, reason: 'close 在行内第 3 位');
      expect(k.single.high, 13);
      expect(k.single.low, 9);
      expect(k.single.vol, 1000);
      expect(k.single.time, '2026-11-20');
    });

    test('分钟线：12 位时间戳转换为 YYYY-MM-DD HH:MM', () async {
      final body = jsonEncode({
        'code': 0,
        'data': {
          'sz300750': {
            'm60': [
              ['202611211500', '10', '11', '12', '9', '5000'],
            ]
          }
        }
      });
      final client = MockClient((request) async =>
          http.Response.bytes(utf8.encode(body), 200));
      final k = await TencentProvider(client)
          .fetchKline(stock('300750'), 'm60', 140);
      expect(k.single.time, '2026-11-21 15:00');
      expect(k.single.close, 11);
      expect(k.single.high, 12);
    });

    test('无数据时返回空列表而非抛错', () async {
      final client = MockClient((request) async =>
          http.Response.bytes(utf8.encode(jsonEncode({'code': 0, 'data': {}})), 200));
      final k = await TencentProvider(client)
          .fetchKline(stock('300750'), 'day', 140);
      expect(k, isEmpty);
    });
  });

  group('MultiSourceProvider', () {
    test('主源 K 线失败自动降级备用源', () async {
      final a = FakeProvider('主')..failKline = true;
      final b = FakeProvider('备');
      final p = MultiSourceProvider(a, b, circuitThreshold: 5);
      final k = await p.fetchKline(stock('300750'), 'day', 10);
      expect(k.single.open, 1);
      expect(b.klineCalls, 1, reason: '主源失败应由备用源接管');
    });

    test('主源连续失败达到阈值后熔断，冷却期内直接走备用源', () async {
      final a = FakeProvider('主')..failKline = true;
      final b = FakeProvider('备');
      final p = MultiSourceProvider(a, b,
          circuitThreshold: 3, circuitCooldown: const Duration(minutes: 5));
      for (var i = 0; i < 5; i++) {
        await p.fetchKline(stock('300750'), 'day', 10);
      }
      final callsAfterTrip = a.klineCalls;
      await p.fetchKline(stock('300750'), 'day', 10);
      expect(a.klineCalls, callsAfterTrip,
          reason: '熔断后主源不应再被调用');
    });

    test('科创板列表固定走备用源，其余板块走主源', () async {
      final a = FakeProvider('主');
      final b = FakeProvider('备');
      final p = MultiSourceProvider(a, b);
      final list = await p.fetchStockList({'CYB', 'KCB'});
      expect(a.listCalls, 1);
      expect(b.listCalls, 1);
      expect(list.length, 2, reason: 'CYB 来自主源、KCB 来自备用源');
      expect(list.any((s) => s.code == '688001'), isTrue);
    });

    test('主源列表整段失败时整段交备用源', () async {
      final a = FakeProvider('主')..failList = true;
      final b = FakeProvider('备');
      final p = MultiSourceProvider(a, b);
      final list = await p.fetchStockList({'CYB'});
      expect(list.single.name, '备');
    });
  });
}
