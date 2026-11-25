/// AI 公式转换：把其他软件的选股公式/策略改写为本 APP 语法。
///
/// 通过 OpenAI 兼容的 /chat/completions 接口调用（Moonshot Kimi、
/// DeepSeek 等均兼容）。语法规范文档（assets/ai_syntax.md）随包内置，
/// 整体作为 system 提示词的一部分发给模型，保证改写结果可编译。
///
/// [convertWithFix] 在转换后用本机公式引擎编译校验：不通过则把编译
/// 报错原文回喂模型自我修正，最多 [maxFixRounds] 轮，只把编译通过的
/// 结果标记为 validated，避免把语法错误的公式直接交给用户。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../engine/formula.dart';

/// AI 调用失败。
class AiConvertException implements Exception {
  final String message;
  AiConvertException(this.message);
  @override
  String toString() => 'AI 转换失败：$message';
}

/// 转换模式：
/// - [rewrite]：把用户粘贴的其他软件公式改写为本 APP 语法（保留原逻辑参数）；
/// - [generate]：用户只用自然语言描述选股条件，AI 从零写出公式。
enum AiConvertMode { rewrite, generate }

/// convertWithFix 的结果。
class ConvertResult {
  /// 最终一轮模型的原始回复（含"说明："行与 ``` 代码块）。
  final String reply;

  /// 从 [reply] 提取出的公式代码。
  final String code;

  /// 共发起几轮转换/修正（1 = 首次即通过）。
  final int attempts;

  /// 最终代码是否通过本机公式引擎编译。
  final bool validated;

  /// 未通过时的编译错误原文（null 表示通过）。
  final String? compileError;

  const ConvertResult({
    required this.reply,
    required this.code,
    required this.attempts,
    required this.validated,
    this.compileError,
  });
}

/// OpenAI 兼容的公式转换客户端。
class AiConverter {
  final String baseUrl; // 形如 https://api.moonshot.cn/v1
  final String apiKey;
  final String model;
  final http.Client _client;

  AiConverter({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    http.Client? client,
  }) : _client = client ?? http.Client();

  /// 将 [foreignCode]（任意来源的公式/策略代码）改写为本 APP 公式。
  /// [syntaxGuide] 为 assets/ai_syntax.md 的全文。
  /// [mode] 为 generate 时，[foreignCode] 是自然语言描述而非已有公式。
  /// 返回模型原始回复（含"说明："行与 ``` 代码块）。
  Future<String> convert({
    required String foreignCode,
    required String syntaxGuide,
    AiConvertMode mode = AiConvertMode.rewrite,
  }) async {
    _checkConfig();
    if (foreignCode.trim().isEmpty) throw AiConvertException('请粘贴要转换的公式');
    return _chatWithTempFallback(
        _buildMessages(foreignCode, syntaxGuide, mode));
  }

  /// 转换 + 本机引擎编译校验 + 自动纠错。
  ///
  /// 流程：首次转换 → 提取代码用 [CompiledFormula.compile] 校验 →
  /// 失败则把编译报错回喂模型要求只修正代码块（保持原策略逻辑与参数），
  /// 最多 [maxFixRounds] 轮。返回最终结果，[ConvertResult.validated]
  /// 为 false 时 [ConvertResult.compileError] 是最后一轮的编译错误。
  ///
  /// [onRound] 在每轮修正发起前回调（round 从 1 计，total = maxFixRounds）。
  Future<ConvertResult> convertWithFix({
    required String foreignCode,
    required String syntaxGuide,
    AiConvertMode mode = AiConvertMode.rewrite,
    int maxFixRounds = 2,
    void Function(int round, int total)? onRound,
  }) async {
    _checkConfig();
    if (foreignCode.trim().isEmpty) throw AiConvertException('请粘贴要转换的公式');
    final messages = _buildMessages(foreignCode, syntaxGuide, mode);
    var attempts = 0;
    while (true) {
      attempts++;
      final reply = await _chatWithTempFallback(messages);
      final code = extractCode(reply);
      try {
        CompiledFormula.compile(code);
        return ConvertResult(
            reply: reply, code: code, attempts: attempts, validated: true);
      } on FormulaException catch (e) {
        if (attempts > maxFixRounds) {
          return ConvertResult(
            reply: reply,
            code: code,
            attempts: attempts,
            validated: false,
            compileError: e.toString(),
          );
        }
        onRound?.call(attempts, maxFixRounds);
        messages
          ..add({'role': 'assistant', 'content': reply})
          ..add({
            'role': 'user',
            'content': '你上一步给出的公式在本 APP 的公式引擎里编译报错：\n'
                '$e\n'
                '请修正代码块中的公式：只允许使用语法规范中列出的常量、函数与写法，'
                '保持原策略的逻辑与参数不变；修正后重新输出完整公式的 ``` 代码块。'
                '除代码块与"说明："行外不要输出任何内容。',
          });
      }
    }
  }

