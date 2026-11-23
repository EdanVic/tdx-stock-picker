/// 通达信风格指标函数库（纯 Dart，零平台依赖）。
///
/// 语义对齐 MyTT（https://github.com/mpquant/MyTT）：
/// - MA/LLV/HHV/SUM/COUNT 为窗口滚动计算，窗口未满时输出 NaN；
/// - EMA 为 span=N、adjust=False 的指数递推：Y[i] = 2/(N+1)*X[i] + (1-2/(N+1))*Y[i-1]；
/// - SMA(X,N,M) 为中国版递推：Y[i] = M/N*X[i] + (1-M/N)*Y[i-1]（等价 alpha=M/N 的 ewm）；
/// - REF 为序列右移 N 位，头部补 NaN；
/// - CROSS(A,B)：A 上穿 B，即 A[i]>B[i] 且 A[i-1]<=B[i-1]（NaN 比较视为假）。
/// 不使用任何未来函数：第 i 根输出仅依赖第 i 根及之前的输入。
library;

const double kNaN = double.nan;

bool _isValid(double v) => !v.isNaN;

/// 算术平均移动平均。前 N-1 根为 NaN（语义同 pandas rolling(mean)）。
List<double> MA(List<double> x, int n) {
  final len = x.length;
  final out = List<double>.filled(len, kNaN);
  double sum = 0;
  int validCount = 0;
  for (var i = 0; i < len; i++) {
    final v = x[i];
    if (_isValid(v)) {
      sum += v;
      validCount++;
    }
    if (i >= n) {
      final old = x[i - n];
      if (_isValid(old)) {
        sum -= old;
        validCount--;
      }
    }
    if (i >= n - 1 && validCount == n) out[i] = sum / n;
  }
  return out;
}

/// 指数移动平均（span=N, adjust=False）。
List<double> EMA(List<double> x, int n) {
  final len = x.length;
  final out = List<double>.filled(len, kNaN);
  if (len == 0) return out;
  final alpha = 2.0 / (n + 1);
  double prev = x[0];
  out[0] = _isValid(prev) ? prev : kNaN;
  for (var i = 1; i < len; i++) {
    final v = x[i];
    if (!_isValid(v)) {
      out[i] = prev;
      continue;
    }
    if (!_isValid(prev)) {
      prev = v;
      out[i] = v;
      continue;
    }
    prev = alpha * v + (1 - alpha) * prev;
    out[i] = prev;
  }
  return out;
}

/// 通达信 SMA(X,N,M)：Y[i] = (X[i]*M + Y[i-1]*(N-M)) / N，Y[0]=X[0]。
List<double> SMA(List<double> x, int n, int m) {
  final len = x.length;
  final out = List<double>.filled(len, kNaN);
  if (len == 0) return out;
  final alpha = m / n;
  double prev = x[0];
  out[0] = _isValid(prev) ? prev : kNaN;
  for (var i = 1; i < len; i++) {
    final v = x[i];
    if (!_isValid(v)) {
      out[i] = prev;
      continue;
    }
    if (!_isValid(prev)) {
      prev = v;
      out[i] = v;
      continue;
    }
    prev = alpha * v + (1 - alpha) * prev;
    out[i] = prev;
  }
  return out;
}

/// 引用 N 根前的值，头部 N 根为 NaN。
/// N 为负数时引用未来（第 i-N 根），尾部 |N| 根为 NaN —— 属未来函数，慎用。
List<double> REF(List<double> x, int n) {
  final len = x.length;
  final out = List<double>.filled(len, kNaN);
  if (n >= 0) {
    for (var i = n; i < len; i++) {
      out[i] = x[i - n];
    }
  } else {
    for (var i = 0; i < len + n; i++) {
      out[i] = x[i - n];
    }
  }
  return out;
}

