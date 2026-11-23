/// 公式引擎基准测试：函数语义与解析求值。
/// 数值用例为手工推导值，语义对齐 MyTT / 通达信定义。
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:stock_picker_app/engine/formula.dart';
import 'package:stock_picker_app/engine/functions.dart';

const eps = 1e-9;

void expectClose(double actual, double expected, [String? msg]) {
  if (expected.isNaN) {
    expect(actual.isNaN, isTrue, reason: msg);
  } else {
    expect(actual, closeTo(expected, 1e-6), reason: msg);
  }
}

void main() {
  group('基础函数（对齐 MyTT 语义）', () {
    final c = <double>[1.0, 2, 3, 4, 5];

    test('MA 窗口未满为 NaN', () {
      final ma = MA(c, 3);
      expectClose(ma[0], double.nan);
      expectClose(ma[1], double.nan);
      expectClose(ma[2], 2.0);
      expectClose(ma[4], 4.0);
    });

    test('EMA span=N adjust=False：alpha=2/(N+1)', () {
      final e = EMA(c, 3);
      expectClose(e[0], 1.0);
      expectClose(e[1], 1.5);
      expectClose(e[2], 2.25);
      expectClose(e[3], 3.125);
      expectClose(e[4], 4.0625);
    });

    test('SMA(X,3,1) 通达信递推：alpha=1/3', () {
      final s = SMA(c, 3, 1);
      expectClose(s[0], 1.0);
      expectClose(s[1], 4 / 3);
      expectClose(s[2], 17 / 9);
      expectClose(s[3], 70 / 27);
    });

    test('REF 右移 N 位头部补 NaN', () {
      final r = REF(c, 2);
      expectClose(r[0], double.nan);
      expectClose(r[1], double.nan);
      expectClose(r[2], 1.0);
      expectClose(r[4], 3.0);
    });

    test('LLV / HHV / SUM', () {
      expectClose(LLV(c, 3)[1], double.nan);
      expectClose(LLV(c, 3)[2], 1.0);
      expectClose(LLV(c, 3)[4], 3.0);
      expectClose(HHV(c, 3)[4], 5.0);
      expectClose(SUM(c, 3)[2], 6.0);
      expectClose(SUM(c, 3)[4], 12.0);
    });

    test('COUNT 统计非零天数', () {
      final cond = <double>[0.0, 1, 0, 1, 1];
      final cnt = COUNT(cond, 3);
      expectClose(cnt[2], 1.0);
      expectClose(cnt[4], 2.0);
    });

    test('CROSS：A 上穿 B（严格定义）', () {
      final a = <double>[1.0, 2, 1, 2, 2];
      final b = <double>[2.0, 1, 1, 1, 2];
      final x = CROSS(a, b);
      expect(x[0], 0, reason: 'i=0 无上根可比');
      expect(x[1], 1, reason: 'i=1: 2>1 且前一根 1<=2');
      expect(x[2], 0, reason: 'i=2: 1>1 不成立');
      expect(x[3], 1, reason: 'i=3: 2>1 且前一根 1<=1');
      expect(x[4], 0, reason: 'i=4: 2>2 不成立');
    });
  });

  group('MACD / KDJ', () {
    test('MACD 数值', () {
      final close = List<double>.generate(60, (i) => 10 + (i % 7) * 0.5);
      final m = MACD(close);
      expect(m.dif.length, 60);
      expect(m.dea.length, 60);
      expect(m.macd.length, 60);
      expect(m.dif[0], closeTo(0.0, eps));
      expectClose(m.macd[30], 2 * (m.dif[30] - m.dea[30]));
    });

    test('KDJ 边界：HHV==LLV 时 RSV 为 NaN', () {
      final flat = List<double>.filled(20, 5.0);
      final kdj = KDJ(flat, flat, flat);
      expect(kdj.k[8].isNaN || kdj.k[8] == 0, isTrue);
    });
  });

  group('公式解析与求值（计划书 7.3 基准公式）', () {
    KlineData makeKline(List<double> closes) {
      final n = closes.length;
      return KlineData(
        List<double>.filled(n, 0),
        List<double>.from(closes),
        List<double>.filled(n, 0),
        closes,
        List<double>.filled(n, 100),
        List<String>.generate(n, (i) => '2026-01-${(i + 1).toString().padLeft(2, '0')}'),
      );
    }

    test('① MACD 金叉', () {
      final closes = <double>[
        20, 19.5, 19, 18.5, 18, 17.5, 17, 16.8, 16.5, 16.2,
        16.0, 16.1, 16.3, 16.6, 17.0, 17.5, 18.0, 18.6, 19.2, 19.8,
        20.4, 21.0, 21.6, 22.2, 22.8, 23.4, 24.0, 24.6, 25.2, 25.8,
      ];
      final f = CompiledFormula.compile(
          'DIF:=EMA(CLOSE,12)-EMA(CLOSE,26);\nDEA:=EMA(DIF,9);\nXG:CROSS(DIF,DEA);');
      final desc = f.evalSignal(makeKline(closes), mode: 'RECENT_N', recentN: 15);
      expect(desc, isNotNull, reason: '反转初期应出现 MACD 金叉');
    });

    test('② KDJ 超卖区金叉公式语法正确且可求值', () {
      final closes = List<double>.generate(60, (i) => 10 + (i % 9) - 4);
      final f = CompiledFormula.compile(
          'RSV:=(CLOSE-LLV(LOW,9))/(HHV(HIGH,9)-LLV(LOW,9))*100;\n'
          'K:=SMA(RSV,3,1);\nD:=SMA(K,3,1);\nJ:=3*K-2*D;\nXG:CROSS(K,D) AND D<20;');
      final out = f.eval(makeKline(closes));
      expect(out.containsKey('XG'), isTrue);
      expect(out['XG']!.length, 60);
    });

    test('③ 缩量回踩 20 日线', () {
      final closes = List<double>.generate(
          40, (i) => 10 + 0.01 * (i % 5) - 0.005 * (i % 3));
      final k = makeKline(closes);
      for (var i = 0; i < k.vol.length; i++) {
        k.vol[i] = 1000 * pow(0.85, i).toDouble();
      }
      final f = CompiledFormula.compile(
          'XG:ABS(CLOSE/MA(CLOSE,20)-1)<0.02 AND VOL<MA(VOL,5)*0.8;');
      final desc = f.evalSignal(k);
      expect(desc, isNotNull);
    });

    test('语法错误检测', () {
      expect(() => CompiledFormula.compile('XG CROSS(CLOSE,1);'),
          throwsA(isA<FormulaException>()));
      expect(() => CompiledFormula.compile('XG:UNKNOWN_FN(CLOSE,1);'),
          throwsA(isA<FormulaException>()));
      expect(() => CompiledFormula.compile('xg = ma(close, n)'),
          throwsA(isA<FormulaException>()), reason: 'n 必须是整数常量');
      expect(() => CompiledFormula.compile('xg = no_such_fn(close, 1)'),
          throwsA(isA<FormulaException>()), reason: '不支持的函数');
      expect(() => CompiledFormula.compile('xg = undefined_var + 1'),
          throwsA(isA<FormulaException>()), reason: '未定义变量');
    });

    test('Python 风格语法（小写、= 赋值、and/or、==）', () {
      final closes = <double>[
        20, 19.5, 19, 18.5, 18, 17.5, 17, 16.8, 16.5, 16.2,
        16.0, 16.1, 16.3, 16.6, 17.0, 17.5, 18.0, 18.6, 19.2, 19.8,
        20.4, 21.0, 21.6, 22.2, 22.8, 23.4, 24.0, 24.6, 25.2, 25.8,
      ];
      final f = CompiledFormula.compile(
          'dif = ema(close, 12) - ema(close, 26)\n'
          'dea = ema(dif, 9)\n'
          'xg = cross(dif, dea)');
      final desc = f.evalSignal(makeKline(closes),
          mode: 'RECENT_N', recentN: 15);
      expect(desc, isNotNull, reason: '反转初期应出现 MACD 金叉');
    });

    test('Python 与通达信写法混用', () {
      final f = CompiledFormula.compile(
          'DIF:=ema(close,12)-EMA(CLOSE,26);\nDEA:=EMA(DIF,9);\nXG:CROSS(DIF,DEA) AND VOL<MA(VOL,5)*0.8;');
      final k = makeKline(List<double>.generate(40, (i) => 10 + (i % 7) * 0.3));
      for (var i = 0; i < k.vol.length; i++) {
        k.vol[i] = 1000 * pow(0.85, i).toDouble();
      }
      final out = f.eval(k);
      expect(out.containsKey('XG'), isTrue);
    });

    test('变量名含数字（zhan5 类命名）', () {
      // 回归：标识符后续字符须含数字，不能把一个名字切成"标识符+数字"两段
      final f = CompiledFormula.compile('zhan5 = count(close > 0, 5)\nxg = zhan5 >= 5');
      final k = makeKline(List<double>.generate(10, (i) => i + 1.0));
      expect(f.eval(k).containsKey('XG'), isTrue);
    });

    test('表达式内 = 作等于比较（通达信习惯写法）', () {
      final f = CompiledFormula.compile('xg = ref(close, 1) = ref(close, 2)');
      final k = makeKline(const <double>[1.0, 2, 2, 3]);
      final out = f.eval(k);
      expect(out['XG']![2], 0.0, reason: '第3根=2、第1根=1，不等');
      expect(out['XG']![3], 1.0, reason: '第4根=3 与第2根=2… ref(close,2) 取第2根=2，第3根 close=2，相等');
    });

    test('最近 N 根信号判定', () {
      final f = CompiledFormula.compile('XG:CLOSE>REF(CLOSE,1);');
      final closes = <double>[1.0, 2, 3, 4, 5, 4, 4, 4, 4, 4];
      final k = makeKline(closes);
      expect(f.evalSignal(k), isNull);
      expect(f.evalSignal(k, mode: 'RECENT_N', recentN: 8), isNotNull);
      expect(f.evalSignal(k, mode: 'RECENT_N', recentN: 5), isNull);
    });
  });

  group('未来函数族（语义对齐通达信官方说明）', () {
    final x = <double>[100.0, 110, 120, 108, 96, 105, 115, 103, 95, 108];

    test('ZIG 阶梯输出', () {
      expectClose(ZIG(x, 10)[0], 100.0);
      expectClose(ZIG(x, 10)[1], 100.0);
      expectClose(ZIG(x, 10)[2], 120.0, '峰@2');
      expectClose(ZIG(x, 10)[4], 96.0, '谷@4');
      expectClose(ZIG(x, 10)[6], 115.0, '峰@6');
      expectClose(ZIG(x, 10)[9], 95.0, '谷@8 延续到尾');
    });

    test('ZIGA 绝对量转向', () {
      final a = <double>[10.0, 11, 12, 10.4, 9];
      final z = ZIGA(a, 1.5);
      expectClose(z[0], 10.0);
      expectClose(z[2], 12.0, '峰@2');
      expectClose(z[4], 12.0);
    });

    test('PEAK / PEAKBARS', () {
      expectClose(PEAK(x, 10, 1)[5], double.nan, '确认前为 NaN');
      expectClose(PEAK(x, 10, 1)[6], 115.0);
      expectClose(PEAK(x, 10, 1)[9], 115.0);
      expectClose(PEAK(x, 10, 2)[2], 120.0, '前 2 个波峰');
      expectClose(PEAK(x, 10, 3)[9], double.nan, '只有 2 个波峰');
      expectClose(PEAKBARS(x, 10, 1)[9], 3.0, '9-6');
      expectClose(PEAKBARS(x, 10, 2)[9], 7.0, '9-2');
    });

    test('TROUGH / TROUGHBARS', () {
      expectClose(TROUGH(x, 10, 1)[8], 95.0);
      expectClose(TROUGH(x, 10, 1)[9], 95.0);
      expectClose(TROUGH(x, 10, 2)[4], 96.0);
      expectClose(TROUGHBARS(x, 10, 1)[9], 1.0, '9-8');
      expectClose(TROUGHBARS(x, 10, 2)[9], 5.0, '9-4');
    });

    test('BACKSET 向前赋值', () {
      final cond = <double>[0.0, 0, 1, 0, 0];
      expect(BACKSET(cond, 2), <double>[0, 1, 1, 0, 0]);
      expect(BACKSET(cond, 3), <double>[1, 1, 1, 0, 0]);
    });

    test('FILTER 信号去抖（非未来函数）', () {
      final cond = <double>[1.0, 0, 1, 1, 0, 1];
      expect(FILTER(cond, 1), <double>[1, 0, 1, 0, 0, 1]);
    });

    test('REF 负偏移引用未来', () {
      final c = <double>[1.0, 2, 3, 4, 5];
      final r = REF(c, -1);
      expectClose(r[0], 2.0);
      expectClose(r[3], 5.0);
      expectClose(r[4], double.nan, '尾部补 NaN');
    });

    test('公式级 ZIG 拐点判定（波峰处阶梯跳升）', () {
      final f = CompiledFormula.compile(
          'z = zig(close, 10)\nxg = z > ref(z, 1)');
      final k = KlineData(
          List<double>.filled(10, 0), List<double>.from(x),
          List<double>.from(x), List<double>.from(x),
          List<double>.filled(10, 100),
          List<String>.generate(10, (i) => '$i'));
      final out = f.eval(k)['XG']!;
      expect(out[2], 1, reason: '峰@2 处阶梯跳升');
      expect(out[6], 1, reason: '峰@6 处阶梯跳升');
      expect(out[9], 0);
      expect(f.hasFutureFunctions, isTrue);
    });

    test('hasFutureFunctions 检测', () {
      expect(CompiledFormula.compile('xg = close > ma(close, 5)').hasFutureFunctions,
          isFalse);
      expect(CompiledFormula.compile('xg = zig(close, 5) > 0').hasFutureFunctions,
          isTrue);
      expect(CompiledFormula.compile('xg = peak(close, 5, 1) > 100').hasFutureFunctions,
          isTrue);
      expect(
          CompiledFormula.compile(
                  'a = ma(close, 5)\nb = ma(close, 10)\nxg = backset(cross(a, b), 3) > 0')
              .hasFutureFunctions,
          isTrue);
      expect(CompiledFormula.compile('xg = refx(close, 1) > close').hasFutureFunctions,
          isTrue);
      expect(CompiledFormula.compile('xg = ref(close, -1) > close').hasFutureFunctions,
          isTrue, reason: '负偏移引用未来');
      expect(CompiledFormula.compile('xg = ref(close, 1) > 0').hasFutureFunctions,
          isFalse);
      expect(CompiledFormula.compile('xg = filter(close > open, 5)').hasFutureFunctions,
          isFalse, reason: 'filter 不是未来函数');
    });

    test('函数速用示例公式可编译可求值', () {
      final f = CompiledFormula.compile(
          'z = zig(close, 8)\n'
          'tg = trough(close, 8, 1)\n'
          'xg = close < tg * 1.03 and close > ref(close, 1)');
      final k = KlineData(
          List<double>.filled(30, 0),
          List<double>.generate(30, (i) => 20 + (i % 10)),
          List<double>.generate(30, (i) => 20 + (i % 10)),
          List<double>.generate(30, (i) => 20 + (i % 10)),
          List<double>.filled(30, 100),
          List<String>.generate(30, (i) => '$i'));
      final out = f.eval(k);
      expect(out.containsKey('XG'), isTrue);
      expect(out['XG']!.length, 30);
    });
  });
}
