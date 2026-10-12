# iOS 界面规范：Apple HIG 落地

> 需求来源：**"iOS 客户端需严格遵循 Apple design 风格"**。
> 本文是可执行的规范，不是理念总结：逐屏规格 + 设计令牌 + 无障碍要求 + **M3 验收用自检清单**。
> 目标平台：**iOS 17+**（用到 `@Observable`、`.sensoryFeedback`、`ContentUnavailableView`、`ShareLink`、`.symbolEffect`）。

---

## 1. 三条原则的落地含义

| HIG 原则 | 在本项目里意味着 |
|---|---|
| **Clarity（清晰）** | 会话内容优先：时间线是屏幕主体，chrome 尽量少；状态（连接中/断开/运行中/等审批）用文字+符号明确表达，不靠颜色单独传达 |
| **Deference（克制）** | 不自绘导航栏、不做抽屉/汉堡菜单、不抢系统手势；栏用系统材质与层次，让内容浮在正确的层级上 |
| **Depth（层次）** | 会话 → 时间线 → 工具详情的层级用**系统导航与 sheet**表达；重要的等待（审批）用 sheet/通知提升到前台，而不是塞进角落 |

**硬性约束**：任何界面决策如果与系统默认行为冲突，**默认行为优先**；需要偏离时必须在 `DECISIONS.md` 里记一条理由。

---

## 2. 平台与框架选择

| 项 | 决定 |
|---|---|
| 最低版本 | iOS 17.0（Apple 当前主流覆盖；换来 `@Observable` / `sensoryFeedback` / SwiftUI 新导航） |
| UI 框架 | **SwiftUI 优先**。仅在 SwiftUI 无对应能力时桥接 UIKit（如条码扫描用 `DataScannerViewController`、文本输入高级行为） |
| 架构 | 单向数据流：`Store`（`@Observable`）持有状态 → View 只读渲染 → 事件回到 Store；协议层（DSHKit）不认识 SwiftUI |
| 并发 | Swift Concurrency（`async/await`、`Task`、`AsyncStream`）；协议层的流用 `AsyncThrowingStream` 暴露 |
| 依赖 | 只加 **iroh-ffi（IrohLib）**；其余能力全部用系统框架。**不引入任何第三方 UI 库** |
| iPad / Mac | iPhone 为一等公民；iPad 用 `NavigationSplitView` 两栏；Mac 走 "Designed for iPad"（不作为一等目标） |

---

## 3. 导航架构

```
RootView
 ├─ （iPhone）NavigationStack(path:)
 │     ├─ SessionListView            大标题；按工作区分组
 │     └─ SessionView                时间线 + 底部输入区（.navigationBarTitleDisplayMode(.inline)）
 ├─ （iPad/Mac）NavigationSplitView
 │     ├─ sidebar: SessionListView
 │     └─ detail:  SessionView 或 ContentUnavailableView("选择一个会话")
 └─ 模态（全部用系统 sheet/覆盖层）
       ├─ PairingSheet              .sheet ＋ .presentationDetents([.medium, .large])
       ├─ SettingsSheet             NavigationStack ＋ Form
       ├─ FilesSheet                工作区文件浏览
       ├─ ApprovalSheet             可选：把"等待审批"提升为模态（用户偏好）
       └─ QuickLook / ShareLink     系统预览与分享
```

规则：

- **不做**自绘侧栏、抽屉、汉堡菜单、底部自定义 tab bar；
- 返回手势、边缘滑动返回、`NavigationStack` 的转场动画**一律用系统默认**；
- 会话页标题用 `.inline`（长标题不占高），列表页用**大标题**；
- 会话页顶栏只放：连接状态（小圆点+文字）、会话标题菜单（重命名/复制 ID/归档）、模型入口。

---

## 4. 逐屏规格

### S1 会话列表（`SessionListView`）