/// 最近 N 根最低值，窗口未满为 NaN。
List<double> LLV(List<double> x, int n) {
  final len = x.length;
  final out = List<double>.filled(len, kNaN);
  for (var i = n - 1; i < len; i++) {
    var m = x[i];
    for (var j = i - n + 1; j < i; j++) {
      if (x[j] < m) m = x[j];
    }
    out[i] = m;
  }
  return out;
}

/// 最近 N 根最高值，窗口未满为 NaN。
List<double> HHV(List<double> x, int n) {
  final len = x.length;
  final out = List<double>.filled(len, kNaN);
  for (var i = n - 1; i < len; i++) {
    var m = x[i];
    for (var j = i - n + 1; j < i; j++) {
      if (x[j] > m) m = x[j];
    }
    out[i] = m;
  }
  return out;
}

/// 最近 N 根求和，窗口未满为 NaN。
List<double> SUM(List<double> x, int n) {
  final len = x.length;
  final out = List<double>.filled(len, kNaN);
  double sum = 0;
  int cnt = 0;
  for (var i = 0; i < len; i++) {
    final v = x[i];
    if (_isValid(v)) {
      sum += v;
      cnt++;
    }
    if (i >= n) {
      final old = x[i - n];
      if (_isValid(old)) {
        sum -= old;
        cnt--;
      }
    }
    if (i >= n - 1 && cnt == n) out[i] = sum;
  }
  return out;
}

/// 最近 N 根内条件成立的天数，窗口未满为 NaN。
List<double> COUNT(List<double> cond, int n) {
  final len = cond.length;
  final out = List<double>.filled(len, kNaN);
  int cnt = 0;
  for (var i = 0; i < len; i++) {
    if (cond[i] != 0 && _isValid(cond[i])) cnt++;
    if (i >= n && cond[i - n] != 0 && _isValid(cond[i - n])) cnt--;
    if (i >= n - 1) out[i] = cnt.toDouble();
  }
  return out;
}

/// 条件选择：cond 非 0 取 a，否则取 b。
List<double> IFF(List<double> cond, List<double> a, List<double> b) {
  final len = cond.length;
  final out = List<double>.filled(len, kNaN);
  for (var i = 0; i < len; i++) {
    final c = cond[i];
    if (!_isValid(c)) {
      out[i] = kNaN;
    } else {
      out[i] = c != 0 ? a[i] : b[i];
    }
  }
  return out;
}

List<double> ABS(List<double> x) =>
    x.map((v) => _isValid(v) ? v.abs() : v).toList();

/// 两序列逐根取大（短序列按最后一根对齐 extend）。
List<double> MAX(List<double> a, List<double> b) => _zip(a, b, (x, y) => x > y ? x : y);

/// 两序列逐根取小。
List<double> MIN(List<double> a, List<double> b) => _zip(a, b, (x, y) => x < y ? x : y);

List<double> _zip(List<double> a, List<double> b, double Function(double, double) f) {
  final len = a.length;
  final out = List<double>.filled(len, kNaN);
  for (var i = 0; i < len; i++) {
    final x = a[i];
    final y = b.length == len ? b[i] : b[b.length - 1];
    out[i] = (_isValid(x) && _isValid(y)) ? f(x, y) : kNaN;
  }
  return out;
}

/// A 上穿 B：A[i]>B[i] 且 A[i-1]<=B[i-1]（NaN 比较为假）。
List<double> CROSS(List<double> a, List<double> b) {
  final len = a.length;
  final out = List<double>.filled(len, 0);
  for (var i = 1; i < len; i++) {
    final ai = a[i], bi = b[i], ap = a[i - 1], bp = b[i - 1];
    if (_isValid(ai) && _isValid(bi) && _isValid(ap) && _isValid(bp)) {
      if (ai > bi && ap <= bp) out[i] = 1;
    }
  }
  return out;
}

