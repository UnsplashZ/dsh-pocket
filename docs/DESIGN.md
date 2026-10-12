# DSH Pocket — 设计方案

> **v0.2 · 2026-10-12** · 面向：实现者
> 相对 v0.1 的方向性变更：**移动端从"Tauri + 自研 Web UI"改为 iOS 原生 SwiftUI，严格遵循 Apple HIG。**
> 上游基线：DSH `0.2.0-rc.2`（本机实测）· 传输对照：`dsh-plugin-tether@0.1.20` + `iroh 1.0.3`

---

## 1. 问题陈述

见 [WHY-NOT-INJECTION.md](WHY-NOT-INJECTION.md)。一句话：tether 靠 **16 KB 注入 CSS/JS** 把 DSH 的桌面网页掰成竖屏，在 iPhone 上实测碎（叠字、重绘残留、命中与画面不一致），且依赖哈希类名与隐式 DOM 状态位，上限只是"能看能点"。

**传输层是好的**：iroh P2P 打洞、6 位配对、DLP 线协议、电脑侧 cookie 兑换与逐请求注入、手机侧 TCP 代理 —— 全部保留。

**界面层重写**：不再让手机渲染 DSH 的网页，而是用 **Swift + SwiftUI 原生渲染**，直接消费 DSH 的客户端协议。

---

## 2. 目标与非目标

### 2.1 目标

| # | 目标 | 可验收的判据 |
|---|---|---|
| G1 | **iOS 原生**：Swift + SwiftUI，无 WebView 参与会话渲染 | 工程内不存在任何加载 DSH 页面的 `WKWebView` |
| G2 | **严格遵循 Apple HIG** | 通过 [IOS-DESIGN.md](IOS-DESIGN.md) 的 HIG 自检清单；支持动态字体 AX1–AX5、深色模式、VoiceOver、降低动态效果 |
| G3 | 完成一轮完整对话 | 列表 → 流式时间线 → 发消息 → 打断 → 处理工具调用 → 批审批/答提问 |
| G4 | 复用既有传输，**电脑端零改动** | 客户端能与**当前已安装的** `dsh-plugin-tether` sidecar 配对并跑通协议 |
| G5 | 手感"像系统 App" | 原生导航转场、下拉刷新、滑动手势、上下文菜单、触感反馈、分享面板 |
| G6 | 不依赖 DSH 的 DOM/CSS | 代码中不出现任何 DSH 的类名/选择器 |

### 2.2 非目标

- **Android 一期不做**：本方案只交付 iOS。方案保留 Android 的可行性（见 §3.5），但不投入。
- 不复刻 DSH 桌面端全部设置页；凭据、插件市场、Agent 预设编辑留在电脑上。
- 不重写传输；**不分叉 tether 的电脑端**（理想情况下一行都不改）。
- 不改 DSH 上游。
- 不做"手机本地跑 dsh"（tether 的 Android 本地模式不在本期范围）。

---

## 3. 架构

### 3.1 分层

```
┌─ iPhone · DSHPocket.app (SwiftUI) ──────────────────────────────┐
│  Features/        会话列表 · 时间线 · 输入区 · 审批卡 · 文件 · 设置 │ ← 新写（SwiftUI）
│  DesignSystem/    语义色/动态字体/SF Symbols/触感/转场             │ ← 新写
│  DSHKit (SwiftPM) DSH 客户端协议层：RPC · mux · 事件 · 投影        │ ← 新写（Swift）
│  TetherKit (SwiftPM)                                               │
│    · iroh-ffi（官方 Swift 绑定，预编译 xcframework）               │ ← 复用官方
│    · DLP 线协议（≈400 行，移植自 tether-core，保持线兼容）          │ ← 移植
│    · 本地 TCP 代理（127.0.0.1:<派生端口> → iroh 代理流）            │ ← 移植
│  系统服务        通知 · 分享 · 文件 · 相册 · 触感 · 后台刷新        │ ← 原生 API
└─────────────────────────────────────────────────────────────────┘
        ⇅ QUIC / iroh（ALPN `dsh-tether/0`，preset N0）
┌─ Mac ───────────────────────────────────────────────────────────┐
│  dsh-plugin-tether（**原样不动**）                                │
│   · iroh endpoint + 配对窗口 + 设备公钥白名单                      │
│   · cookie 兑换（connection.authenticatedUrl → 303 → Set-Cookie） │
│   · 代理流：注入 cookie / 改写 Host → 127.0.0.1:19387              │
└─────────────────────────────────────────────────────────────────┘
        ⇅ 本机回环
      DSH host（0.2.0-rc.2，不改上游）
```

