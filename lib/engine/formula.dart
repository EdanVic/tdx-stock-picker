/// Python 风格选股公式解析与求值（兼容通达信写法）。
///
/// 语法（Python 风格，默认）：
/// - 一行一条语句，用换行或 `;` 分隔；
/// - 赋值 `name = 表达式`；选股信号取最后一条语句（或显式的 xg 输出）；
/// - 序列常量：close/open/high/low/volume（别名 c/o/h/l/v，大小写不敏感）；
/// - 函数：ma/ema/sma/ref/llv/hhv/sum/count/cross/if/abs/max/min（小写）；
///   未来函数族：zig/ziga/peak/peakbars/trough/troughbars/backset/refx（见
///   [CompiledFormula.hasFutureFunctions]，含未来函数的策略会被标记警示）；
/// - 运算符：`+ - * /`、比较 `> < >= <= == !=`、逻辑 `and or not`；
/// - 兼容通达信写法：`NAME:=表达式` 赋值、`NAME:表达式` 输出、`AND/OR/NOT`、
///   `VOL`/`AMOUNT`、大写函数名均可；
/// - 不做跨周期引用。
library;

import 'functions.dart';

/// 公式语法错误。
class FormulaException implements Exception {
  final String message;
  final int position; // 字符位置，-1 表示未知
  FormulaException(this.message, [this.position = -1]);
  @override
  String toString() =>
      position >= 0 ? '公式错误(位置$position)：$message' : '公式错误：$message';
}

// ---------------------------------------------------------------------------
// 词法分析
// ---------------------------------------------------------------------------

enum _TokType { number, ident, op, eof }

class _Token {
  final _TokType type;
  final String text;
  final double num;
  final int pos;
  _Token(this.type, this.text, this.pos) : num = 0;
  _Token.number(this.text, this.pos) : type = _TokType.number, num = double.parse(text);
  @override
  String toString() => '$_TokType($text)';
}

