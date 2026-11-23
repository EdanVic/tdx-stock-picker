# tdx选股药丸（tdx-stock-picker）

通达信公式风格的**本地策略选股**安卓 APP（Flutter）。策略文件仅存手机本地；行情数据按需从公开接口临时拉取、即用即删，不做持久化；不提供任何交易功能。

![platform](https://img.shields.io/badge/platform-Android-3DDC84) ![flutter](https://img.shields.io/badge/Flutter-3.x-02569B) ![license](https://img.shields.io/badge/license-MIT-blue)

## 功能特性

- **策略管理**：新建/编辑/删除/复制/导出分享，JSON 文件存于应用私有目录，重启不丢
- **Python 风格公式语法**（兼容通达信写法）：一行一条语句，`name = 表达式` 赋值，最后一条语句为选股信号；大小写不敏感
- **22 个指标函数**：ma / ema / sma / ref / llv / hhv / sum / count / abs / max / min / if / cross / filter，以及未来函数族 zig / ziga / peak / peakbars / trough / troughbars / backset / refx（含未来函数编译期警示）
- **AI 公式转换**：粘贴任意软件（通达信/同花顺/聚宽/Python 量化）的公式，AI 改写为本 APP 语法，校验通过后一键填入；语法规范文档（`assets/ai_syntax.md`）随包内置作为 AI 提示词；支持 OpenAI 兼容接口（Moonshot 开放平台、Kimi 订阅版 Coding 计划、DeepSeek 等）
- **多数据源自动切换**：腾讯行情主源 + 东方财富兜底，主源连续失败自动熔断切换；科创板自动走东财补齐
- **扫描并发可调**（1–10），停牌按 K 线新旧自动判定
- **选股范围**：沪主板/深主板/创业板/科创板/北交所多选；剔除 ST/停牌/退市整理
- **周期跨度**：日/周 + 5/15/30/60 分钟，K 线 30–250 根可调
- **结果管理**：摘要落盘、CSV 导出（UTF-8 BOM）、系统分享、K 线蜡烛图预览

## 架构

```
lib/
 ├─ engine/      纯 Dart 公式引擎（零平台依赖，可单测）
 │    ├─ functions.dart  指标函数库（语义对齐 MyTT / 通达信 TCalc64）
 │    └─ formula.dart     词法/递归下降解析 + 求值 + 信号判定
 ├─ quote/       QuoteProvider 抽象
 │    ├─ quote_provider.dart   东财实现 + 并发/重试/限频客户端
 │    └─ tencent_provider.dart 腾讯实现 + 多源自动切换（熔断/降级）
 ├─ ai/          OpenAI 兼容公式转换客户端
 ├─ models/      Strategy / Kline / ScanResult
 ├─ storage/     strategies/ results/ settings 文件存储（K 线不落盘）
 ├─ state/       ScanController 任务状态机
 └─ ui/          策略 / 选股 / 结果 / K线 / 设置 / 帮助
```

## 构建

```bash
flutter pub get
flutter analyze
flutter test          # 46 项单元测试
flutter build apk --release
```

## 测试

```bash
flutter test
```

行情网关（翻页/镜像容错）、腾讯多源切换（熔断/降级/板块拆分）、公式引擎、AI 转换（请求/重试/解析）均有 MockClient 回归测试。

## 数据与隐私

- 行情来源：腾讯 / 东方财富公开 HTTP 接口，仅作个人学习研究用途，不做数据转发服务
- API 密钥（AI 转换）只保存在手机本地 `settings.json`，只用于请求鉴权
- 本 APP 不提供交易功能、不接入券商接口、不构成投资建议。股市有风险，投资需谨慎

## License

MIT（见 LICENSE）