/// MACD：DIF=EMA(C,12)-EMA(C,26)，DEA=EMA(DIF,9)，MACD=2*(DIF-DEA)。
({List<double> dif, List<double> dea, List<double> macd}) MACD(List<double> close,
    {int short = 12, int long = 26, int mid = 9}) {
  final dif = _sub(EMA(close, short), EMA(close, long));
  final dea = EMA(dif, mid);
  final macd = _sub(dif, dea).map((v) => v.isNaN ? v : v * 2).toList();
  return (dif: dif, dea: dea, macd: macd);
}

/// KDJ（默认 9,3,1）。
({List<double> k, List<double> d, List<double> j}) KDJ(List<double> high,
    List<double> low, List<double> close,
    {int n = 9, int m1 = 3, int m2 = 3}) {
  final rsv = List<double>.filled(close.length, kNaN);
  for (var i = 0; i < close.length; i++) {
    final hh = HHV(high, n)[i];
    final ll = LLV(low, n)[i];
    if (_isValid(hh) && _isValid(ll) && hh != ll) {
      rsv[i] = (close[i] - ll) / (hh - ll) * 100;
    }
  }
  final k = SMA(rsv, m1, 1);
  final d = SMA(k, m2, 1);
  // J = 3K - 2D
  final j = List<double>.filled(close.length, kNaN);
  for (var i = 0; i < close.length; i++) {
    if (_isValid(k[i]) && _isValid(d[i])) j[i] = 3 * k[i] - 2 * d[i];
  }
  return (k: k, d: d, j: j);
}

List<double> _sub(List<double> a, List<double> b) => _zip(a, b, (x, y) => x - y);

// ---------------------------------------------------------------------------
// 未来函数族（zig 之字转向及其配套）。
// 语义对齐通达信 TCalc64 官方函数说明：
//   ZIG(K,N)  价格变化量超过 N% 时转向；PEAK/PEAKBARS/TROUGH/TROUGHBARS(K,N,M)
//   取前 M 个已确认波峰/波谷的值/距离（M=1 为最近一个）；ZIGA(K,X) 为绝对量变体；
//   BACKSET(X,N) 若 X 非 0 将当前到前 N-1 周期置 1。
// ⚠️ 这些是"未来函数"：拐点靠未来走势确认，最新几根的信号可能漂移/重绘，
//    选股结果仅供参考。本实现对整个历史序列计算，与通达信盘中行为一致。
// ---------------------------------------------------------------------------

class _Pivot {
  final int idx;
  final double price;
  final bool isPeak;
  const _Pivot(this.idx, this.price, this.isPeak);
}

/// ZIG 状态机：返回全部已确认拐点（按时间序）。
/// [pct] 为百分数（5 表示 5%）；[absAmt] 非 null 时按绝对量转向（ZIGA）。
List<_Pivot> _zigPivots(List<double> x, double pct, [double? absAmt]) {
  final pivots = <_Pivot>[];
  final len = x.length;
  if (len == 0 || !_isValid(x[0])) return pivots;
  final r = pct / 100.0;
  // trend: 1 上升跟踪 / -1 下降跟踪 / 0 未定（以 x[0] 为锚）
  var trend = 0;
  var maxPrice = x[0], maxIdx = 0;
  var minPrice = x[0], minIdx = 0;
  for (var i = 1; i < len; i++) {
    final v = x[i];
    if (!_isValid(v)) continue;
    if (trend == 1) {
      if (v > maxPrice) {
        maxPrice = v;
        maxIdx = i;
      } else if (maxPrice > 0 &&
          (absAmt != null ? maxPrice - v >= absAmt : v <= maxPrice * (1 - r))) {
        pivots.add(_Pivot(maxIdx, maxPrice, true));
        trend = -1;
        minPrice = v;
        minIdx = i;
      }
    } else if (trend == -1) {
      if (v < minPrice) {
        minPrice = v;
        minIdx = i;
      } else if (minPrice > 0 &&
          (absAmt != null ? v - minPrice >= absAmt : v >= minPrice * (1 + r))) {
        pivots.add(_Pivot(minIdx, minPrice, false));
        trend = 1;
        maxPrice = v;
        maxIdx = i;
      }
    } else if (minPrice > 0) {
      // 未定方向：相对锚点 x[0] 涨/跌破阈值即确认首个拐点
      if (absAmt != null ? v - x[0] >= absAmt : v >= x[0] * (1 + r)) {
        pivots.add(_Pivot(0, x[0], false));
        trend = 1;
        maxPrice = v;
        maxIdx = i;
      } else if (absAmt != null ? x[0] - v >= absAmt : v <= x[0] * (1 - r)) {
        pivots.add(_Pivot(0, x[0], true));
        trend = -1;
        minPrice = v;
        minIdx = i;
      }
    }
  }
  return pivots;
}