  /// 构造首轮对话消息：system（任务说明 + 语法规范）+ user（原文/需求描述）。
  List<Map<String, String>> _buildMessages(
      String foreignCode, String syntaxGuide, AiConvertMode mode) {
    final system = StringBuffer();
    if (mode == AiConvertMode.generate) {
      system
        ..writeln('用户会用自然语言描述他想要的选股条件（描述可能不完整、不精确，'
            '甚至只是大概意图，例如"底部放量""回踩 20 日线不破"）。')
        ..writeln('你的任务：直接为用户写出一个"tdx选股药丸"APP 的选股公式，'
            '满足用户描述的条件。必须严格遵守下方语法规范，只使用规范中列出的'
            '常量、函数与写法：')
        ..writeln()
        ..writeln('====语法规范开始====')
        ..write(syntaxGuide.trim())
        ..writeln()
        ..writeln('====语法规范结束====')
        ..writeln()
        ..writeln('输出要求：')
        ..writeln('1. 先写一行以"说明："开头的简短说明（公式逻辑、参数默认值取值），'
            '不超过 100 字。')
        ..writeln('2. 然后输出一个 ``` 包裹的代码块，代码块内是完整公式；除此之外不要输出任何内容。')
        ..writeln('3. 用户描述中明确的参数必须照用；未给出的参数取常见合理默认值'
            '（如均线周期 20、放量倍数 2、回踩容忍度 2%），并在"说明："中写明。');
    } else {
      system
        ..writeln('你是一名股票技术指标公式转换专家。用户会给你一段来自其他炒股软件'
            '（通达信、同花顺、大智慧、文华、聚宽、Python 量化代码等）的选股公式或策略代码。')
        ..writeln('请将其改写为"tdx选股药丸"APP 的选股公式。语法规范如下，'
            '必须严格遵守，只使用规范中列出的常量、函数与写法：')
        ..writeln()
        ..writeln('====语法规范开始====')
        ..write(syntaxGuide.trim())
        ..writeln()
        ..writeln('====语法规范结束====')
        ..writeln()
        ..writeln('输出要求：')
        ..writeln('1. 先写一行以"说明："开头的简短转换说明（等价改写、无法保留的功能等），'
            '不超过 100 字；没有需要说明的写"说明：无"。')
        ..writeln('2. 然后输出一个 ``` 包裹的代码块，代码块内是完整公式；除此之外不要输出任何内容。')
        ..writeln('3. 保留原策略的参数与逻辑含义，不要自行优化或添加新条件。');
    }

    return [
      {'role': 'system', 'content': system.toString()},
      {'role': 'user', 'content': foreignCode},
    ];
  }

  /// 连通测试：发送最小请求，返回模型回复内容；失败抛 [AiConvertException]。
  Future<String> ping() async {
    _checkConfig();
    final reply = await _chat(const [
      {'role': 'user', 'content': 'ping'}
    ], maxTokens: 8, temperature: 1);
    return reply.trim().isEmpty ? '连接成功' : reply.trim();
  }