### 3.2 复用 / 替换边界

| 能力 | 归属 | 动作 |
|---|---|---|
| iroh 打洞 / 中转回退 / QUIC 加密 | 客户端用 **官方 iroh-ffi**；电脑端用 iroh 1.0.3 | **复用**（两侧都用官方实现对同一个线协议） |
| 配对窗口、设备公钥白名单、cookie 兑换、逐请求注入、Host 改写 | `dsh-plugin-tether`（电脑端） | **原样复用，零改动** |
| DLP 线协议（控制流 + 代理流） | 契约在 `tether-core/src/lib.rs` | **移植到 Swift**（小、稳定、线兼容） |
| 手机侧 TCP 代理 + 端口派生 | tether 的 Rust 客户端 | **移植到 Swift**（保端口公式，见 [TRANSPORT.md](TRANSPORT.md) §4） |
| DSH 客户端协议（RPC/流/事件/投影） | 无现成 Swift 实现（`DSH_Mobile` 的 DSHKit 可作参考） | **新写**（Swift） |
| 会话/时间线/审批/文件的界面 | —— | **新写**（SwiftUI，见 [IOS-DESIGN.md](IOS-DESIGN.md)） |
| 16 KB 注入 CSS/JS、代理 DSH 桌面页 | `dsh-plugin-tether`（电脑端） | **本项目不使用**（客户端永不请求那个页面）；是否顺手删掉留给上游 |

**一句话**：电脑端一行不改；客户端用官方 iroh Swift 包 + 约 400 行 DLP 移植 + 全新的 DSH 协议层与原生界面。

### 3.3 为什么是"纯 Swift 客户端"，而不是把 tether 的 Rust 桥进来

