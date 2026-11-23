/// 行情网关测试：股票列表翻页取全（东财单页最多返回 100 条）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:stock_picker_app/quote/quote_provider.dart';

void main() {
  group('EastMoneyProvider.fetchStockList 翻页', () {
    String body(List<Map<String, Object?>> items, int total) =>
        jsonEncode({'data': {'total': total, 'diff': items}});

    test('单页未取全时按 total 翻页并去重', () async {
      final page1 = List.generate(
          2, (i) => {'f12': '30000$i', 'f14': '股票$i', 'f2': 10.0});
      final page2 = [
        {'f12': '300001', 'f14': '股票1', 'f2': 10.0}, // 与第一页重复
        {'f12': '300002', 'f14': '*ST测试', 'f2': '-'}, // ST + 停牌
        {'f12': '300003', 'f14': '正常股', 'f2': 5.5},
      ];
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        if (calls == 1) return http.Response.bytes(utf8.encode(body(page1, 4)), 200);
        return http.Response.bytes(utf8.encode(body(page2, 4)), 200);
      });
      final list = await EastMoneyProvider(client).fetchStockList({'CYB'});
      expect(calls, 2, reason: 'total=4 未取全应翻第 2 页');
      expect(list.length, 4, reason: '300001 重复应去重');
      expect(list.firstWhere((s) => s.code == '300002').isST, isTrue);
      expect(list.firstWhere((s) => s.code == '300002').isSuspended, isTrue);
      expect(list.firstWhere((s) => s.code == '300003').isSuspended, isFalse);
    });

    test('单页取全时不发多余请求', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        return http.Response.bytes(
            utf8.encode(body([{'f12': '300001', 'f14': '甲', 'f2': 1.0}], 1)),
            200);
      });
      final list = await EastMoneyProvider(client).fetchStockList({'CYB'});
      expect(calls, 1);
      expect(list.length, 1);
    });

    test('空板块返回空列表', () async {
      final client = MockClient((request) async => http.Response('{}', 200));
      final list = await EastMoneyProvider(client).fetchStockList({});
      expect(list, isEmpty);
    });
  });
}