| 元素 | 规格 |
|---|---|
| 数据 | `session/list` 的 `projections`（标题、最后一轮 prompt/response 摘要、token、上下文压力、是否在跑）——**不打开任何流**（省电省流） |
| 分组 | 按 `cwd`（工作区）分组；组头用系统 `.listSectionSeparator(.visible)` 与 `.headerProminence(.increased)` |
| 行内容 | 主标题=会话标题（1 行截断）；副标题=最后一轮助手回复摘要（2 行截断）；尾部=相对时间 + 状态徽标 |
| 状态徽标 | `running` → 绿色小圆点 + "运行中"；`agentAvailable == false` → 灰色"不可用"；等审批 → 橙色 `exclamationmark.bubble` |
| 下拉刷新 | `.refreshable { await store.refresh() }`（调用 `session/list`） |
| 行操作 | `swipeActions`：左滑 = 归档（`workspace/archiveSession`）；`contextMenu`：重命名、复制 session ID、在新窗口打开（iPad） |
| 搜索 | `.searchable`，对已加载列表**本地过滤**（DSH 的 `session/search` 在本部署默认关闭，不做服务端搜索） |
| 状态页 | 空：`ContentUnavailableView("还没有会话", systemImage: "bubble.left.and.bubble.right")`；断开：`ContentUnavailableView` + "重新连接"按钮；加载：`.redacted(reason: .placeholder)` 骨架 |
| 新建 | 工具栏 `+`：选择工作区 → `session/create` |

### S2 会话时间线（`SessionView`）

| 元素 | 规格 |
|---|---|
| 结构 | `ScrollViewReader` + `ScrollView` + **`LazyVStack`**（不用 List：需要自定义排版与流式追加） |
| 分组 | 按 turn 分组：`turn/start` 出"第 N 轮"分隔（`.headline` + `.secondary` 时间）；组内 step 顺序渲染 |
| 用户消息 | 右侧气泡（`.bubble` 圆角连续），支持图片缩略图（点开 QuickLook） |
| 助手消息 | 左侧正文卡片；Markdown 渲染（`AttributedString(markdown:)` 起步，代码块用等宽 + 横向滚动 + 复制按钮） |
| **工具调用** | **默认折叠一行**：SF Symbol（工具类别）+ 工具名 + 状态 + 耗时；点开展开参数/结果（结果超过 ~40 行折叠并给"查看全部"→ Files/QuickLook）；`.accessibilityLabel` 报"工具 X 运行中/成功/失败，用时 1.2 秒" |
| 待办 | `todo/write` 渲染为内嵌 checklist 卡（系统 `Toggle` 样式只读展示） |
| 审批 | 内嵌卡片：标题（要做什么）+ 理由 + 主按钮「批准一次」/ 次按钮「拒绝」；已决后变灰并显示结果与时间 |
| 压缩 | `compaction/*` 渲染为居中分隔说明"上下文已压缩"，**同时按 `surfaceOp.replace` 重算区间**（见 [DESIGN.md](DESIGN.md) §4.4） |
| 子 agent | 缩进卡片，可跳转其会话 |
| 错误 | 红色卡片 + 重试按钮（`ContentUnavailableView` 的 inline 变体） |
| 流式 | 只用 `.animation(.default, value: lastSeq)`；**`reduceMotion` 时不加动画**；光标用闪烁 `▌` 的 `symbolEffect(.pulse)`（reduceMotion 时静态） |
| 滚动策略 | 默认贴底自动滚动；**用户手动上滑即暂停自动滚动**，右下出现「跳到最新」悬浮按钮（`.buttonStyle(.borderedProminent)` + 材质底）；滚到底自动恢复 |
| 文本选择 | 整个时间线 `.textSelection(.enabled)` |
| 补历史 | 滚到顶部触发 `session/page`（带 `throughSeq`）；加载态用 `.redacted` 或 `ProgressView` 行 |
| 长内容 | 单会话快照可达 831 KB → 先出骨架，再分批 insert（见 [DESIGN.md](DESIGN.md) §4.4） |

### S3 输入区（`Composer`）