/// ZIG 之字转向（未来函数）：输出阶梯序列，第 i 根 = 截至 i 最近一个已确认拐点价。
List<double> ZIG(List<double> x, double pct) => _zigSeries(x, pct, null);

/// ZIGA 之字转向（未来函数，绝对量版）：价格变化超过 [amt] 元时转向。
List<double> ZIGA(List<double> x, double amt) => _zigSeries(x, 0, amt);

List<double> _zigSeries(List<double> x, double pct, double? amt) {
  final len = x.length;
  final out = List<double>.filled(len, kNaN);
  final pivots = _zigPivots(x, pct, amt);
  var p = 0;
  for (var i = 0; i < len; i++) {
    while (p < pivots.length && pivots[p].idx <= i) p++;
    if (p > 0) out[i] = pivots[p - 1].price;
  }
  return out;
}

List<double> _pivotValue(
    List<double> x, double pct, int m, bool wantPeak, bool bars) {
  final len = x.length;
  final out = List<double>.filled(len, kNaN);
  final list = _zigPivots(x, pct).where((p) => p.isPeak == wantPeak).toList();
  if (m < 1 || list.length < m) return out;
  final target = list[list.length - m]; // m=1 为最近一个
  for (var i = target.idx; i < len; i++) {
    out[i] = bars ? (i - target.idx).toDouble() : target.price;
  }
  return out;
}

/// PEAK（未来函数）：前 m 个 ZIG 波峰值，m=1 为最近波峰；该波峰确认前为 NaN。
List<double> PEAK(List<double> x, double pct, int m) =>
    _pivotValue(x, pct, m, true, false);

/// PEAKBARS（未来函数）：前 m 个 ZIG 波峰到当前的周期数。
List<double> PEAKBARS(List<double> x, double pct, int m) =>
    _pivotValue(x, pct, m, true, true);

/// TROUGH（未来函数）：前 m 个 ZIG 波谷值。
List<double> TROUGH(List<double> x, double pct, int m) =>
    _pivotValue(x, pct, m, false, false);

/// TROUGHBARS（未来函数）：前 m 个 ZIG 波谷到当前的周期数。
List<double> TROUGHBARS(List<double> x, double pct, int m) =>
    _pivotValue(x, pct, m, false, true);

/// BACKSET（未来函数）：若 cond 非 0，将当前位置到前 n-1 周期置 1，否则 0。
List<double> BACKSET(List<double> cond, int n) {
  final len = cond.length;
  final out = List<double>.filled(len, 0);
  if (n < 1) return out;
  for (var i = 0; i < len; i++) {
    if (cond[i] != 0 && _isValid(cond[i])) {
      for (var j = i; j >= 0 && j > i - n; j--) {
        out[j] = 1;
      }
    }
  }
  return out;
}

/// FILTER（非未来函数）：信号去抖——条件成立后，其后 n 周期内的信号置 0。
List<double> FILTER(List<double> cond, int n) {
  final len = cond.length;
  final out = List<double>.filled(len, 0);
  var lastTrue = -1;
  for (var i = 0; i < len; i++) {
    if (cond[i] != 0 && _isValid(cond[i])) {
      if (lastTrue < 0 || i - lastTrue > n) out[i] = 1;
      lastTrue = i;
    }
  }
  return out;
}