List<_Token> _tokenize(String src) {
  final tokens = <_Token>[];
  var i = 0;
  bool isDigit(int c) => c >= 48 && c <= 57;
  // 标识符首字符：字母/下划线；后续字符可含数字（变量名支持数字，对齐语法文档）。
  // 数字打头的 token 已在上面的数字分支被消耗，不会进入标识符分支。
  bool isAlpha(int c) =>
      (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || c == 95 || isDigit(c);
  while (i < src.length) {
    final c = src.codeUnitAt(i);
    if (c == 32 || c == 9 || c == 13 || c == 10) {
      i++;
      continue;
    }
    if (isDigit(c) || (c == 46 && i + 1 < src.length && isDigit(src.codeUnitAt(i + 1)))) {
      final start = i;
      while (i < src.length) {
        final c2 = src.codeUnitAt(i);
        if (!isDigit(c2) && c2 != 46) break;
        i++;
      }
      // 科学计数法
      if (i < src.length && (src[i] == 'e' || src[i] == 'E')) {
        var j = i + 1;
        if (j < src.length && (src[j] == '+' || src[j] == '-')) j++;
        if (j < src.length && isDigit(src.codeUnitAt(j))) {
          i = j;
          while (i < src.length && isDigit(src.codeUnitAt(i))) i++;
        }
      }
      tokens.add(_Token.number(src.substring(start, i), start));
      continue;
    }
    if (isAlpha(c)) {
      final start = i;
      while (i < src.length && isAlpha(src.codeUnitAt(i))) i++;
      tokens.add(_Token(_TokType.ident, src.substring(start, i).toUpperCase(), start));
      continue;
    }
    final two = i + 1 < src.length ? src.substring(i, i + 2) : '';
    const twoOps = ['>=', '<=', '!=', '<>', '==', ':='];
    if (twoOps.contains(two)) {
      tokens.add(_Token(_TokType.op, two == '==' ? '=' : two, i));
      i += 2;
      continue;
    }
    // '=' 作为比较运算符出现（语句首的赋值已被 compile 的正则拆出，
    // 能进入表达式的 '=' 只可能是"等于"比较，语法文档承诺支持）
    const oneOps = '+-*/(),:<>=';
    if (oneOps.contains(src[i])) {
      tokens.add(_Token(_TokType.op, src[i], i));
      i++;
      continue;
    }
    throw FormulaException('无法识别的字符 "${src[i]}"', i);
  }
  tokens.add(_Token(_TokType.eof, '', src.length));
  return tokens;
}

// ---------------------------------------------------------------------------
// AST
// ---------------------------------------------------------------------------

abstract class _Node {
  const _Node();
}

class _NumNode extends _Node {
  final double value;
  const _NumNode(this.value);
}

class _SeriesNode extends _Node {
  final String name; // 常量（CLOSE 等）或已赋值变量名
  const _SeriesNode(this.name);
}

class _UnaryNode extends _Node {
  final String op; // '-' 或 'NOT'
  final _Node child;
  const _UnaryNode(this.op, this.child);
}

class _BinNode extends _Node {
  final String op; // + - * / > < >= <= = != AND OR
  final _Node left, right;
  const _BinNode(this.op, this.left, this.right);
}

class _FuncNode extends _Node {
  final String name;
  final List<_Node> args;
  const _FuncNode(this.name, this.args);
}

// ---------------------------------------------------------------------------
// 语法分析（递归下降）
// ---------------------------------------------------------------------------

class _Parser {
  final List<_Token> tokens;
  int idx = 0;
  _Parser(this.tokens);

  _Token get peek => tokens[idx];
  _Token next() => tokens[idx++];

  bool accept(String op) {
    if (peek.type == _TokType.op && peek.text == op) {
      idx++;
      return true;
    }
    return false;
  }

  void expect(String op) {
    if (!accept(op)) {
      throw FormulaException('期望 "$op"，遇到 "${peek.text.isEmpty ? "结尾" : peek.text}"',
          peek.pos);
    }
  }

  _Node parseExpr() => _parseOr();

  _Node _parseOr() {
    var node = _parseAnd();
    while (true) {
      if (peek.type == _TokType.ident && peek.text == 'OR') {
        next();
        node = _BinNode('OR', node, _parseAnd());
      } else if (accept('|')) {
        node = _BinNode('OR', node, _parseAnd());
      } else {
        return node;
      }
    }
  }

  _Node _parseAnd() {
    var node = _parseCmp();
    while (true) {
      if (peek.type == _TokType.ident && peek.text == 'AND') {
        next();
        node = _BinNode('AND', node, _parseCmp());
      } else if (accept('&')) {
        node = _BinNode('AND', node, _parseCmp());
      } else {
        return node;
      }
    }
  }

  static const _cmpOps = {'>', '<', '>=', '<=', '=', '!='};

  _Node _parseCmp() {
    var node = _parseAdd();
    if (peek.type == _TokType.op && _cmpOps.contains(peek.text)) {
      final op = next().text;
      node = _BinNode(op == '<>' ? '!=' : op, node, _parseAdd());
    }
    return node;
  }

  _Node _parseAdd() {
    var node = _parseMul();
    while (peek.type == _TokType.op && (peek.text == '+' || peek.text == '-')) {
      final op = next().text;
      node = _BinNode(op, node, _parseMul());
    }
    return node;
  }

  _Node _parseMul() {
    var node = _parseUnary();
    while (peek.type == _TokType.op && (peek.text == '*' || peek.text == '/')) {
      final op = next().text;
      node = _BinNode(op, node, _parseUnary());
    }
    return node;
  }

  _Node _parseUnary() {
    if (accept('-')) return _UnaryNode('-', _parseUnary());
    if (peek.type == _TokType.ident && peek.text == 'NOT') {
      next();
      return _UnaryNode('NOT', _parseUnary());
    }
    return _parsePrimary();
  }

  static const _seriesConsts = {'CLOSE', 'OPEN', 'HIGH', 'LOW', 'VOL', 'AMOUNT',
      'C', 'O', 'H', 'L', 'V'};

  _Node _parsePrimary() {
    final t = peek;
    if (t.type == _TokType.number) {
      next();
      return _NumNode(t.num);
    }
    if (accept('(')) {
      final node = parseExpr();
      expect(')');
      return node;
    }
    if (t.type == _TokType.ident) {
      next();
      if (accept('(')) {
        final args = <_Node>[];
        if (!accept(')')) {
          args.add(parseExpr());
          while (accept(',')) {
            args.add(parseExpr());
          }
          expect(')');
        }
        return _FuncNode(t.text, args);
      }
      if (_seriesConsts.contains(t.text)) return _SeriesNode(t.text);
      return _SeriesNode(t.text); // 可能是已赋值变量，求值时再校验
    }
    throw FormulaException('意外的符号 "${t.text.isEmpty ? "结尾" : t.text}"', t.pos);
  }
}

// ---------------------------------------------------------------------------
// 语句与公式
// ---------------------------------------------------------------------------

class _Statement {
  final String name;
  final bool isOutput;
  final _Node expr;
  _Statement(this.name, this.isOutput, this.expr);
}

/// 解析后的选股公式。可复用：对每只股票调用 [evalSignal]。
class CompiledFormula {
  final String source;
  final List<_Statement> statements;
  CompiledFormula._(this.source, this.statements);

  /// 输出语句的变量名（选股信号取最后一个）。
  List<String> get outputs =>
      statements.where((s) => s.isOutput).map((s) => s.name).toList();

  /// 解析公式文本。空公式报错；无显式输出（`:`）时取最后一条语句为信号。
  static CompiledFormula compile(String source) {
    final statements = <_Statement>[];
    // 按 ; 或换行切分语句
    final raw = source.replaceAll('\r', '').split(RegExp(r'[;\n]'));
    for (var rawStmt in raw) {
      final stmt = rawStmt.trim();
      if (stmt.isEmpty) continue;
      // 兼容三种赋值形式：Python `=`、通达信 `:=` 与输出 `:`
      final m = RegExp(r'^([A-Za-z_][A-Za-z0-9_]*)\s*(:=|:|=)\s*(.+)$')
          .firstMatch(stmt);
      if (m == null) {
        throw FormulaException(
            '语句 "$stmt" 不是合法赋值（name = 表达式）或输出（NAME:表达式）');
      }
      final name = m.group(1)!.toUpperCase();
      final isOutput = m.group(2) == ':';
      final exprSrc = m.group(3)!;
      final parser = _Parser(_tokenize(exprSrc));
      final expr = parser.parseExpr();
      if (parser.peek.type != _TokType.eof) {
        throw FormulaException('表达式末尾有多余内容 "${parser.peek.text}"',
            parser.peek.pos);
      }
      statements.add(_Statement(name, isOutput, expr));
    }
    if (statements.isEmpty) {
      throw FormulaException('公式为空');
    }
    // Python 风格：无显式 `:` 输出时，最后一条语句即为选股信号
    if (!statements.any((s) => s.isOutput)) {
      statements[statements.length - 1] = _Statement(
          statements.last.name, true, statements.last.expr);
    }
    // 语义校验：函数名、参数个数、变量引用必须在编译期可判定
    final defined = <String>{
      'CLOSE', 'OPEN', 'HIGH', 'LOW', 'VOL', 'VOLUME', 'AMOUNT',
      'C', 'O', 'H', 'L', 'V',
    };
    for (final stmt in statements) {
      _validate(stmt.expr, defined);
      defined.add(stmt.name);
    }
    return CompiledFormula._(source, statements);
  }

  static const _knownFuncs = {
    'MA': 2, 'EMA': 2, 'SMA': 3, 'REF': 2, 'LLV': 2, 'HHV': 2,
    'SUM': 2, 'COUNT': 2, 'BARSLAST': 1, 'ABS': 1, 'MAX': 2, 'MIN': 2,
    'IF': 3, 'CROSS': 2,
    // 未来函数族（语义对齐通达信官方说明，见 functions.dart）
    'ZIG': 2, 'ZIGA': 2, 'BACKSET': 2, 'REFX': 2,
    'PEAK': 3, 'PEAKBARS': 3, 'TROUGH': 3, 'TROUGHBARS': 3,
    // 信号去抖（非未来函数）
    'FILTER': 2,
  };

  /// 未来函数名单：这些函数会引用未来数据，信号可能漂移/重绘。
  static const _futureFuncs = {
    'ZIG', 'ZIGA', 'BACKSET', 'REFX', 'PEAK', 'PEAKBARS', 'TROUGH', 'TROUGHBARS',
  };

  /// 本公式是否使用了未来函数（含 ref(x, -n) 负偏移引用未来）。
  late final bool hasFutureFunctions = _detectFuture(statements);

  static bool _detectFuture(List<_Statement> stmts) {
    bool walk(_Node n) {
      if (n is _FuncNode) {
        if (_futureFuncs.contains(n.name)) return true;
        // REF/REFX 的第二参数为负常量 → 引用未来
        if ((n.name == 'REF' || n.name == 'REFX') &&
            n.args.length == 2 &&
            _constNum(n.args[1]) != null &&
            _constNum(n.args[1])! < 0) {
          return true;
        }
        return n.args.any(walk);
      }
      if (n is _UnaryNode) return walk(n.child);
      if (n is _BinNode) return walk(n.left) || walk(n.right);
      return false;
    }

    return stmts.any((s) => walk(s.expr));
  }

  /// 取数字字面量常量（含一元负号），非常量返回 null。
  static double? _constNum(_Node n) {
    if (n is _NumNode) return n.value;
    if (n is _UnaryNode && n.op == '-' && n.child is _NumNode) {
      return -(n.child as _NumNode).value;
    }
    return null;
  }

  static void _validate(_Node node, Set<String> defined) {
    if (node is _SeriesNode) {
      if (!defined.contains(node.name)) {
        throw FormulaException('未定义的变量或常量 "${node.name}"');
      }
    } else if (node is _UnaryNode) {
      _validate(node.child, defined);
    } else if (node is _BinNode) {
      _validate(node.left, defined);
      _validate(node.right, defined);
    } else if (node is _FuncNode) {
      final arity = _knownFuncs[node.name];
      if (arity == null) {
        throw FormulaException('不支持的函数 "${node.name}"');
      }
      if (node.args.length != arity) {
        throw FormulaException(
            '函数 ${node.name} 需要 $arity 个参数，实际 ${node.args.length} 个');
      }
      for (final a in node.args) {
        _validate(a, defined);
      }
    }
  }
}

// ---------------------------------------------------------------------------
// 求值上下文与求值器
// ---------------------------------------------------------------------------

/// 单只股票的 K 线数据（按时间升序）。
class KlineData {
  final List<double> open, high, low, close, vol;
  final List<String> time;
  KlineData(this.open, this.high, this.low, this.close, this.vol, this.time);
  int get length => close.length;
}

/// 求值过程中的环境：序列常量 + 已赋值变量。
class _EvalContext {
  final KlineData k;
  final env = <String, List<double>>{};

  _EvalContext(this.k) {
    env['CLOSE'] = k.close;
    env['C'] = k.close;
    env['OPEN'] = k.open;
    env['O'] = k.open;
    env['HIGH'] = k.high;
    env['H'] = k.high;
    env['LOW'] = k.low;
    env['L'] = k.low;
    env['VOL'] = k.vol;
    env['V'] = k.vol;
    env['VOLUME'] = k.vol;
  }

  List<double> lookup(String name) {
    final v = env[name];
    if (v == null) {
      throw FormulaException('未定义的变量或常量 "$name"');
    }
    return v;
  }
}

extension CompiledFormulaEval on CompiledFormula {
  /// 对单只股票求值，返回所有输出序列（key 为输出变量名）。
  Map<String, List<double>> eval(KlineData k) {
    final ctx = _EvalContext(k);
    for (final stmt in statements) {
      ctx.env[stmt.name] = _evalNode(stmt.expr, ctx);
    }
    final out = <String, List<double>>{};
    for (final stmt in statements) {
      if (stmt.isOutput) out[stmt.name] = ctx.env[stmt.name]!;
    }
    return out;
  }

  /// 选股判定：
  /// - mode = LAST_BAR：最后一根输出为 1；
  /// - mode = RECENT_N(n)：最近 n 根内存在 1。
  /// 返回 null 表示不触发，否则返回触发说明。
  String? evalSignal(KlineData k,
      {String mode = 'LAST_BAR', int recentN = 3}) {
    final outputs = eval(k);
    final sig = outputs[outputs.keys.last]!;
    bool hit;
    String desc;
    if (mode == 'RECENT_N') {
      final start = sig.length > recentN ? sig.length - recentN : 0;
      var found = -1;
      for (var i = sig.length - 1; i >= start; i--) {
        if (sig[i] == 1) {
          found = i;
          break;
        }
      }
      hit = found >= 0;
      desc = hit ? '最近$recentN根内第${sig.length - found}根触发' : '';
    } else {
      hit = sig.isNotEmpty && sig[sig.length - 1] == 1;
      desc = hit ? '最后一根触发' : '';
    }
    return hit ? desc : null;
  }

  List<double> _evalNode(_Node node, _EvalContext ctx) {
    if (node is _NumNode) {
      return List<double>.filled(ctx.k.length, node.value);
    }
    if (node is _SeriesNode) {
      final s = ctx.lookup(node.name);
      return s;
    }
    if (node is _UnaryNode) {
      final c = _evalNode(node.child, ctx);
      if (node.op == '-') {
        return c.map((v) => v.isNaN ? v : -v).toList();
      }
      // NOT
      return c
          .map((v) => v.isNaN ? 0.0 : (v == 0 ? 1.0 : 0.0))
          .toList();
    }
    if (node is _BinNode) {
      final a = _evalNode(node.left, ctx);
      final b = _evalNode(node.right, ctx);
      return _applyBin(node.op, a, b);
    }
    if (node is _FuncNode) {
      final args = node.args.map((e) => _evalNode(e, ctx)).toList();
      return _applyFunc(node.name, args, node.args, ctx);
    }
    throw FormulaException('内部错误：未知节点');
  }

  List<double> _applyBin(String op, List<double> a, List<double> b) {
    final len = a.length;
    List<double> out = List<double>.filled(len, kNaN);
    double bv(int i) => b.length == len ? b[i] : b[b.length - 1];
    bool valid(double v) => !v.isNaN;
    for (var i = 0; i < len; i++) {
      final x = a[i];
      final y = bv(i);
      switch (op) {
        case '+':
          if (valid(x) && valid(y)) out[i] = x + y;
        case '-':
          if (valid(x) && valid(y)) out[i] = x - y;
        case '*':
          if (valid(x) && valid(y)) out[i] = x * y;
        case '/':
          if (valid(x) && valid(y)) out[i] = y == 0 ? kNaN : x / y;
        case '>':
          if (valid(x) && valid(y)) out[i] = x > y ? 1 : 0;
        case '<':
          if (valid(x) && valid(y)) out[i] = x < y ? 1 : 0;
        case '>=':
          if (valid(x) && valid(y)) out[i] = x >= y ? 1 : 0;
        case '<=':
          if (valid(x) && valid(y)) out[i] = x <= y ? 1 : 0;
        case '=':
          if (valid(x) && valid(y)) out[i] = x == y ? 1 : 0;
        case '!=':
          if (valid(x) && valid(y)) out[i] = x != y ? 1 : 0;
        case 'AND':
          out[i] = (x != 0 && valid(x)) && (y != 0 && valid(y)) ? 1 : 0;
        case 'OR':
          out[i] = (x != 0 && valid(x)) || (y != 0 && valid(y)) ? 1 : 0;
        default:
          throw FormulaException('不支持的运算符 "$op"');
      }
    }
    return out;
  }

  /// 提取整数参数（如 MA(C,20) 中的 20）。参数须为数字字面量（允许负号）。
  int _intArg(List<_Node> argNodes, List<List<double>> args, int i) {
    final v = _numArg(argNodes, args, i);
    if (v == v.roundToDouble()) return v.toInt();
    throw FormulaException('第 ${i + 1} 个参数必须是整数常量');
  }

  /// 提取数值常量参数（如 ZIG(C,5) 中的 5，允许小数与负号）。
  double _numArg(List<_Node> argNodes, List<List<double>> args, int i) {
    final v = CompiledFormula._constNum(argNodes[i]);
    if (v != null) return v;
    throw FormulaException('第 ${i + 1} 个参数必须是数字常量');
  }

  List<double> _applyFunc(
      String name, List<List<double>> args, List<_Node> argNodes, _EvalContext ctx) {
    List<double> s(int i) => args[i];
    switch (name) {
      case 'MA':
        return MA(s(0), _intArg(argNodes, args, 1));
      case 'EMA':
        return EMA(s(0), _intArg(argNodes, args, 1));
      case 'SMA':
        return SMA(s(0), _intArg(argNodes, args, 1), _intArg(argNodes, args, 2));
      case 'REF':
        return REF(s(0), _intArg(argNodes, args, 1));
      case 'LLV':
        return LLV(s(0), _intArg(argNodes, args, 1));
      case 'HHV':
        return HHV(s(0), _intArg(argNodes, args, 1));
      case 'SUM':
        return SUM(s(0), _intArg(argNodes, args, 1));
      case 'COUNT':
        return COUNT(s(0), _intArg(argNodes, args, 1));
      case 'BARSLAST':
        return BARSLAST(s(0));
      case 'ABS':
        return ABS(s(0));
      case 'MAX':
        return MAX(s(0), s(1));
      case 'MIN':
        return MIN(s(0), s(1));
      case 'IF':
        return IFF(s(0), s(1), s(2));
      case 'CROSS':
        return CROSS(s(0), s(1));
      case 'ZIG':
        return ZIG(s(0), _numArg(argNodes, args, 1));
      case 'ZIGA':
        return ZIGA(s(0), _numArg(argNodes, args, 1));
      case 'PEAK':
        return PEAK(s(0), _numArg(argNodes, args, 1), _intArg(argNodes, args, 2));
      case 'PEAKBARS':
        return PEAKBARS(s(0), _numArg(argNodes, args, 1), _intArg(argNodes, args, 2));
      case 'TROUGH':
        return TROUGH(s(0), _numArg(argNodes, args, 1), _intArg(argNodes, args, 2));
      case 'TROUGHBARS':
        return TROUGHBARS(s(0), _numArg(argNodes, args, 1), _intArg(argNodes, args, 2));
      case 'BACKSET':
        return BACKSET(s(0), _intArg(argNodes, args, 1));
      case 'FILTER':
        return FILTER(s(0), _intArg(argNodes, args, 1));
      case 'REFX':
        return REF(s(0), -_intArg(argNodes, args, 1));
      case 'MACD':
        // MACD.DIF / MACD.DEA / MACD.MACD 形态不支持，提供便捷函数无意义，报错提示
        throw FormulaException(
            '请按 DIF:=EMA(CLOSE,12)-EMA(CLOSE,26);DEA:=EMA(DIF,9); 方式书写 MACD');
      default:
        throw FormulaException('不支持的函数 "$name"');
    }
  }
}
