/// AI 公式转换测试：OpenAI 兼容接口请求/错误处理 + 回复解析。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:stock_picker_app/ai/ai_converter.dart';

void main() {
  group('AiConverter.convert', () {
    http.Response okReply(String content) => http.Response.bytes(
        utf8.encode(jsonEncode({
          'choices': [
            {'message': {'content': content}}
          ]
        })),
        200);

    test('请求体含语法规范与原文，URL 归一化，返回模型回复', () async {
      String? capturedBody;
      String? capturedUrl;
      final client = MockClient((request) async {
        capturedBody = request.body;
        capturedUrl = request.url.toString();
        return okReply('说明：无\n```\nxg = cross(ma(close,5), ma(close,10))\n```');
      });
      final converter = AiConverter(
          baseUrl: 'https://api.test/v1/', // 尾斜杠应被去掉
          apiKey: 'sk-x',
          model: 'm1',
          client: client);
      final reply = await converter.convert(
          foreignCode: 'XG:CROSS(MA(C,5),MA(C,10));', syntaxGuide: '# 语法');
      expect(reply, contains('xg = cross'));
      expect(capturedUrl, 'https://api.test/v1/chat/completions');
      final sent = jsonDecode(capturedBody!) as Map<String, dynamic>;
      expect(sent['model'], 'm1');
      expect((sent['messages'] as List).length, 2);
      expect(sent.containsKey('temperature'), isFalse,
          reason: '首请求不带 temperature（兼容固定 temperature=1 的模型）');
      final sys = (sent['messages'] as List)[0]['content'] as String;
      expect(sys, contains('# 语法'), reason: '语法规范须进入 system 提示词');
      expect(sys, contains('语法规范开始'));
    });

    test('服务端报 temperature 错误时自动带 temperature=1 重试', () async {
      final bodies = <String>[];
      final client = MockClient((request) async {
        bodies.add(request.body);
        if (bodies.length == 1) {
          return http.Response.bytes(
              utf8.encode(jsonEncode({
                'error': {'message': 'invalid temperature: only 1 is allowed'}
              })),
              400);
        }
        return okReply('说明：无\n```\nxg = 1\n```');
      });
      final converter = AiConverter(
          baseUrl: 'https://api.test/v1',
          apiKey: 'sk-x',
          model: 'k3',
          client: client);
      final reply = await converter.convert(foreignCode: 'x', syntaxGuide: 'g');
      expect(reply, contains('xg = 1'));
      expect(bodies.length, 2, reason: '应重试一次');
      final retry = jsonDecode(bodies[1]) as Map<String, dynamic>;
      expect(retry['temperature'], 1);
    });

    test('密钥为空直接报错', () async {
      final converter = AiConverter(
          baseUrl: 'https://api.test/v1', apiKey: '', model: 'm');
      expect(
          converter.convert(foreignCode: 'x', syntaxGuide: 'g'),
          throwsA(predicate((e) =>
              e is AiConvertException && e.toString().contains('API 密钥'))));
    });

    test('401 返回密钥无效提示', () async {
      final client = MockClient((request) async => http.Response.bytes(
          utf8.encode(jsonEncode({
            'error': {'message': 'Invalid Authentication'}
          })),
          401));
      final converter = AiConverter(
          baseUrl: 'https://api.test/v1',
          apiKey: 'bad',
          model: 'm',
          client: client);
      expect(
          converter.convert(foreignCode: 'x', syntaxGuide: 'g'),
          throwsA(predicate((e) =>
              e is AiConvertException && e.toString().contains('密钥无效'))));
    });
  });

  group('extractCode / extractNote', () {
    test('提取 ``` 代码块（取最后一个）', () {
      final reply = '说明：无\n```\nma5 = ma(close, 5)\n```\n其他';
      expect(AiConverter.extractCode(reply), 'ma5 = ma(close, 5)');
    });

    test('无代码块时去掉说明行返回全文', () {
      final reply = '说明：近似改写\nxg = close > ref(close, 1)';
      expect(AiConverter.extractCode(reply), 'xg = close > ref(close, 1)');
    });

    test('提取说明行', () {
      expect(AiConverter.extractNote('说明：MA 参数保留\n```\nx```'), 'MA 参数保留');
      expect(AiConverter.extractNote('```\nx```'), '');
    });
  });
}
