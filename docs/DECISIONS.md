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

## ADR-0013 · Markdown 自己写块级渲染器，不引第三方库

**日期**：2026-10-12
**背景**：助手正文里的 Markdown 之前只处理"内联 + 代码围栏"，**表格会原样显示**成
`| 方向 | 能做什么 |`。调研了 [swift-markdown-ui (MarkdownUI)](https://github.com/gonzalezreal/swift-markdown-ui)
（纯 SwiftUI、无 UIKit 桥接、MIT，是这类需求的事实标准）。

**试过的路**：
1. 作为 SwiftPM 依赖加进 `project.yml` → **Xcode 27 加载工程时直接挂死**
   （`xcodebuild -list` 60 秒不返回，`-resolvePackageDependencies` 输出空列表，
   包永远不会被解析）。不带包引用时同一个工程秒开 —— 与本机环境有关，不是配置问题。
2. Vendored（像 IrohLib 那样把源码搬进工程内 target）→ 需要连
   `swift-cmark`（C 库，带 modulemap）+ `NetworkImage` 一起搬，
   加起来约 5 MB 源码。对一个"把表格画对"的需求不成比例。

**决定**：自己写**块级**解析 + 排版（`MarkdownParser` + `MarkdownBody`）：
标题、段落、代码块、**表格**、列表、引用、分隔线、单独成段的图片。
内联（粗体/斜体/行内代码/链接）继续用系统自带的 `AttributedString(markdown:)` —— 那部分不用自己写。

**后果**：
- 零新依赖，符合 ADR-0006；
- 解析是纯函数，可单测（表格容错、`---` 与列表标记的歧义、代码块里不解析表格…都钉住了）；
- 能力边界明确：**没有** HTML 内联、脚注、任务列表勾选框这些。真需要时再评估；
- **隐私红利**：正文里的远程图片**刻意不加载**。这个 App 的承诺是"所有流量都只去你自己的电脑"，
  引一个会自动拉 `http(s)` 图片的渲染库就破坏了这个承诺。现在远程图片渲染成一行占位，
  并写明"未加载：只从你的电脑取数据"。

## ADR-0014 · 权限档位走「斜杠命令」，不走 `settings/*`

**日期**：2026-10-12
**背景**：用户要求"读写权限必须加入设置"。查了 DSH 安装里**全部** Remote 方法：
`permissionPresets` 只暴露 `catalog`（只读），没有任何写方法。
**决定**：改权限走 **`commands/execute`** 跑 `dsh-permission-presets` 注册的
斜杠命令 `/permission <preset>`；读走 `permissionPresets/catalog`。
**后果**：
- 这是"改**当前会话**权限"的唯一入口。`settings.mutate` 改的是"新会话的默认档位"，
  语义不同（[DESIGN.md](DESIGN.md) §4.2 本来也把 `settings/*` 排除在一期之外）；
- 线上形状有个坑：agent scope 是**放进 `args` 里**的
  （`{args:{agentId, line, submittedAttachments}}`），放 payload 顶层会被拒
  （`Remote payload must contain exactly one plain-object args field`）；
- 危险档位（`danger-full-access`）要先确认再改，并且如实说明"减少确认步骤、
  包括敏感操作与外部命令"，不美化也不恐吓；
- 自动化测试里**只跑不带参数的 `/permission`**（它只打印当前档位，不改任何东西）。

## ADR-0015 · 设置里不再暴露"连接方式"，产品上只用 iroh

**日期**：2026-10-12（收窄 ADR-0009 与 ADR-0014 里那条直连网关的产品面）
**背景**：一期把"连接方式"做成了用户可见的三选一（远端 iroh / 开发直连 / 直连网关）。
但 iroh 已经覆盖全部真实场景，而三选一把内部实现细节摊给了用户 ——
选错就是"连不上"，而且没有任何理由让普通用户去理解 iroh 与 HTTP 网关的区别。
**决定**：
- 设置页移除「连接方式」整段；**默认且只用 iroh**；
- `TransportMode` 保留但降级为开发者模式，只在 DEBUG 构建里通过 `UserDefaults` 打开；
  打开后设置页顶部会出现一条「调试」提示与一键"改回 iroh"；
- `tools/direct-gateway.mjs`（含 `--host` / `--token`）**保留**，作为 iroh 走不通时的备用路
  与模拟器开发的 DEV-DIRECT。
**后果**：
- 用户侧零概念负担，默认路径就是对的那条；
- ADR-0009 的 DEV-DIRECT 能力没有丢，只是从 UI 挪到了 defaults（本来就是开发者用的）；
- 代价：如果将来真的需要"强制走某条路"（比如 iroh 在中转上很慢），得重新开一个入口 ——
  但那应该是"诊断页里的一个开关"，不是首屏设置。

## ADR-0016 · 会话内容落盘缓存，切会话不再等远程快照

**日期**：2026-10-12
**背景**：每次打开/切回一个会话都要等一次 `session/follow` 的远程快照（本机实测一个大会话
约 600 KB，走 iroh 时是秒级）。这是这个 App 最影响手感的地方。
**决定**：把折叠状态**落盘**，打开时先铺内容、再跟远程对齐。

三条原则（写进 `SessionCache` 的注释里）：
1. **正确性优先**：缓存只当"提示"，永远以宿主为准。恢复之后必须还能**继续增量折叠** ——
   所以存的是 `TimelineBuilder.State` **全量**（含 `surfaceNodes` / `toolCalls` / `approvals`
   这些索引），不是渲染用的条目数组。少一个索引，后续 `surfaceOp.replace` 就会算错区间、
   `tool/result` 就会合并不到对应的 `tool/call`。
2. **增量续拉，不整体重建**：快照只带最近 N 条消息，而我们手里可能有更早的。
   `TimelineBuilder.resume(with:)` 按 `seq` 合并、老条目留着；
   **但宿主的 `cursor` 落后于我们的 `lastSeq` 时返回 `false`**（日志被换过 / 缓存过旧），
   调用方退回整体重建。
3. **有界且可丢弃**：放在 `Caches/`（系统可回收），LRU 淘汰，总预算 32 MB、
   单会话上限 4 MB。单个会话超限就**不缓存**，而不是截断内容 ——
   截断过的工具输出比没有更糟。版本号对不上直接丢，不猜着读。

**后果**：
- 冷启动与切会话都是"秒开 + 后台校准"（实测：有缓存时 2.2 秒画面已完整，
  无缓存时同一时刻还是骨架占位）；
- 会话列表也缓存（冷启动第一屏不用等 `session/list`）；
- 代价：多了一份可能过期的本地副本。用 `resume` 的 cursor 校验 + 版本号兜住了；
  设置页有「清空缓存」，只影响速度、不丢东西。

## ADR-0017 · waterfall 的 `deferred`：用户没决定时**必须挂住**，不能回 `next`

**日期**：2026-10-12
**背景**：用户反馈"agent 提问支持得不是特别好"。查下来是个**功能性 bug**，不是观感问题：
界面上会正常弹出问题卡片，用户选完点提交 —— **什么都不会发生**，agent 一直等到超时。

**根因**：`EventStreamCoordinator.dispatch` 把应答回调返回的 `nil` 当成"我不答这条"，
立刻回 `{kind:'next'}` 并把 pending 清掉。而 `AppModel.route` 恰恰用 `nil` 表示
"用户还没决定，先挂着"。于是 waterfall 在卡片出现的那一瞬间就已经结案了，
之后 UI 调 `$events/result` 送答案，宿主那边早就不欠这条了。

**并且没有第二条路**：远端客户端**不可能**改用 `userQuestions/answer(callId)` 绕过它 ——
实测网关转发 waterfall 时会把 `wait` 整个剥掉，远端永远拿不到 `callId`：

```json
{"type":"waterfall","event":"user-questions/request","eventId":"…","agentId":"…",
 "request":{"questions":[…]}}          // 没有 wait，没有 callId
```

**决定**：把回调的返回值从 `JSONValue?` 换成显式的 `WaterfallDecision`
（`.answer` / `.next` / `.deferred`）。审批与提问一律 `.deferred`，
由 UI 走 `coordinator.respond(_:outcome:)` 结案 —— 从 `pending` 摘除与发送放在同一个地方，
"恰好一次应答"这条保证才守得住。
另加 `abandonmentHandler`：连接换代导致某几条作废时通知 UI 撤掉卡片，
否则用户会对着一个"点了没反应"的卡片反复点。

**后果**：
- 提问链路端到端打通，有活宿主测试钉住（`testUserQuestionRoundTripActuallyReachesTheAgent`：
  真的让 agent 提问 → 挂起 → 交答案 → 断言 agent 恢复并跑完、且日志里能看到所选内容）；
- 去重从 `eventId` 改成"**哪个会话的哪件事**"。宿主会把未决 waterfall **重放**给新客户端
  （重放带新 `eventId`），按 eventId 去重会让同一个问题变成两张卡片，
  用户很可能点中那张已作废的；
- "跳过"走 `{kind:'rejected', error:{…}}` 而不是 `next`：后者会让宿主继续等一个永不到来的
  回答、agent 挂到超时；拒绝能立刻把"用户跳过了"交给 agent；
- 顺带修掉一个抽取脚本的 bug：注释里举例的 `Text("\\(index + 1)")` 会被当成真调用点抽出，
  凭空多一条 key 为 `%lld` 的目录条目（之前那条 `%@` 误报同源）。现在抽之前先抹掉行注释。

## ADR-0018 · 审批的两个 id 不是一回事；批准前必须看得到要执行什么

**日期**：2026-10-12
**背景**：用户要求"审批这类互动场景一并优化"。做下来发现一个**功能性 bug**：
横幅显示"1 个待批准"，而会话里的审批卡片却写着"这条已经不能在这里回答了" ——
按钮根本不出现，等于**没法批准**。

**根因**：`approval/asked` 里有两个不同的 id，我当初假设它们是同一个：

```json
{"id":"81e8b850-f040-4349-a916-2af93eb3c974",   // 审批自身的 UUID
 "toolName":"bash",
 "callId":"call_00_T7rDK9OjMLkUZ2O9p3CG1129",   // 被审批的工具调用
 "reason":"escalate sandbox to danger-full-access: …"}
```

而 waterfall 里带的是 **`callId`**。按 `id` 去匹配永远匹配不上。
同一个假设还导致第二个后果：拿不到"要执行什么" —— 参数挂在 `tool/call` 上，也是按 `callId` 关联的。
所以之前用户是在**不知道将执行什么命令**的情况下点"批准一次"。

**决定**：
- `TimelineItem.Approval` 同时保留 `approvalId` 与 `callId`（缓存 schema 1 → 2，旧缓存直接丢）；
- 卡片按 `callId` 关联 waterfall，并按 `callId` 从时间线里取出工具参数；
- 卡片里**内联显示将被执行的命令**（折叠 4 行、可展开、可选中复制）；
- 理由优先用 waterfall 的 `displayReason`（宿主写好的**给人看**的那版，按 locale 选），
  退回 `reason`。之前只读 `reason`，留下的是 `escalate sandbox to danger-full-access: …` 这种机器话；
- 按钮是否可用只看**挂着的 waterfall**，不看时间线。时间线可能已经过期，两者不一致时
  给出诚实的说明（"这条已经不能在这里回答了"），而不是摆一对按不动的按钮。

**后果**：审批从"盲批"变成"看清楚再批"。全局待处理列表里拿不到参数（那需要目标会话的
时间线），所以那里老实说明"完整参数在「某某」那张卡片上"并标出所属会话 —— 横幅是全局的，
不说清属于谁，用户知道有人在等却不知道该去哪儿。

## ADR-0019 · 队列不在会话日志里；频道入口跟着 IM 插件走

**日期**：2026-10-12

### 队列（排队中的消息）

**背景**：用户反馈"在主机上排队的消息，在 App 里显示成已发送"。
**实测发现**：排队中的消息**根本不在会话日志里**。轮次跑着的时候发一条，
`session/page` 里一条 `user/message` 都没有；它只出现在 `inbox` **投影**里：

```json
{"inbox":{"next-turn":[{"content":[{"type":"text","text":"…"}],
                        "source":{"kind":"user","rpcId":"r2"}}],"next-step":[]}}
```

等下一轮真正开始，它才落进日志。所以：
- 主机上排队的那条，App **完全看不到**；
- 自己排队发的那条，只剩乐观插入的"发送中…"，看起来像已经发出去了。

**决定**：队列从 `projections.inbox` 读，在时间线末尾单独渲染成**虚线气泡** +
「N 条排队中」+ "电脑跑完这一轮就会发出去"。乐观插入的那条在进入队列后**撤掉**
（按 `rpcId` 对上），否则同一句话会显示两遍。

### 频道入口跟着 IM 插件走

**背景**：频道不是 App 的能力，是 IM 插件产生的效果。
**决定**：主机没装/没启用那个插件时**不显示「频道」这个入口** ——
点进去只会看到"没有频道会话"，然后怀疑是不是坏了。

判据是**启发式**（插件不声明自己产出什么，只能看名字）：
启用的插件名字里含 `im-connect` / `dsh-im` / `feishu` / `weixin` / `lark` / `instant-messag` 之类，
**或者**已经存在 `im:` 会话（插件后来被停用，但历史还在）。
本机实测那个叫 `@michengai/dsh-im-connect` —— **第三方**插件，所以不能只匹配官方前缀。
认不出时宁可少一个入口。插件被停用时，正在看的频道页会退回会话。

## ADR-0020 · 主机设置：只做能在协议里安全表达的那几项

**日期**：2026-10-12
**背景**：用户要求"主机最好能进行少量设置，至少包含插件开关、默认模型和思考等级"。
**决定**：在手机上提供两项，都走 DSH 原生协议：
- **插件开关**：`pluginManager/listPlugins` + `pluginManager/setPluginEnabled`（`{args:{id,enabled}}`）。
  `readOnlyReason` 是**能不能开关的权威说明**，不自己猜：`unaddressable`（没有可寻址位置）、
  `management-required`（管理插件不给自己开关自己）。不能开关的显示锁 + 原因，
  而不是摆一个灰开关让人猜。**停用要确认**（可能把正在用的能力掐掉），启用直接生效。
- **默认模型 / 思考等级**：`settings/describe` + `settings/mutate`
  （命名空间 `agent-default-model`，ops 形如 `{op:"set", path:["model"], value}`）。
  写的时候带 `expectedRevision` —— 乐观并发控制，别人改过就会被拒，而不是悄悄覆盖。

**刻意不做**：密钥、沙箱、搜索这些其余设置。手机上改它们既危险又没必要，
电脑上改更合适。文案里也写清"默认模型只影响之后新建的会话"，
免得跟会话菜单里的"切换模型"混起来（那是改当前会话）。

## ADR-0021 · 轮次收拢：跑完的轮次只留一行摘要 + 最终结论

**日期**：2026-10-13
**背景**：用户要求"参考 desktop 的效果，轮次运行结束时把前面的思考、命令执行统一收拢"。
一个跑了半小时的轮次能刷出几十屏，真正要回看的往往只有最后那段话。
**决定**：`TimelineBuilder.timelineBlocks()` 把条目按轮次分组
（`turn/start` 开、`turn/end` 关，轮次之外的条目照常独立显示）：

- **跑完的轮次**：明面上只有一行 `✓ 已完成 · 用时 X · N 步` + **最终结论**，
  中间的思考、命令、过场说明全部折叠进去，点摘要行展开；
- **还在跑的轮次**：**照常全展开** —— 正在发生的事没有收拢的道理。

两处细节：
- **时长**协议里没有现成字段，用 `turn/start` 与 `turn/end` 的 `time` 相减算；
- **"最终结论"取最后一个有正文的助手消息**，中间那些"我先看一下…"跟工具行一起收起来。

**顺带修掉一个空白卡片的 bug**：`hasRenderableContent` 原来把 `.toolCall` 也算作"有内容"，
但助手卡片对 `.toolCall` 渲染的是 `EmptyView`（工具走单独的 `ToolRow`）——
于是"只声明了一个工具调用"的助手消息会渲染成一张**只有时间、没有任何文字的空白卡片**。
用户截图里的那几张空白行就是它。

> 这个 bug 我改过一次又被后续编辑覆盖回去了 —— 是新增的测试
> （`testAssistantMessageWithOnlyToolCallsIsNotRenderable`）把它抓回来的。

## ADR-0022 · 输入框里的权限/上下文/统计，与消息级操作

**日期**：2026-10-13
**背景**：用户要求把输入框做成桌面端那样（直接改权限、显示用量与上下文、显示会话统计），
并给消息补上复制、点赞点踩、分支、用量。
**决定**：

**输入框**（照桌面端的布局：输入框占整行，工具一行，统计一行）
- **权限档位**直接放在输入框里 —— 它是"这次任务怎么跑"的一部分，跟打字是同一个动作。
  之前藏在右上角 `⋯` 菜单里，每次都要点两层。
- **上下文占用条**：`projections.contextPressure`，超过 85% 变橙。
  这是"还能聊多久"的唯一线索 —— 快满时模型会开始压缩历史。
- **统计行**：`projections.sessionStats` + `tokenUsage` →
  `33 轮 · 1156 步 · 首字 11.8s · 100 tok/s · 缓存 98%`。

**消息操作**：复制 / 👍 / 👎 / 分支 / 用量，放在页脚跟时间同一行 ——
这些是**回看时**才需要的动作，不该占据正文的注意力。

**三处协议坑**（都是探出来的，不是读出来的）：
1. `messageFeedback/put` 的**线上形状是扁平的**：
   `{request:{sessionId, messageId, rating, ifVersion}}`，
   不是那个带 `item` 的 TS 接口。`ifVersion` **必填**，没有就传 `null`。
2. **版本冲突是业务级拒绝**（HTTP 200 + `value.ok == false` + `error.code == "version-conflict"`），
   不是传输错误。不显式识别的话调用方会以为"保存成功了"，而实际什么都没写。
   现在 `DSHClientError.isVersionConflict` 识别它，`SessionModel` 会**重新拉取再重试一次** ——
   用户只是点了个赞，不该看到"版本冲突"这种词。
3. 缓存命中率的**分母是提示词总量**（未命中 + 命中），不是 `total` ——
   后者把输出算进去了，比例会被输出长度稀释，跟桌面端对不上。

**顺带修掉一个本地化漏洞**：`gen-strings.py` 只扫 `DSHPocket/`，
而 `DSHKit` 里也有 `String(localized:)`。它是**静态库**，链接进 App 后
`String(localized:)` 走的就是 App 的目录 —— 不扫它那些文案会漏翻译
（英文界面上直接显示中文）。现在也扫 `DSHKit/Sources` 与 `TetherKit/Sources`，
一扩就多找出 24 条。
