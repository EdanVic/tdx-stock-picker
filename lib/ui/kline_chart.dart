import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine/functions.dart' as ind;
import '../models/models.dart';
import '../quote/quote_provider.dart';

/// K 线预览页：按需拉取数据（不落盘），Canvas 绘制蜡烛图 + MA5/10/20。
class KlineChartPage extends StatefulWidget {
  final StockInfo stock;
  final String period;
  final int count;
  const KlineChartPage({
    super.key,
    required this.stock,
    this.period = 'day',
    this.count = 120,
  });

  @override
  State<KlineChartPage> createState() => _KlineChartPageState();
}

class _KlineChartPageState extends State<KlineChartPage> {
  late final EastMoneyProvider _provider;
  List<Kline>? _klines;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    // 进入 K 线页强制横屏，宽度更充足，蜡烛图展示更完整
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _provider = EastMoneyProvider();
    _load();
  }

  @override
  void dispose() {
    // 退出时恢复竖屏
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final k = await _provider.fetchKline(
          widget.stock, widget.period, widget.count);
      if (!mounted) return;
      setState(() {
        _klines = k;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.stock.name)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text('加载失败：$_error'))
              : _klines == null || _klines!.isEmpty
                  ? const Center(child: Text('无 K 线数据'))
                  : Column(
                      children: [
                        Expanded(child: KlineChart(klines: _klines!)),
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text(
                            '${widget.stock.code} · '
                            '${KlineSetting.periodNames[widget.period]} · '
                            '${_klines!.length}根 · 数据仅本次展示用，用后删除',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
    );
  }
}

/// Canvas 蜡烛图组件（最近 showCount 根，含 MA5/MA10/MA20）。
class KlineChart extends StatelessWidget {
  final List<Kline> klines;
  final int showCount;
  const KlineChart({super.key, required this.klines, this.showCount = 90});

  @override
  Widget build(BuildContext context) {
    final data = klines.length > showCount
        ? klines.sublist(klines.length - showCount)
        : klines;
    final closes = data.map((e) => e.close).toList();
    final ma5 = ind.MA(closes, 5);
    final ma10 = ind.MA(closes, 10);
    final ma20 = ind.MA(closes, 20);
    return CustomPaint(
      painter: _KlinePainter(data, ma5, ma10, ma20),
      child: Container(),
    );
  }
}

class _KlinePainter extends CustomPainter {
  final List<Kline> data;
  final List<double> ma5, ma10, ma20;
  _KlinePainter(this.data, this.ma5, this.ma10, this.ma20);

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;
    final up = Paint()..color = const Color(0xFFD32F2F); // 红涨
    final down = Paint()..color = const Color(0xFF388E3C); // 绿跌
    final grid = Paint()
      ..color = Colors.grey.withValues(alpha: 0.3)
      ..strokeWidth = 0.5;
    final ma5Paint = Paint()
      ..color = Colors.amber
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    final ma10Paint = Paint()
      ..color = Colors.blue
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    final ma20Paint = Paint()
      ..color = Colors.purple
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    var hi = data.first.high;
    var lo = data.first.low;
    for (final k in data) {
      if (k.high > hi) hi = k.high;
      if (k.low < lo) lo = k.low;
    }
    final pad = (hi - lo) * 0.08;
    hi += pad;
    lo -= pad;
    double y(double price) => size.height * (1 - (price - lo) / (hi - lo));

    // 网格
    for (var i = 1; i <= 3; i++) {
      final gy = size.height * i / 4;
      canvas.drawLine(Offset(0, gy), Offset(size.width, gy), grid);
    }

    final slot = size.width / data.length;
    final candleW = (slot * 0.7).clamp(1.0, 20.0);

    for (var i = 0; i < data.length; i++) {
      final k = data[i];
      final x = slot * (i + 0.5);
      final paint = k.close >= k.open ? up : down;
      // 影线
      canvas.drawLine(
          Offset(x, y(k.high)), Offset(x, y(k.low)), paint..strokeWidth = 1);
      // 实体
      final top = y(k.open > k.close ? k.open : k.close);
      final bottom = y(k.open > k.close ? k.close : k.open);
      canvas.drawRect(
          Rect.fromLTRB(x - candleW / 2, top, x + candleW / 2,
              bottom < top + 1 ? top + 1 : bottom),
          paint..style = PaintingStyle.fill);
    }

    // MA 线
    void drawMa(List<double> ma, Paint p) {
      final path = Path();
      var started = false;
      for (var i = 0; i < ma.length; i++) {
        final v = ma[i];
        if (v.isNaN) continue;
        final x = slot * (i + 0.5);
        if (!started) {
          path.moveTo(x, y(v));
          started = true;
        } else {
          path.lineTo(x, y(v));
        }
      }
      canvas.drawPath(path, p);
    }

    drawMa(ma5, ma5Paint);
    drawMa(ma10, ma10Paint);
    drawMa(ma20, ma20Paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