| 元素 | 规格 |
|---|---|
| 布局 | `.safeAreaInset(edge: .bottom)`；`TextField(..., axis: .vertical)` 1–6 行自适应；圆角容器 + `.thinMaterial` 背景 |
| 主按钮 | 空闲=发送（`arrow.up.circle.fill`，`.borderedProminent`）；运行中=停止（`stop.circle.fill`，`.tint(.red)`）。**同一位置的形态切换**，不要并排两个按钮 |
| 附件 | 左侧 `+`：照片（`PhotosPicker`）、文件（`.fileImporter`）、拍照（`camera`）。已选附件以缩略图横排显示，可单独删除 |
| 草稿 | 每个会话独立草稿，本地持久化；切会话不丢 |
| 键盘 | 硬件键盘：`⌘↩` 发送、`⇧⌘A` 加附件；`.submitLabel(.send)` 行为与按钮一致 |
| 无障碍 | 发送/停止按钮的 a11y label 随状态变化；附件缩略图有"已附加 1 张图片，点按移除" |

### S4 审批（两条呈现路径）

1. **时间线内卡片**（默认，主路径）；
2. **通知**（`UNNotificationAction`：批准一次 / 拒绝 / 稍后）——点通知直接进入该卡片位置（`ScrollViewReader.scrollTo(id)` 高亮 1 秒）。

规则：**永远不由 App 自动决策**；提供「稍后」把卡片收起到会话顶部的待处理条；决策走 DSH 原生 `$events/result`（见 [TRANSPORT.md](TRANSPORT.md) §3）。

### S5 文件浏览（`FilesSheet`）

`NavigationStack` + `List`；面包屑用 `navigationTitle` 的子标题；行 = 图标（SF Symbol 按类型）+ 文件名 + 大小；下拉刷新；点文件 → QuickLook 预览；`contextMenu`：分享、下载到 Files、复制路径。路径语义注意：`list` 用工作区相对路径，`stat/read` 用绝对路径（见 [PROTOCOL-NOTES.md](PROTOCOL-NOTES.md) §5）。

### S6 设置（`SettingsSheet`）

`NavigationStack` + `Form`，分组：

| 分组 | 内容 |
|---|---|
| 主机 | 已配对主机列表（切换/重命名/删除）；「添加主机」→ 配对 |
| 通知 | 审批/提问/完成三类开关（开关打开时才请求系统授权） |
| 外观 | 跟随系统 / 浅色 / 深色；字号（可选：会话内容额外缩放） |
| 诊断 | 当前连接路径（direct/relay + RTT）、DSH 版本与端点自检结果、最近错误、**导出日志**（ShareLink） |
| 关于 | 版本、MIT 许可、第三方组件（iroh、tether、DSH 引用）、隐私说明、安全边界说明（见 [TRANSPORT.md](TRANSPORT.md) §8） |

### S7 配对（`PairingSheet`）

- 主路径：**扫码**（`DataScannerViewController`，识别电脑端「连接手机」显示的 QR）；
- 备选：粘贴整串 `endpointId#code`（`.textContentType(.oneTimeCode)` 便于从剪贴板自动填）；
- 也支持手输 6 位码（`keyboardType(.numberPad)`）；
- 失败按**原因码本地化**：没有配对窗口 / 已过期 / 错太多次 / 码不对（不要把码本身显示给用户）；
- 配对成功后 `.sheet` 关闭并直接进入会话列表。

---

## 5. 设计令牌（Design tokens）

| 类别 | 规定 |
|---|---|
| **字体** | 只用语义字体：`.largeTitle .title2 .headline .body .callout .subheadline .footnote .caption .caption2`。代码/ID 用 `.system(.body, design: .monospaced)`。**禁止固定字号**（`Font.system(size:)` 仅限图标） |
| **颜色** | 只用语义色：`.primary .secondary .tint`、`Color(.systemGroupedBackground)`、`Color(.separator)`。状态色用语义色 + 符号双重表达（`Increase Contrast` 下不靠色相）。**禁止硬编码 hex** |
| **间距** | 8pt 网格；屏幕水平边距 16（紧凑）/ 20（常规）；列表行垂直内边距 10–12 |
| **圆角** | `RoundedRectangle(cornerRadius: 12, style: .continuous)` 用于卡片；气泡 18；与系统卡片观感一致 |
| **图标** | 只用 SF Symbols；状态图标固定语义：运行中 `circle.dotted`、成功 `checkmark.circle.fill`、失败 `xmark.octagon.fill`、等待审批 `exclamationmark.bubble.fill`、工具 `wrench.and.screwdriver` |
| **层次/材质** | 栏与浮层用 `.regularMaterial` / `.thinMaterial`；内容层用系统背景色。**原生材质正常使用**（v0.1 里"避免毛玻璃"的约束只针对 WebView 路线，不适用于原生） |
| **触感** | `.sensoryFeedback`：发送 `.impact(weight: .light)`、停止 `.impact(weight: .medium)`、完成 `.success`、失败 `.error`、审批到达 `.warning` |
| **动效** | 只用系统默认转场；自定义动画必须 `withAnimation` 且尊重 `reduceMotion`；单个动画时长 ≤ 300ms |
| **空/错/离线** | 统一用 `ContentUnavailableView`（图标 + 标题 + 说明 + 至多一个主按钮） |

