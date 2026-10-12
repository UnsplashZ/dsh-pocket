# 决策记录（ADR）

> 每条记录：背景 → 决定 → 后果。**改动其中任何一条都要新加一条 ADR 说明为什么翻案**，不要直接改历史。

---

## ADR-0001 · 移动端采用 iOS 原生 SwiftUI，而非"自研 Web UI 跑在 Tauri 里"

**日期**：2026-10-12（v0.2 修订；推翻 v0.1 的选择）
**背景**：v0.1 曾选定"复用 tether 的 Tauri 壳 + 自研移动优先 Web UI"。用户明确要求：**严格遵循 Apple 设计风格，最好用 Swift 原生构建**。
**决定**：iOS 客户端为原生 SwiftUI App，会话渲染**不使用任何 WebView**。
**后果**：
- 得到真正的原生手感（系统导航转场、材质、触感、QuickLook、分享、动态字体、VoiceOver），HIG 可逐条验收；
- 代价：协议层要用 Swift 重写（原本可复用 TS 类型定义）；Android 不再"顺便就有"（见 [DESIGN.md](DESIGN.md) §3.5）；
- 好处：不再有任何注入 CSS / DOM 依赖 / WebView 合成 bug 的空间。

## ADR-0002 · 客户端用官方 `iroh-ffi`（Swift 包），不自建 UniFFI 桥、不分叉 tether 的 Rust