| 方案 | 结论 |
|---|---|
| **A. 纯 Swift**：iroh-ffi（官方、预编译 xcframework）+ 自己写 DLP + 协议层 | ✅ **选定**。无 Rust 工具链、无 UniFFI 胶水、无跨语言调试；客户端一种语言；DLP 很小（`Wire` 枚举只有 8 种消息） |
| B. 分叉 tether 的 Rust，用 UniFFI 暴露给 Swift | ✗ 多一层语言边界，构建复杂度与调试成本翻倍，收益只是省下 ~400 行移植 |
| C. 继续 Tauri + 自研 Web UI | ✗ 与 G1/G2/G5 冲突（用户明确要求原生与 HIG） |
| D. 直接用 `DSH_Mobile` 的现成 Swift 客户端 | ✗ 它是 relay-only（无 P2P）、iOS 端未真机验证（[issue #6](https://github.com/jayantTang/DSH_Mobile/issues/6) 同类问题）、UI 与 HIG 要求未必一致。但**它的协议文档与 Swift 层是重要参考**，见 §3.4 |

### 3.4 与既有项目的复用关系（全部 MIT，需保留版权声明）

| 项目 | 我们取什么 |
|---|---|
| [zexadev/dsh-tether](https://github.com/zexadev/dsh-tether) | **电脑端原样使用**；`tether-core` 的 `Wire` 定义与代理流语义作为线协议契约；端口派生公式、`Info.plist`(ATS/本地网络) 配置作为对照 |
| [jayantTang/DSH_Mobile](https://github.com/jayantTang/DSH_Mobile) | [`docs/DSH-PROTOCOL.md`](https://github.com/jayantTang/DSH_Mobile/blob/main/docs/DSH-PROTOCOL.md)（协议权威参考）、[`docs/dsh-rpc-catalog.json`](https://github.com/jayantTang/DSH_Mobile/blob/main/docs/dsh-rpc-catalog.json)（端点目录）；其 `DSHKit` 的 Swift 结构可作设计参考（**不直接复制代码**，避免把未验证的实现带进来） |
| [n0-computer/iroh-ffi](https://github.com/n0-computer/iroh-ffi) | Swift 包 `IrohLib`（v1.1.0），预编译 xcframework |
| [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) | 上游；只作为客户端消费其协议 |

### 3.5 Android 的将来（本期不做）

同一套 `DSHKit` / `TetherKit` 逻辑可以用 Kotlin 重写（iroh-ffi 同样提供 Kotlin 绑定），或用 Kotlin Multiplatform 共享协议层。**本方案不为此做任何妥协设计**，只保证协议层不写死 iOS 特有 API。

---

## 4. 协议层（`DSHKit`，Swift）

> 事实依据：[PROTOCOL-NOTES.md](PROTOCOL-NOTES.md) + [PROTOCOL-0.2.0-rc.2.md](PROTOCOL-0.2.0-rc.2.md)（已在本机实测通过的部分）。

### 4.1 模块

```
DSHKit/
  Transport/
    RPCClient.swift          # POST /api/<method>（URLSession），判 result.ok 而非 HTTP 状态
    MuxClient.swift          # 单条 URLSessionWebSocketTask /api/remote.mux 上的多路复用
    Frames.swift             # open/cancel 上行、item/error/end 下行
  Events/
    EventStream.swift        # $events：ready 世代、emit、waterfall
    Waterfall.swift          # 必须应答 $events/result；不能答就回 {kind:'next'}
  Sessions/
    SessionList.swift        # session/list（含 projections，够撑列表页）
    SessionFollow.swift      # session/follow：snapshot + 增量 + assistant-stream
    SessionPage.swift        # session/page（必须带 throughSeq）
    SessionActions.swift     # prompt / cancel / rename / selectModel / updateQueue
  Model/
    Timeline.swift           # SessionWireEvent → 视图模型；**必须实现 surfaceOp.replace**
    Projections.swift        # 会话投影（title/goal/todos/tokenUsage/contextPressure…）
    Attachments.swift        # session/attachment（base64）与文件
  Support/
    CapabilityProbe.swift    # 启动自检 + 宿主版本区间判定
    Retry.swift              # 500ms→10s 上限 + 抖动（与 DSH 客户端一致）
```

### 4.2 一期端点子集（约 20 / 47）

`$events` + `$events/result`、`session/list`、`session/follow`、`session/page`、`session/prompt`、`session/cancel`、`session/modelCatalog`、`session/selectModel`、`session/create`、`session/rename`、`session/updateQueue`、`workspace/follow`、`workspaceFiles/list|stat|read`、`session/attachment`。

**不做**：`settings/*`、`credentials/*`、`skills/list`、`directoryPicker/*`（`pick` 会在电脑上弹系统对话框）、`session/search`（本部署默认关）、`session/fork`。

### 4.3 三条事件通道（最易混淆）

| 通道 | 内容 | 来源 | 应答 |
|---|---|---|---|
| 转发应用事件 | `ready`/`emit`/`waterfall` | `$events` | 仅 `waterfall` |
| **持久会话事件** | `turn/start`、`step/start`、`assistant/message`、`tool/call`、`tool/result`、`user/message`、`approval/*`、`todo/write`、`compaction/*`… | **`session/follow`** | 永不 |
| 客户端实时帧 | `{type:'assistant-stream'}` | `session/follow`（`assistantStream: true`） | 永不 |

**聊天界面要的一切都在 `session/follow`，不在 `$events`。**

### 4.4 时间线渲染的硬要求

1. **`surfaceOp`**：`{op:'replace', startSeq, endSeq}` 表示该事件**取代**区间内的 surface 节点（压缩会这么做）。必须按区间重算，否则显示重复内容。
2. **快照很大**：本机实测单会话快照 **831 KB**。首帧到达即出骨架，随后分批入视图；不要等完整解析再渲染。
3. **`assistant-stream` 自带 `attemptId`/`revision`/`index`** → 流式渲染可去重、可重放，不依赖到达顺序。
4. **`session/page` 要 `throughSeq`**（取自 follow 快照的 `cursor`）才能向上补历史。

### 4.5 断线、世代、重连

- `$events` 首帧 `ready` 绑定 **client generation**；重连后旧 `clientId` 失效，宿主会把未决 waterfall 重放到新世代；
- 恢复：重开 WS → `ready` → `session/follow` 按本地最后 `seq` 续拉（或重取快照 + `page` 补历史）；
- 退到前台立即重连（iOS 不允许常驻后台连接，见 §9）；
- UI 必须区分三态：连接中 / 已断开（可重试）/ 正在补历史。

---

## 5. 界面（SwiftUI）

**完整规范见 [IOS-DESIGN.md](IOS-DESIGN.md)**（导航架构、逐屏规格、组件清单、HIG 自检清单、无障碍、本地化、通知、隐私清单）。要点：

- **导航**：iPhone 用 `NavigationStack`（会话列表 → 会话）；iPad 用 `NavigationSplitView`（两栏）。**不做自绘侧栏/抽屉**。
- **会话页**：`ScrollView` + `LazyVStack` 时间线，输入区用 `.safeAreaInset(edge: .bottom)` 常驻；工具调用折叠成一行，点开看参数/结果。
- **审批**：时间线内卡片 + 本地通知（带操作按钮），点通知回到该卡片。
- **原生能力优先**：`.refreshable`（下拉刷新会话列表）、`swipeActions`（重命名/归档）、`contextMenu`、`ShareLink`、`.fileImporter`、`PhotosPicker`、`.sensoryFeedback`（发送/完成/失败/审批）、`.textSelection(.enabled)`。
- **无障碍是一等要求**：动态字体到 AX5、VoiceOver 标签与 trait、降低动态效果、增强对比度、44pt 触摸目标。

---

## 6. 电脑端

**不改。** 现有 `dsh-plugin-tether@0.1.20` 提供的一切（配对、白名单、cookie 注入、代理流）就是本方案需要的全部。

可选（非本期）：给上游提 PR，把"代理 DSH 桌面页 + 注入 CSS"这段改成可选开关（对纯原生客户端无用）；顺手修 `navList` 漏复位 `overflow-y` 的问题（见 [WHY-NOT-INJECTION.md](WHY-NOT-INJECTION.md) §2.1）。

---

## 7. 开发与验证流程

### 7.1 三种开发模式（按依赖从少到多）

| 模式 | 目标 | 用途 |
|---|---|---|
| **DEV-DIRECT**（DEBUG 编译标志） | 直连 `http://127.0.0.1:8788`（Mac 上的 dev 代理，自动附 cookie，转发到 `127.0.0.1:19387`） | 纯 UI 与协议开发，**不需要 iroh、不需要配对、不需要手机**；模拟器即可 |
| **DEV-LOCAL** | 与本机 iroh sidecar 走真实 P2P 环回 | 验证传输层 |
| **REL-REMOTE** | 正常远端路径（P2P / 中转） | 真机验收 |

DEV-DIRECT 的价值：把 95% 的工作（界面 + 协议 + 时间线渲染）从"必须真机 + 必须配对"里解耦出来。

### 7.2 真机

- 已有可用链路：`dsh-tether/ios-dist/resign-install.sh`（未签名 IPA 重签 + `devicectl` 装机）可用于**参考**；本项目自己的工程直接 `xcodebuild -allowProvisioningUpdates` + `xcrun devicectl device install app`。
- 免费个人团队证书 7 天过期 → 写一个 `scripts/install-device.sh` 固化流程（含描述文件续期）。
- 截图：`xcrun devicectl device capture screenshot`（本机实测可用；`screen-record` 在 iPhone 15 Pro 上不受支持）。

### 7.3 协议回归

`docs/artifacts/samples/` 放脱敏抓包（已 gitignore）；DSH 升级后跑 `tools/` 下的探针 diff 差异。**任何"宿主升级后 App 崩了"的问题，第一步都是跑探针，而不是看 App。**

---

## 8. 里程碑与验收

详细任务清单见 [ROADMAP.md](ROADMAP.md)。

| 阶段 | 内容 | 验收（真机 iPhone） |
|---|---|---|
| **M0a** 协议 spike | 本机探针（已部分完成）+ Swift `DSHKit` 骨架 | 能用 Swift 列会话、订阅会话流、发消息、收并发事件 |
| **M0b** 传输互通 | iroh-ffi Swift ↔ 现有 sidecar | 配对成功、代理流打通、`/api` 请求 200 |
| **M1** 只读客户端 | 会话列表 + 时间线（历史/实时）+ 重连 + 空/错/离线态 | 滚动流畅无残影；动态字体 AX1/AX5 都不破；深色模式正常 |
| **M2** 可交互 | 输入区、发消息/打断、模型切换、工具折叠、审批/问答、图片文件 | 完整跑一轮"提需求 → 看工具 → 批一次审批 → 收结果"；审批通知可点 |
| **M3** 打磨与 HIG 审计 | IOS-DESIGN 自检清单全过、触感、分享、iPad 分栏、无障碍逐项测 | 清单 100% 通过；VoiceOver 能完成"发一条消息"全流程 |
| **M4** 分发 | TestFlight（需付费账号）或自签安装脚本 | 全新设备 0→可用 ≤10 分钟 |

---

## 9. 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| **iroh-ffi ↔ 宿主 iroh 版本互通**（宿主 1.0.3；ffi 1.1.0） | 连不上，全盘受阻 | **M0b 专门消除**：第一件事就是用一个最小 Swift 程序连上现有 sidecar 并跑通 Hello + 代理流 |
| iroh-ffi 尚年轻（v1.1.0） | API 变动 / 缺能力 | 把 iroh 使用面压到最小（bind / connect / open_bi / accept_bi / secretKey）；锁定版本；必要时可用 `cargo make swift-xcframework` 自建 |
| iOS 不允许常驻后台连接 | 退到后台即断 | 前台保持连接；后台只保留通知；回前台立即重连并按 `seq` 补齐（HIG 与系统限制下的正解） |
| **本地网络权限**（iOS 14+，tether issue #6 的教训） | 同 Wi-Fi 直连静默失败 | 保留 `NSLocalNetworkUsageDescription`；第一条同网段连接必须能触发系统询问；提供"仅蜂窝可用"的诊断路径 |
| 免费团队签名 7 天过期 | 自用摩擦 | `scripts/install-device.sh` 固化续签；长期建议付费账号（同时解锁 TestFlight + APNs） |
| **App Store 审核**（若公开发布） | 被拒 | 这是"连接用户自有电脑的客户端"，需在审核说明里讲清并提供可用凭据；同时注意 4.2（最低功能）、5.1.1（隐私）；**一期走 TestFlight/自签，不追求上架** |
| DSH 协议漂移（0.1.5-rc.1 → 0.2.0-rc.2 已变过） | 升级即碎 | `CapabilityProbe` 启动自检 + 明确的不兼容文案；协议层独立可单测；版本区间记录在 README |
| APNs / 后台通知需付费账号 | 锁屏通知能力受限 | 一期用**本地通知**（App 在后台仍可收，只要进程未被回收）；APNs 作为付费账号后的增强 |
| 电池与流量 | 移动端体验 | 列表页只靠 `session/list` 的 `projections`（不开流）；只对**当前显示的会话**开 `session/follow`；退到后台断开 |
| 上游自己做移动端 / tether 转向 | 重复劳动 | 协议层与传输层保持可独立复用；电脑端零改动使其可与任何客户端共存 |

---

## 10. 目标仓库结构

```
dsh-pocket/
  README.md
  docs/
    DESIGN.md               # 本文
    IOS-DESIGN.md           # Apple HIG 规范：导航/逐屏/组件/无障碍/本地化/通知
    TRANSPORT.md            # iroh + DLP 线协议 + Swift 客户端实现配方
    PROTOCOL-NOTES.md       # DSH 客户端协议事实（传输/认证/端点/坑）
    PROTOCOL-0.2.0-rc.2.md  # 按本机版本实测的协议结论
    WHY-NOT-INJECTION.md    # 为什么放弃注入式适配（真机证据）
    ROADMAP.md              # 里程碑任务清单（可勾选）
    DECISIONS.md            # 决策记录（ADR）
    GLOSSARY.md             # 术语表
    artifacts/              # 截图证据；samples/ 放脱敏抓包（gitignore）
  ios/
    DSHPocket.xcodeproj
    DSHPocket/              # App：Features/ DesignSystem/ Resources/
    DSHKit/                 # SwiftPM：DSH 客户端协议层
    TetherKit/              # SwiftPM：iroh-ffi 封装 + DLP + 本地代理
  tools/
    mint-cookie.cjs         # 本机签发会话 cookie
    dev-proxy.mjs           # DEV-DIRECT 用的注入 cookie 的代理
  spikes/                   # 一次性验证脚本（Node/Swift）
  scripts/
    install-device.sh       # 真机构建 + 装机 + 证书续期
```

---

## 11. 开放问题

1. **iroh-ffi 与宿主 1.0.3 的互通**（M0b 必须先证实）。
2. `session/prompt` 的完整参数与流内事件序列；`session/cancel` 的成功判据。
3. 图片/文件的正确路径：`session/attachment`（base64）还是文件上传路由？后者在原生客户端下如何鉴权？
4. `present` 产物（图片、HTML 报告）如何取回与展示（分享面板/Quick Look？）。
5. 会话列表是否需要 `workspace/follow` 才能正确分组，还是 `session/list` 的 `cwd` 足够。
6. 通知：一期本地通知在 App 被杀后完全失效，是否需要在一期就引入 APNs（取决于是否有付费账号）。
7. 中文/英文本地化跟随 App 语言还是 DSH 设置（tether 的取舍是"各随其主"）。
8. 是否需要在 App 内暴露"重启/停止 DSH 主机"这类运维动作。