  /// 配置预检：API 地址 / 密钥 / 模型缺一不可。
  void _checkConfig() {
    if (baseUrl.trim().isEmpty) {
      throw AiConvertException('未配置接口地址（设置页 → AI 公式转换 → 接口地址）');
    }
    if (apiKey.trim().isEmpty) {
      throw AiConvertException('未配置 API 密钥（设置页 → AI 公式转换）');
    }
    if (model.trim().isEmpty) {
      throw AiConvertException('未配置模型（设置页 → AI 公式转换 → 模型，'
          '如 kimi-for-coding / moonshot-v1-8k）');
    }
  }

  /// 发送 chat 请求；若服务端报 temperature 限制则带 temperature=1 重试一次。
  /// 注意：部分模型（如 Kimi 订阅版 k 系列）固定 temperature=1，
  /// 首请求不发 temperature。
  Future<String> _chatWithTempFallback(List<Map<String, String>> messages) async {
    try {
      return await _chat(messages);
    } on AiConvertException catch (e) {
      if (e.message.toLowerCase().contains('temperature')) {
        return await _chat(messages, temperature: 1);
      }
      rethrow;
    }
  }

  /// 发送一次 chat 请求并解析回复内容。
  Future<String> _chat(List<Map<String, String>> messages,
      {int? maxTokens, double? temperature}) async {
    _checkConfig();
    var base = baseUrl.trim();
    if (base.endsWith('/')) base = base.substring(0, base.length - 1);
    final uri = Uri.parse('$base/chat/completions');

    final payload = <String, dynamic>{
      'model': model,
      'messages': messages,
    };
    if (maxTokens != null) payload['max_tokens'] = maxTokens;
    if (temperature != null) payload['temperature'] = temperature;

    http.Response resp;
    try {
      resp = await _client
          .post(uri,
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $apiKey',
              },
              body: jsonEncode(payload))
          .timeout(const Duration(seconds: 180));
    } on TimeoutException {
      throw AiConvertException('请求超时（180 秒），请检查网络或稍后重试');
    } catch (e) {
      throw AiConvertException('网络错误（${uri.host}）：$e');
    }

    if (resp.statusCode != 200) {
      String detail = 'HTTP ${resp.statusCode}';
      try {
        final j = jsonDecode(resp.body) as Map<String, dynamic>;
        final err = j['error'];
        if (err is Map && err['message'] != null) detail = '${err['message']}';
      } catch (_) {}
      if (resp.statusCode == 401) detail = 'API 密钥无效或未授权（$detail）';
      throw AiConvertException(detail);
    }

    try {
      final j = jsonDecode(resp.body) as Map<String, dynamic>;
      final choices = j['choices'] as List?;
      final first = choices?.first as Map<String, dynamic>?;
      final msg = first?['message'] as Map<String, dynamic>?;
      final content = msg?['content']?.toString();
      if (content == null || content.trim().isEmpty) {
        throw AiConvertException('模型返回为空');
      }
      return content;
    } catch (e) {
      if (e is AiConvertException) rethrow;
      throw AiConvertException('返回解析失败：$e');
    }
  }

  /// 从模型回复中提取公式代码：优先取最后一个 ``` 代码块；
  /// 没有代码块时返回去除"说明："行后的全文。
  static String extractCode(String reply) {
    final blocks = RegExp(r'```[a-zA-Z]*\s*\n(.*?)```', dotAll: true)
        .allMatches(reply)
        .map((m) => m.group(1)!.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (blocks.isNotEmpty) return blocks.last;
    // 无代码块：逐行去掉"说明：…"行
    return reply
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('说明：'))
        .join('\n')
        .trim();
  }

  /// 从模型回复中提取"说明："行文本（无则返回空串）。
  static String extractNote(String reply) {
    for (final line in reply.split('\n')) {
      final t = line.trim();
      if (t.startsWith('说明：')) return t.substring(3).trim();
    }
    return '';
  }
}
