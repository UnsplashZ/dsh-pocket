# DSH Pocket — 设计方案

> Draft v0.1 · 2026-10-12 · 面向：实现者
> 上游基线：DSH `0.2.0-rc.2`（本机实测版本）· 协议参考基线：`dsh-protocol.md`（对 DSH `0.1.5-rc.1` 活服务器核对）

---

## 1. 问题陈述

### 1.1 现状

[dsh-tether](https://github.com/zexadev/dsh-tether) 的做法是：

```
iPhone (Tauri)                                     Mac
┌─────────────────────────┐                    ┌──────────────────────────┐
│ 自带壳 UI（main.js）      │                    │ dsh-plugin-tether        │
│  └ iframe src=代理URL ───┼──iroh P2P 隧道────┼─► 127.0.0.1:19387        │
│                          │   (DLP v1)         │      DSH 自己的 Web UI   │
│  代理把 DSH 的 index.html │                    │  + 注入 23KB CSS/JS 适配  │
│  连同注入一起交给 WebView  │                    │    手机竖屏              │
└─────────────────────────┘                    └──────────────────────────┘
```

也就是说：**手机上看的是 DSH 的桌面界面**，只是被一段注入样式"掰"成了竖屏。

### 1.2 这条路的天花板与地板

| 维度 | 现状 |
|---|---|
| 适配手段 | 注入 CSS/JS（`ctx.webServer.tapIndex()`），只在 `≤640px` 生效；实测 **16 KB**（CSS 4.7 KB + JS 11.8 KB） |
| 依赖的锚点 | `[class*="_frame"]`、`[class*="_handle"]`、`navList`、`navCell`、`footArea`、`footerActions`、`rowText` —— 全是**哈希类名的子串匹配** |
| 状态推断 | "抽屉是否展开" = `_frame` 是否有直接子元素 `*_handle`（用拖拽把手存在与否当作隐式状态位） |
| 真机结果 | iOS WebView 上**设置弹窗导航叠字 / 重绘残留 / 画面与命中区域不一致**（见 [WHY-NOT-INJECTION.md](WHY-NOT-INJECTION.md)） |
| 与第三方插件 | 与 `dsh-better-sidebar`（大改侧栏 DOM）天然冲突；注入里已经为 `dsh-cost-meter` 打过补丁 |
| 每次 DSH 升级 | 哈希类名/结构一变，注入就退化成"看运气" |

结论：**这段注入能维持"能看能点"，但它是不可修的负债**。移动端要一等公民体验，必须自己渲染界面。

---

## 2. 目标与非目标

### 2.1 目标

1. 手机上完成一轮完整对话：**看会话（历史 + 实时流）→ 发消息 → 打断 → 处理工具调用 → 批审批 / 答提问**。
2. **真机 iPhone 上流畅**：滚动 60fps 观感、点击即中、无重绘残留。
3. **一套代码两端**：iOS + Android 共用 UI 与协议层（这与 tether 的 Tauri 技术选择一致）。
4. **不依赖浏览器巧合**：不注入任何 CSS、不依赖 DSH 的 DOM 结构或类名。
5. 复用传输层，**不改 DSH 上游源码**。

### 2.2 非目标

- 不复刻 DSH 桌面端全部设置页（凭据、插件市场、Agent 预设编辑等留在电脑上）。
- 不重写传输层（iroh / 配对 / 中转 / 加密继续用 tether）。
- 不做 DSH 内核或插件的分叉维护。
- 一期不做"手机本地跑 dsh"（沿用 tether 的本地模式即可，不重做）。

---

## 3. 总体架构

### 3.1 分层图

```
┌─ iPhone / Android ───────────────────────────────────────────────┐
│  Pocket UI（移动优先 SPA：会话列表 / 时间线 / 输入区 / 审批卡）      │  ◀ 新写
│  pocket-protocol（TS：RPC / 流 / 事件 / 会话投影 / 重连）           │  ◀ 新写
│  传输：沿用 tether 手机侧（iroh + TCP 代理 + 配对 + 多主机 + 通知）  │  ◀ 复用
└──────────────────────────────────────────────────────────────────┘
                      ⇅ DLP v1（复用，不改协议）
┌─ Mac：dsh-plugin-pocket（dsh-tether 的宿主插件分叉）───────────────┐
│  cookie 兑换（authenticatedUrl → 303 → Set-Cookie）                │  ◀ 复用
│  逐请求注入 cookie / 改写 Host（tether-core: rewrite_request_head） │  ◀ 复用
│  iroh endpoint + 配对窗口 + 设备白名单                              │  ◀ 复用
│  ★ 新增：静态托管 Pocket SPA（`/pocket/*`），与 /api 同源           │  ◀ 新写（很小）
│  ✗ 删除：把 DSH 桌面 index.html 交给手机、注入窄屏 CSS/JS            │  ◀ 移除
└──────────────────────────────────────────────────────────────────┘
                      ⇅ HTTP + WS（同源）
                     DSH host（127.0.0.1:<port>，不改上游）
```

### 3.2 复用 / 替换边界（这是本方案的核心）

| 能力 | 归属 | 动作 |
|---|---|---|
| iroh 打洞、公网中转回退、重连与背压 | tether 手机侧 + `tether-host` sidecar | **复用**（不动） |
| 6 位配对码、设备身份（iroh 公钥）、白名单增删 | 同上 | **复用** |
| DLP v1 帧协议 | `tether-core` | **复用**（不动） |
| 电脑侧浏览器认证 cookie 兑换与逐请求注入 | `dsh-plugin-tether/index.js` | **复用**（不动） |
| 手机侧 TCP 代理（`127.0.0.1:<按主机派生的端口>`） | `app/src-tauri/src/lib.rs` | **复用**（不动） |
| 手机壳（多主机列表、改名/删除、语言、顶部状态条） | `app/ui/*` | **复用**，只改一处：iframe 指向 `/pocket/` 而不是 `/` |
| 窄屏 CSS/JS 注入（23KB） | `index.js` `injectNarrowScreenCss()` | **整体删除** |
| 会话/时间线/审批/文件的呈现 | —— | **新写**（本文档 §5–§6） |
| DSH 客户端协议消费 | —— | **新写**（TS，本文档 §4） |

一句话：**传输、配对、认证、隧道全留；"界面怎么来"从"代理桌面 UI"换成"自己渲染"。**

### 3.3 为什么新增"托管 SPA"这一小块

手机 WebView 里，如果 Pocket UI 由 App 自身来源（`tauri://localhost`）提供，它去请求 `http://127.0.0.1:<port>/api` 就是**跨源**；而 DSH 的 `/api` 信任栅栏要求 `Origin` 必须等于 `Host`，否则 403（[PROTOCOL-NOTES](PROTOCOL-NOTES.md) §2.3）。所以：

- **方案 A2（选定）**：宿主插件在 `/pocket/*` 静态托管 Pocket SPA。手机 iframe 加载 `http://127.0.0.1:<port>/pocket/` —— **与 `/api` 同源**，代理又会给每个请求注入 cookie，于是：
  - 无需 CORS、无需在客户端处理 token/cookie；
  - 开发时还能直接在电脑浏览器打开 `http://127.0.0.1:19387/pocket/` 迭代 UI（DX 极好）；
  - 宿主侧新增代码量极小（一条 prefix 路由 + 读文件 + mime）。
- 方案 A3（备选）：把协议层放进 Rust，手机 UI 走 Tauri IPC 调用。更"原生"、后台能力更强，但要在 Rust 里重写一遍 RPC/流，工作量与维护成本翻倍。**除非 M3 通知/后台被证明必须由 Rust 承担，否则不用。**

---

## 4. 协议层设计（`pocket-protocol`）

> 事实依据：[PROTOCOL-NOTES.md](PROTOCOL-NOTES.md)。**M0 必须按 `0.2.0-rc.2` 重新核对**，本文只给结构与取舍。

### 4.1 模块划分

```
pocket-protocol/
  transport.ts     # POST /api/<method>（unary）+ 单条 WS /api/remote.mux 的 open/cancel/item/error/end
  mux.ts           # streamId 分配、多路复用、取消、错误帧 → 异常
  events.ts        # $events：ready 世代绑定、emit、waterfall（必须答 $events/result）
  sessions.ts      # list / follow / page / prompt / cancel / create / fork / rename / selectModel
  timeline.ts      # SessionWireEvent → 可渲染视图模型（含 surfaceOp: replace 的区间覆盖）
  workspaces.ts    # workspace/* + workspaceFiles/*（两套路径语义）
  attachments.ts   # session/attachment（base64）与文件上传
  projections.ts   # 会话投影（turn/step 分组）
  capabilities.ts  # 启动自检：探测宿主 DSH 版本与端点可用性，不支持时明确报错
  types/           # 从 dsh-protocol.md §3 的 .d.ts 抄来的类型（唯一真源）
```

### 4.2 要实现的端点子集（47 中的核心 ~20）

| 用途 | 端点 | 备注 |
|---|---|---|
| 事件通道 | `$events`（stream）, `$events/result` | waterfall 必须应答，否则宿主侧操作一直阻塞 |
| 会话枚举 | `session/list` | `cursor` 被忽略，别做分页 |
| 会话内容 | `session/follow`（stream） | 快照 + 增量；`assistantStream: true` 才带实时流帧 |
| 翻历史 | `session/page` | **必须带 `throughSeq`**（来自 follow 快照的 cursor） |
| 发消息 / 打断 | `session/prompt`, `session/cancel` | 移动端最高频 |
| 会话管理 | `session/create`, `session/rename`, `session/selectModel`, `session/updateQueue` | |
| 模型目录 | `session/modelCatalog` | |
| 工作区 | `workspace/follow`, `workspace/list 类动词` | |
| 文件浏览 | `workspaceFiles/list`（工作区相对路径）, `read`/`stat`（绝对路径） | 两套路径词汇，别混 |
| 附件 | `session/attachment` | base64；配合文件上传路由 |
| 审批/提问 | 经 `$events` 的 waterfall 到达 | 见 §4.4 |

**一期明确不做**：`settings/*`、`credentials/*`、`skills/list`、`directoryPicker/*`（`pick` 会在电脑上弹出系统对话框）、`session/search`（本部署默认关闭）、`session/fork`。

### 4.3 三条事件通道（最容易踩错的地方）

| 通道 | 内容 | 来源 | 要应答吗 |
|---|---|---|---|
| 转发应用事件 | `ready` / `emit` / `waterfall` | `$events` | 仅 `waterfall` |
| 持久会话事件 | `SessionWireEvent`（56 种：`turn/start`、`step/start`、`assistant/message`、`tool/call`、`tool/result`、`user/message`、`approval/*`、`todo/write`、`compaction/*` …） | `session/follow` 的快照与后续 item | 永不 |
| 客户端实时帧 | `{type:'assistant-stream'}` | `session/follow`（`assistantStream: true`） | 永不 |

**聊天界面要的东西全在 `session/follow`，不在 `$events`。** 这一条搞反会浪费一整天。

### 4.4 审批与提问（移动端最不可替代的部分）

- 从 `$events` 收 `approval/request` / `user-questions/request` 的 waterfall 帧；
- 用 `$events/result` 带当前世代的 `clientId` 应答 `{kind:'approve'|'deny'|'next'|…}`；
- **绝不静默丢弃**：不能作答就回 `{kind:'next'}` 委派，否则宿主侧一直挂着；
- 同一请求在 UI 上呈现为会话内卡片 + 系统通知两条路（通知只负责"叫你回来"，不代你决策）。

### 4.5 断线、世代与重连

- `$events` 首帧 `ready` 绑定一次 **client generation**；重连后旧 `clientId` 失效，宿主会向新世代重放未决 waterfall；
- 断线恢复流程：重开 WS → `$events` 收到 `ready` → `session/follow` 用本地最后 `seq` 续拉（或重取快照 + `session/page` 补历史）；
- 重试策略沿用 DSH 自己的：500ms、1s、2s、4s、8s、10s 上限 + 抖动；
- UI 上必须有明确的"连接中 / 已断开 / 正在补历史"三态。

### 4.6 性能约束（来自实测）

- 一个真实会话的快照可以是 **279 条记录 / ~670 KB compact JSON**，且 `hasMore: true` → 必须**流式解析、分批入视图**，不能 `JSON.parse` 后一次性渲染；
- `session/control` 的基线包含**所有活会话**的队列/任务/投影 → 只取当前会话相关的，别整包进内存；
- 时间线与视图模型按 `seq` 做增量 diff；虚拟列表只渲染窗口内 step。

---

## 5. 移动 UI 设计

### 5.1 信息架构（三层，无抽屉）

```
[会话列表]  ──点会话──▶  [会话时间线]  ──工具卡展开──▶  [工具详情]
   ▲  工作区分组              ▲ 输入区常驻                ▲
   └── 顶栏：当前主机 · 状态点 · 模型                    └── 底部抽屉（文件/图片/预览）
```

- **不做侧栏/抽屉**：手机上的 DSH 抽屉是注入 CSS 硬造的，正是不稳定的根源。改成**页面级导航**（列表 ↔ 会话），返回手势走系统。
- **顶栏**：主机名 + 连接状态点 + 当前模型（点开切换）。窄，且永远不滚动。
- **输入区**：常驻底部，支持多行、图片/文件、发送/停止（正在跑时同一按钮变停止）。

### 5.2 时间线渲染规则

| 事件 | 呈现 |
|---|---|
| `user/message` | 右侧气泡，原文/附件缩略图 |
| `assistant/message` | 左侧 Markdown（代码高亮 + 可复制） |
| `turn/start` / `step/start` | 分组锚点（"第 N 轮"标题、耗时） |
| `tool/call` + `tool/result` | **默认折叠成一行**：图标 + 工具名 + 状态（跑/成/败）+ 耗时；点开看参数与结果（截断 + "查看全部"） |
| `todo/write` | 时间线内嵌待办清单（可折叠） |
| `approval/asked` / `approval/decided` | 卡片：批准一次 / 拒绝；已决后变只读回执 |
| `compaction/*` | 灰色分隔线说明"上下文已压缩"，**同时按 `surfaceOp` 覆盖区间重算** |
| `subagent/*` | 缩进子节点 + 可跳转 |
| `error` / 失败 | 红色卡片，带重试入口 |

**必须实现 `surfaceOp`**：`{op:'replace', startSeq, endSeq}` 表示该事件**取代**区间内的surface 节点（压缩就是这么干的）。线性追加渲染器遇到它必然显示重复内容——这是最容易被忽略、也最容易显得"这 app 坏了"的地方。

### 5.3 视觉与手感

- 主题跟随系统（深浅），字号可调（移动端默认比桌面大一档）；
- 触摸目标 ≥44pt；`-webkit-tap-highlight-color: transparent` 由 UI 自己负责按下态；
- 长列表用虚拟滚动；滚动容器**单层**（不要嵌套滚动区，iOS 上嵌套滚动是重绘问题的温床）；
- **不引入任何 `backdrop-filter`**：DSH 弹窗用的毛玻璃在 iOS WebView 上会与滚动层产生合成残留，我们的 UI 用实色分层来避免这一类问题；
- 断网/离线态明示，不假装在线。

### 5.4 通知

- **本地通知**（Tauri notification 插件）覆盖："等审批""等回答""一轮结束"；这三件恰好是"人不在电脑前"时唯一需要被叫回来的事；
- 本地通知**不代答**，点击回到会话卡片；
- APNs 需要付费开发者账号，作为可选增强，不进一期。

---

## 6. 宿主侧改动（`dsh-plugin-pocket`）

分叉自 `dsh-plugin-tether`，改动极小：

1. **删除** `injectNarrowScreenCss()` 及其 `tapIndex` 注册（那 23KB 是全部问题的来源）；
2. **删除**"把 `/` 与 `/index.html` 交给手机"的路由语义（不再代理 DSH 的桌面页）；
3. **新增** `GET /pocket/*` → 从包内 `dist/` 读取文件（mime + 缓存头 + 防目录穿越）；
4. `GET /pocket/` → 返回 `index.html`（SPA 入口）；
5. 其余完全不动：iroh sidecar、配对、设备白名单、cookie 兑换、逐请求注入、`/dsh-tether/*` 三条路由（改名即可）。

安全边界**不放松**：仍然只注入 cookie 到本机 127.0.0.1 的请求；仍然只服务本机回环；配对仍然 10 分钟窗口 + 3 次尝试 + iroh 公钥白名单。

---

## 7. 开发与验证流程

### 7.1 本机快速迭代（不需要手机）

Pocket UI 是纯静态 SPA，用 Vite dev server + 一个**注入 cookie 的 dev 代理**即可在桌面浏览器里做 95% 的 UI/协议开发：

```
浏览器 → localhost:5173（Vite）
            │  /api/*  → 代理到 127.0.0.1:19387 并附加 Cookie 头（tools/mint-cookie.cjs 生成）
            └  WS 升级同样转发
```

好处：热更新、DevTools、可断点；协议层的事件流可以直接在 Network 面板里看。

### 7.2 真机验证（必须有，且要早）

- 已有可用链路：`dsh-tether/ios-dist/resign-install.sh`（官方未签名 IPA + 我们个人团队描述文件重签 + `devicectl` 装机 + 启动）；
- 个人团队证书 **7 天过期**，脚本已能自动重签（描述文件过期时会先跑一次 `xcodebuild -allowProvisioningUpdates` 重新签发）；
- 截屏用 `xcrun devicectl device capture screenshot`（本机已实测可用；`screen-record` 在这台设备上不受支持）；
- **每个里程碑结束必须在真机上按验收清单手测**，不接受"模拟器过了"。

### 7.3 协议回归

M0 产出的抓包样例（脱敏）进 `docs/artifacts/samples/`，作为"协议没变"的对照；DSH 升级后跑一次 spike 脚本 diff 差异。

---

## 8. 里程碑与验收标准

| 阶段 | 产出 | 验收（全部要在真机 iPhone 上过） |
|---|---|---|
| **M0** 协议 spike（~2 天） | `docs/PROTOCOL-0.2.0-rc.2.md` + 抓包样例 + 一个 Node/TS spike 脚本 | 在本机对 `127.0.0.1:19387` 能：① `session/list` 拿到真实会话 ② `session/follow` 收到真实事件 ③ `session/prompt` 发一条并在流里看到回复 ④ 收到一次 `approval/request` 并成功应答 ⑤ 用 `0.2.0-rc.2` 校正文档基线差异 |
| **M1** 只读客户端 | Pocket UI 骨架（会话列表 + 会话时间线 + 重连），跑在 Tauri 壳里 | 真机：滚动流畅无残影；能看历史（`session/page`）与实时（`session/follow`）；断网 30s 再恢复能自动补齐 |
| **M2** 可交互 | 输入区、发消息/打断、模型切换、工具折叠、审批/问答、图片与文件 | 真机：完整跑一轮"发需求 → 看工具 → 批一次审批 → 收结果"；图片上传后在会话里可见 |
| **M3** 通知 | 本地通知（审批/提问/完成）+ 点击回跳 | 真机：锁屏时收到审批通知，点开能直接作答 |
| **M4** 打包分发 | 沿用重签脚本出 IPA；Android 出 APK；OTA 说明 | 全新设备从 0 到可用 ≤ 10 分钟，含证书信任步骤 |

**首个可见成果**：M1 结束时，手机上应该已经"感觉像一个正经 App"，而不是"一个被硬掰的桌面网页"。

---

## 9. 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| DSH 客户端协议非公开稳定契约，且已在 `0.1.5-rc.1 → 0.2.0-rc.2` 之间变过 | 升级即碎 | 协议层独立成包；启动自检 + 能力探测；不支持的宿主给明确文案而不是白屏；版本区间写进 `package.json` |
| 我们对 `0.2.0-rc.2` 的协议认知只来自文档，未逐条实测 | 设计跑偏 | **M0 就是专门消除这个风险的**，先于任何 UI 工作 |
| iOS 后台/长连接限制（App 退到后台即断） | 实时性差 | 会话内前台保持连接；退后台只保留"待处理"通知；重连用 `follow` 增量补齐 |
| 免费个人团队签名 7 天过期 | 自用摩擦 | 已有自动重签脚本；长期建议付费账号或 AltStore；README 写明 |
| 传输层 fork 后与 tether 上游分叉 | 维护成本 | 尽量**零改动**复用（只加一条静态路由）；定期 rebase；把我们的改动压到最小可 diff |
| 上游 DSH/tether 自己做移动端 | 重复劳动 | 保持薄、协议层可独立复用；先把 M0/M1 做成"可被吸收的资产" |
| 许可与商标 | 法律 | pocket 代码 MIT；fork 保留 tether 版权声明；不使用 DeepSeek 商标做本产品标识；不复制 DSH 桌面 UI 的样式资源 |
| 安全：手机 = 挟持开发机的入口 | 高 | 沿用 tether 的边界（配对窗口、公钥白名单、Host 栅栏），并在 README 明写已知边界（**本机进程可自签配对码**；手机上任何 App 可连本地代理端口） |

---

## 10. 目标仓库结构

```
dsh-pocket/
  README.md
  docs/
    DESIGN.md                 # 本文
    WHY-NOT-INJECTION.md      # 为什么换掉注入路线（真机证据）
    PROTOCOL-NOTES.md         # 已核对的协议事实 + 本机复现方法
    PROTOCOL-0.2.0-rc.2.md    # M0 产出：按本机版本校正的协议文档
    artifacts/                # 截图与脱敏抓包
  pocket-ui/                  # M1：移动优先 SPA（Vite + TS）
  pocket-protocol/            # M0/M1：协议层（TS，无 DOM 依赖，可单测）
  plugin/                     # dsh-plugin-pocket（宿主侧，分叉自 dsh-plugin-tether）
  app/                        # 手机壳（分叉 tether 的 Tauri app，只改 iframe 指向）
  tools/
    mint-cookie.cjs           # 本机签发会话 cookie（dev 代理 / 协议 spike 用）
    dev-proxy.mjs             # M0：注入 cookie 的 Vite 代理
  spikes/                     # M0 的一次性验证脚本
```

---

## 11. 开放问题（需要在 M0 期间回答）

1. `0.2.0-rc.2` 的端点表与 `0.1.5-rc.1` 差多少？（尤其 `session/follow` 的快照结构与事件类型）
2. 文件/图片上传走哪条路：`session/attachment`（base64）还是 `dsh-client-file-upload` 的流式路由？后者在手机 WebView 里是否可用？
3. `present` 产物（图片、HTML 报告）在会话里怎么拿：下载 URL 还是 RPC 返回字节？
4. 会话列表要不要按工作区分组、以及 `workspace/follow` 的更新频率是否够用？
5. 中文/英文 i18n 是跟随 App 还是跟随 DSH 设置（tether 的选择是"三处各随其主"）？
6. 是否需要在 UI 里暴露"停止/重启 DSH 主机"这类运维动作？