---

## 6. 无障碍（Accessibility）

**这是验收项，不是加分项。**

| 项 | 要求 |
|---|---|
| 动态字体 | AX1–AX5 全部不破版：不用固定高度、长文本可换行、按钮文字不截断（必要时 `ViewThatFits`）；在 AX3 以上，工具折叠行的耗时移到第二行 |
| VoiceOver | 每行有 `accessibilityLabel` + `accessibilityHint`；工具卡报"工具名 / 状态 / 耗时"；审批按钮 label 明确（"批准一次：运行 npm test"）；时间线可按轮/按步快速导航（`accessibilityElement(children: .contain)` + 自定义 `accessibilityAction`） |
| 降低动态 | `reduceMotion` → 关自动滚动动画、关光标脉冲 |
| 增强对比 | `Increase Contrast` → 状态徽标加描边/符号，不只靠颜色 |
| 触摸目标 | ≥ 44×44pt（含菱形图标按钮的 `contentShape`） |
| Voice Control | 所有可点元素有可见文字或一致的 a11y label |
| 键盘 | 全流程可用硬件键盘完成（Tab 焦点 + 快捷键） |

---

## 7. 本地化

- 用 **String Catalog（`.xcstrings`）**，一期 `zh-Hans` + `en`；
- 文案规范：动词开头、句子短、**不描述手势**（HIG：别写"点击这里"，写"重新连接"）；
- 时间用相对格式（`RelativeDateTimeFormatter`）、数字/字节用 `Locale` 格式化（"1.2 MB"）；
- 线上传来的**原因码**（配对失败、协议错误码）必须由客户端本地化，不直接展示码；认不出的码原样显示（见 [TRANSPORT.md](TRANSPORT.md) §2）。

---

## 8. 系统集成

| 能力 | 用什么 | 注意 |
|---|---|---|
| 通知 | `UNUserNotificationCenter` + category actions | **在用户开启对应开关时才请求授权**，不在启动时弹 |
| 分享 | `ShareLink` | 分享消息文本、代码块、文件、日志 |
| 文件 | `.fileImporter` / QuickLook / `.fileExporter` | 上传给 `session/attachment`；下载落 Files |
| 相册 | `PhotosPicker` | 发图；需要 `NSPhotoLibraryUsageDescription`（用 Picker 时仍建议声明） |
| 剪贴板 | `UIPasteboard` | 配对串、session ID、代码 |
| 后台 | `BGAppRefreshTask`（可选） | 只为"回到前台前刷新列表"；**不试图后台保活连接** |
| 快捷指令/App Intent（后续） | App Intents | "给 DSH 发一条消息"——放在 M4 之后 |

---

## 9. 隐私与合规

1. **`PrivacyInfo.xcprivacy`** 必须提供（App Store 要求）；声明：不追踪、不采集分析数据、仅本地网络通信；
2. **ATS**：只开 `NSAllowsLocalNetworking`（回环 + .local + 链路本地），不用 `NSAllowsArbitraryLoads`；
3. **不做任何遥测**；日志本地保存、用户可导出、默认不发送；
4. 首次启动的**说明页**要如实写：这个 App 会连接你自己的电脑、凭证与数据都在你自己的机器上、以及 [TRANSPORT.md](TRANSPORT.md) §8 的两条安全边界；
5. 若将来上架：审核说明需包含"如何在没有你的电脑的情况下复现"（提供说明页/演示视频/测试主机），并注意 4.2（最低功能）与 5.1.1（隐私）——**一期走 TestFlight/自签，不追求上架**。

