import 'package:flutter/material.dart';

/// 选股公式语法与函数说明（FR-02）：Python 风格，兼容通达信写法。
class HelpPage extends StatelessWidget {
  const HelpPage({super.key});

  static const _sections = [
    (
      '语句规则（Python 风格）',
      '一行一条语句，用换行或 ; 分隔。\n'
          'name = 表达式    赋值（中间变量）\n'
          '选股信号 = 最后一条语句（变量名建议用 xg）\n\n'
          '示例：\n'
          'dif = ema(close, 12) - ema(close, 26)\n'
          'dea = ema(dif, 9)\n'
          'xg = cross(dif, dea) and volume < ma(volume, 5) * 0.8\n\n'
          '兼容通达信写法：NAME:=表达式 赋值、NAME:表达式 输出、'
          'AND/OR/NOT、大写函数名均可混用。'
    ),
    (
      '序列常量（大小写不敏感）',
      'close / c：收盘价\nopen / o：开盘价\nhigh / h：最高价\n'
          'low / l：最低价\nvolume / vol / v：成交量'
    ),
    (
      '函数库（语义对齐通达信 / MyTT）',
      'ma(x, n)    N 日简单移动平均，窗口未满为无效值\n'
          'ema(x, n)   指数移动平均（span=N）\n'
          'sma(x, n, m) 通达信递推平均：y = (x*m + y*(n-m)) / n\n'
          'ref(x, n)   引用 N 根前的值；n 为负引用未来（未来函数）\n'
          'llv(x, n)   最近 N 根最低值\n'
          'hhv(x, n)   最近 N 根最高值\n'
          'sum(x, n)   最近 N 根求和\n'
          'count(x, n) 最近 N 根内 x 非 0 的天数\n'
          'cross(a, b) a 上穿 b\n'
          'if(c, a, b) 条件选择\n'
          'abs(x) 绝对值   max(a, b) 取大   min(a, b) 取小\n'
          'filter(cond, n) 信号去抖：触发后 n 根内不再触发（非未来函数）'
    ),
    (
      '未来函数（⚠️ 信号可能漂移）',
      '以下函数会引用未来数据，最新几根 K 线的信号可能随行情重绘，'
          '选股结果仅供参考，请勿直接作为买卖依据。\n\n'
          'zig(x, p)     之字转向：价格变化超 p% 时转向，输出最近确认拐点价\n'
          'ziga(x, a)    绝对量版：价格变化超 a 元时转向\n'
          'peak(x, p, m)     前 m 个波峰值（m=1 为最近）\n'
          'peakbars(x, p, m) 前 m 个波峰到当前的周期数\n'
          'trough(x, p, m) / troughbars(x, p, m)  波谷版\n'
          'backset(cond, n)  cond 非 0 时将当前及前 n-1 根置 1\n'
          'refx(x, n)    引用 n 根后的值（等价 ref(x, -n)）\n\n'
          '示例（回调到最近之字谷附近企稳）：\n'
          'z = zig(close, 8)\n'
          'tg = trough(close, 8, 1)\n'
          'xg = close < tg * 1.03 and close > ref(close, 1)\n\n'
          '策略编辑页与选股页会对含未来函数的策略显示黄色警示。'
    ),
    (
      '运算符',
      '算术：+ - * /\n比较：> < >= <= == !=\n逻辑：and or not\n'
          '比较与逻辑运算结果为 1（真）或 0（假）。'
    ),
    (
      '信号判定',
      '最后一根触发：公式信号序列最后一根为 1 即命中。\n'
          '最近 N 根内存在信号：放宽时间窗口，适合回踩类形态。'
    ),
    (
      '已知限制（V1 MVP）',
      '不支持跨周期引用、绘图语句；\n'
          'MACD 请按 dif/dea 公式书写；函数参数中的周期 n 必须是整数常量。\n'
          '除未来函数族外，引擎第 i 根结果仅依赖第 i 根及之前的数据。'
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('函数与语法说明')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: _sections
            .map((s) => Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(s.$1,
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 6),
                        Text(s.$2,
                            style: const TextStyle(
                                fontFamily: 'monospace', fontSize: 12.5)),
                      ],
                    ),
                  ),
                ))
            .toList(),
      ),
    );
  }
}