**日期**：2026-10-12
**背景**：tether 的传输实现在 Rust。要让 Swift 用上，有三条路：桥接 tether 的 Rust；用官方 iroh 绑定自己写薄层；完全自研。
**决定**：用官方 [iroh-ffi](https://github.com/n0-computer/iroh-ffi) 的 Swift 包 `IrohLib`（v1.1.0，预编译 xcframework），并在 Swift 里实现 **DLP 线协议**（≈400 行，契约见 `tether-core/src/lib.rs`）。
**后果**：
- 无需 Rust 工具链，无跨语言调试；
- 风险转移到"iroh-ffi 1.1.0 ↔ 宿主 iroh 1.0.3 是否互通" → 由 **M0b 最先验证**；
- 回退方案（若互通失败）：① 用 `cargo make swift-xcframework` 从 iroh-ffi 源码自建；② 退回"分叉 tether 的 Rust + UniFFI 桥"；
- 电脑端因此**一行不改**（见 ADR-0003）。

## ADR-0003 · 电脑端零改动，直接复用已安装的 `dsh-plugin-tether`

**日期**：2026-10-12
**背景**：电脑端插件提供了配对、设备白名单、cookie 兑换、逐请求注入、代理流。
**决定**：**不分叉、不修改**。客户端的 DLP 实现按现有 sidecar 的线协议对齐。
**后果**：
- 用户现在就能用（sidecar 已在运行）；
- 上游升级我们被动跟随（可接受：线协议很小且稳定）；
- 注入 CSS 那段代码虽然我们不用，但保留在插件里 —— 它只影响"用浏览器打开电脑端页面"的场景，不影响原生客户端。

## ADR-0004 · 保留"本地 TCP 代理 + URLSession/WebSocket"这一层

**日期**：2026-10-12
**背景**：可以在 iroh 流上手写 HTTP/WS，也可以像 tether 那样在 App 内起一个 loopback TCP 监听，把每条连接转发成一条代理流。
**决定**：保留本地 TCP 代理；上层用 `URLSession` 与 `URLSessionWebSocketTask`。
**后果**：
- 原生网络栈直接用（连接复用、超时、取消语义都是系统给的）；
- ATS 例外只需覆盖 `127.0.0.1`；
- 代价：进程内多一个 loopback 端口（已知边界：手机上其它 App 可连它，见 [TRANSPORT.md](TRANSPORT.md) §8.5）。

## ADR-0005 · 协议层用 Swift 新写；`DSH_Mobile` 的文档作参考，代码不直接复制

**日期**：2026-10-12
**背景**：`jayantTang/DSH_Mobile`（MIT）已有 Swift 协议层 `DSHKit` 与一份权威协议文档。
**决定**：**文档与端点目录直接用**（[PROTOCOL-NOTES.md](PROTOCOL-NOTES.md) 就是基于它）；**代码不复制**，因为它的实现未经真机验证、且我们的端点子集与渲染需求不同。
**后果**：避免把"未验证的实现"连同它的隐含假设一起带进来；同时保证我们自己的协议层可单测、可自检。

## ADR-0006 · iOS 17+ / SwiftUI 优先 / 不引入第三方 UI 库

**日期**：2026-10-12
**决定**：最低 iOS 17；SwiftUI 优先，UIKit 仅按需桥接（如扫码）；除 `IrohLib` 外**不引入任何第三方依赖**。
**后果**：可用的新 API（`@Observable`、`.sensoryFeedback`、`ContentUnavailableView`、`ShareLink`）能覆盖本项目所有 UI 需求；HIG 一致性更容易保证。

## ADR-0007 · 审批决策走 DSH 原生通道；tether 的 `approval` 消息只用来触发通知

**日期**：2026-10-12
**背景**：有两条审批路径并存 —— tether 的 `Wire::Approval`/`Decision`（电脑端插件观察后转发），与 DSH 原生的 `$events` waterfall `approval/request` + `$events/result`。
**决定**：**决策只走原生通道**；tether 的消息用于"有一条审批在等你"的**提示/通知**。
**后果**：不出现重复决策；原生通道能拿到完整上下文（工具名、理由、结构化选项）；电脑端插件即使将来去掉审批转发也不影响我们。

## ADR-0008 · 一期不做 Android、不追求上架

**日期**：2026-10-12
**决定**：本期只交付 iOS；分发走自签安装（免费账号 7 天续签）或 TestFlight（需付费账号）。**不为此做上架适配**。
**后果**：省下大量审核与合规工作；[IOS-DESIGN.md](IOS-DESIGN.md) §9 仍按"将来可能上架"写好隐私清单等基础项。

## ADR-0009 · 提供 `DEV-DIRECT` 开发模式（直连 Mac 上的注入 cookie 的 dev 代理）

**日期**：2026-10-12
**背景**：正常链路需要真机 + 配对 + iroh 全通，UI 与协议开发的迭代成本高。
**决定**：DEBUG 构建支持直连 `http://127.0.0.1:8788`（`tools/direct-gateway.mjs` 转发到 `127.0.0.1:19387` 并注入 cookie）。
**后果**：95% 的界面与协议工作可在模拟器完成，不依赖传输层；但**每个里程碑仍必须真机验收**（尤其 M0b/M1 的流畅度与滚动问题只有当设备能看见）。

## ADR-0010 · App 侧把库源码编成工程内静态框架，而不是让 Xcode 走 SwiftPM 解析

**日期**：2026-10-12
**背景**：设计上 `DSHKit` / `TetherKit` 是 SwiftPM 包（`swift test` 与 M0b spike 都用它们）。
但 `xcodegen` 生成的 `XCLocalSwiftPackageReference` 在 Xcode 27 上解析不出 product
（报 `Missing package product 'DSHKit'`），而远程包又会把构建绑死在"必须有网 + Xcode 的
SwiftPM 状态"上。
**决定**：
- **库的真源仍是 SwiftPM 包**（`ios/DSHKit/Package.swift`、`ios/TetherKit/Package.swift`）；
- App 侧在 `ios/project.yml` 里把**同一份源码目录**编成三个工程内静态框架 target
  （`IrohLib` / `DSHKit` / `TetherKit`），`xcodebuild` 完全不经过 SwiftPM；
- IrohLib 的部件（`Iroh.xcframework` + 官方 Swift 绑定源码）由 `ios/scripts/fetch-iroh.sh`
  取到 `ios/vendor/`（版本与 sha256 钉在脚本里，不入库）。
**后果**：
- 构建确定、离线可用、不受 Xcode 的 SwiftPM 缓存/网络影响；
- 代价是"同一份源码两套 target 定义"—— 但两边**共用源码目录**，不存在实现分叉；
  改 `project.yml` 与改 `Package.swift` 是两件要一起做的事（已在两处写注释互相指路）；
- `TetherKit` 的公开面因此收紧：`TetherLink` / `LocalProxyServer` / `TetherProxyStream`
  都改成 internal，App 只看到 `TetherSession` 这一层 —— 顺带避免了 App 被迫 `import IrohLib`。

## ADR-0011 · 最低版本从 iOS 17.0 提到 **17.5**

**日期**：2026-10-12
**背景**：`iroh-ffi` 官方 Swift 包的 `Package.swift` 声明 `.iOS("17.5")`。
**决定**：App 与两个包的 deployment target 都是 **iOS 17.5**。
**后果**：覆盖范围少了一档（17.0–17.4），换来直接用官方预编译部件、不自建 xcframework；
设计文档里写 17.0 的地方按本条为准。

## ADR-0012 · `$events` 上只答**原生** waterfall；tether 的 `approval` 消息只触发通知

**日期**：2026-10-12（落地 ADR-0007 的实现细节）
**背景**：有两条审批路径并存（ADR-0007 已决定只走原生），但落地时有个具体问题：
用户没来得及决定就断线时，那条 waterfall 该回什么？
**决定**：`EventStreamCoordinator` 在**世代失效**时给未决 waterfall 回一个安全结论 ——
审批回 `{kind:'result', value:'unavailable'}`（宿主侧 fail closed），提问回 `{kind:'next'}`。
**后果**：
- 宿主不会因为"没人应答"而永远阻塞；
- **App 永不自动决策**这条规则不被破坏：`unavailable` 不是批准；
- 代价：用户离线期间的审批会被判为"没人答得上"，回来后在时间线上看到的是
  `approval/decided { outcome: 'unavailable' }` —— 这是事实，不做美化。