---

## 10. 反模式清单（禁止）

- ❌ 自绘导航栏 / 自定义返回按钮 / 隐藏状态栏
- ❌ 抽屉、汉堡菜单、底部自定义 tab bar、把导航藏进角落
- ❌ 嵌套可滚动容器（外层 ScrollView 里再放 List/ScrollView）
- ❌ 固定字号、硬编码颜色、深色模式下靠"反色"凑合
- ❌ 用第三方 UI 库替换系统控件
- ❌ 启动即弹权限、启动即弹告警；用 alert 承载本可以用页面表达的错误
- ❌ 自定义非系统手势（左滑返回、下拉刷新必须用系统实现）
- ❌ 用 toast/横幅承载错误（错误要有可停留、可重试的页面/卡片）
- ❌ 静默失败（所有失败必须有文案 + 可执行动作）
- ❌ 假在线（连接断了仍显示"已连接"）

---

## 11. M3 验收自检清单

> 逐项在**真机 iPhone** 上过；每项要么 ✅，要么记入 issue。

**导航与结构**
- [ ] iPhone 上会话列表 → 会话 → 返回，全部是系统转场，无自绘导航栏
- [ ] iPad 上是 `NavigationSplitView` 两栏；无会话时详情栏显示"选择一个会话"
- [ ] 配对/设置/文件都是 `.sheet`，可下滑关闭，`.presentationDetents` 合理
- [ ] 没有抽屉/汉堡菜单/自绘 tab bar

**会话列表**
- [ ] 下拉刷新可用；左滑归档、长按菜单可用
- [ ] 空/加载/离线三态都有 `ContentUnavailableView` 或骨架
- [ ] 搜索框本地过滤即时生效

**会话时间线**
- [ ] 流式追加时不错位、不重复（含压缩后的 `replace` 场景）
- [ ] 用户上滑后不再自动滚动，出现「跳到最新」；回到底部自动恢复
- [ ] 工具调用默认折叠为一行，展开/收起正常，长结果有"查看全部"
- [ ] 图片点开是系统 QuickLook；文本可选中复制
- [ ] 滚到顶部触发补历史，有加载指示

**输入区**
- [ ] 1–6 行自适应；发送/停止形态切换正确
- [ ] 附件（照片/文件）可添加、可移除、可发送
- [ ] 切会话草稿不丢
- [ ] `⌘↩` 发送（硬件键盘）

**状态与错误**
- [ ] 断网/断开时顶部有明确状态，恢复后自动重连并补齐
- [ ] 所有失败都有文案 + 重试/可执行动作
- [ ] 没有任何"假在线"

**外观与令牌**
- [ ] 深色/浅色/跟随系统都正常，无硬编码颜色
- [ ] 圆角连续、间距在 8pt 网格
- [ ] 图标全部 SF Symbols，状态图标语义一致
- [ ] 关键动作有触感反馈；`reduceMotion` 下动画关闭

**无障碍**
- [ ] 动态字体 AX1 / AX3 / AX5 三档布局都不破
- [ ] VoiceOver 能独立完成：选会话 → 读一轮对话 → 发一条消息 → 批一次审批
- [ ] `Increase Contrast` 下状态不只靠颜色
- [ ] 所有可点元素 ≥44pt；Voice Control 可用

**本地化**
- [ ] zh-Hans / en 全部有文案，无硬编码中文
- [ ] 相对时间、字节数按 Locale 格式化
- [ ] 配对失败按原因码本地化，不显示原始码

**系统集成与隐私**
- [ ] 通知授权在开启开关时才请求；审批通知带三个操作按钮
- [ ] 分享（文本/代码/文件/日志）用的是系统 `ShareLink`
- [ ] `PrivacyInfo.xcprivacy` 存在且如实
- [ ] Info.plist 只有回环 ATS 例外 + 本地网络用途说明
