# Changelog

本文档记录 DSH Pocket 的每个对外版本。格式遵循
[Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循
[语义化版本](https://semver.org/lang/zh-CN/)。

**版本号的唯一真源是 [`ios/VERSION`](ios/VERSION)**，工程里的
`MARKETING_VERSION` 由 `ios/scripts/version.sh` 同步。发版流程见
[README](README.md#releasing)。

All notable changes to this project are documented here.

---

## [Unreleased]

### 计划中 / Planned

- 真机逐项过 HIG 自检清单：VoiceOver 全流程、动态字体 AX1/AX3/AX5、Increase Contrast
- 审批通知上的三个操作按钮（批准一次 / 拒绝 / 稍后）
- `SessionModel`（900+ 行）里可抽出的纯逻辑下沉到 DSHKit，补单元测试

---

## [0.4.6] — 2026-10-19

### Fixed

- **切换权限时冒出一条排队消息**（用户："切换权限时会显示一条排队消息"）。
  `dsh-user-approval` 在审批策略变化时会把一句
  `The approval policy changed from "x" to "y" (changed by the user).` 当成
  **用户消息**塞进队列。0.4.5 已经过滤过这条 —— 但过滤加在了
  `TimelineBuilder.applyInbox`（**日志推导**那份队列），而排队面板实际渲染的是
  **投影 + 增量 splice** 那份（`SessionModel.projectionQueued`），所以面板上
  照冒不误。现在过滤收敛到统一的发布口 `publishQueuedMessages()`
  （`removingMachineNotices`），两条数据源共用一条规则；投影解析层本身不动
  （数据不丢，只是不显示）。
- **关于页的「协议」版本不随主机更新**（用户："协议版本没有随着主机自动更新"）。
  那一行是硬编码的 `DSH 0.2.0-rc.2`，宿主升到 0.2.1-rc.2 之后它就是错的。
  排查发现**协议里没有版本 RPC**（`system/info`、`gateway/release` 等全是
  `not found`），版本号唯一的出处是 `dsh web` 注入首页 HTML 的
  `__DSH_BOOT__.release`。现在连接建立时 `GET /` 抠出真实版本，关于页拆成两行：
  「主机版本」（实时，未连接时如实显示）和「协议基线」（已实测对齐的 0.2.0-rc.2）。
- **装机脚本自动挑设备挑到的是手表**（上一版遗留在 HEAD 的未发版修复）：
  `--list` 与自动挑选现在走同一个 filter（physical + iOS），
  不再先命中 Apple Watch。

### 顺带

- 新增 3 条单测：投影队列的机器通知过滤（splice 与全量投影两条路）、
  `__DSH_BOOT__` 的 `release` 解析（含无 commit / 无 boot 的退化情形）。
  DSHKit 152 条、App 测试全绿。

---

## [0.4.5] — 2026-10-16

### Fixed

- **Markdown 文件不渲染，整段原始语法照原样显示**（用户："md 缺少正确渲染"）。
  截图中那份 8-9 月结算汇总把 `# 2026-10-16 …`、`**38,841.70134**`、
  `| 检查 | 方式 | 结果 |` 一起画了出来。根因**不是解析器坏了** ——
  App 自己的 `MarkdownBody` 一直是好的 —— 而是把 `.md` 交给了**系统 QuickLook**，
  而 QuickLook 对 Markdown 的渲染就是纯文本。现在 `.md` 走 `MarkdownBody`，
  与正文同一套排版，标题、粗体、链接、表格都正常。
- **点开文件会连跳两个窗口**（用户："先跳了一个窗口出来，然后又跳了一个正文窗口"）。
  `FilePreviewScreen` 自己是 sheet，取回成功后它又用 `.sheet` 推一个全屏 QuickLook，
  于是"正在从电脑取回…"刚出现就被盖住（它自己的完成落地页因此几乎永远看不到）。
  现在取回过程与渲染器在**同一页**里切换，只开一个窗口。
- **PDF 内嵌时是空白页**：`QLPreviewController` 放进 `NavigationStack` 后只出翻页控件、
  正文不画（扩展进程停在 `running-active-NotVisible`）。改用 `PDFKit`
  （`PDFView`），一次就对 —— 实测能正常显示中文表格型报表。
- **大文件被静默截断**：`workspaceFiles/read` 的窗口是 5000 行（`eof:false`），
  而按 `offset` 翻页**拼不回原文**（每页末尾不含换行、下一页也不重复它，
  逐页拼接的字节与磁盘不一致）。现在超过窗口且文件 ≤ 8 MB 时改用 `readBytes`
  整份取回（实测逐字节一致，12 MB 也验过）；再大的只显示开头，并明说
  「文件太大，只显示了开头部分」。顺带记下一个协议事实：
  `workspaceFiles/readAll` 在本部署里**没有实现**（路由 `not found`）。
- 引导页文案「用系统 QuickLook 预览，不下载到别处」已不准确（多数格式不再走 QuickLook），
  改为「文本、Markdown、图片、PDF 都能直接看，不下载到别处」。

### 顺带

- 新增 `FilePreviewKind`（按扩展名分派渲染器，纯函数可单测）与 10 条分类单测（含 dotfile、SVG 两个实测踩到的边界）；
  另加 1 条用**用户截图里那段真实 Markdown** 验证块级结构确实被拆出来
  （段落里不再残留行首 `#` 与 `|`）。
- 删除 `FilesSheet` 里重复的那份 `QuickLookPreview`（包装器只留一份）。
- 调试用深链新增 `-DSHOpenPreviewPath` / `-DSHOpenPreviewScopeId`：
  模拟器里点不了 UI，用它直接截一张预览页的图（沿用已有的 `DSHOpenSessionId` 约定）。

---

## [0.4.4] — 2026-10-15

### Fixed

- **交付产物点不开、不能预览**（用户："交付文件能看到，但是点不开，不能展开预览"）。
  两层原因：
  ① **产物卡整行没有点击处理** —— 上一版只把它画出来，没接任何动作，所以点下去毫无反应。
  现在每一行都可点，并给出 `chevron.right` **让"能点"看得见**；没有 `path` 的产物
  明说打不开，而不是做成"点了没反应"。
  ② **`workspaceFiles/read` 的 `range` 是必填字段**，而客户端写成了
  `if let range { … }` —— 不传 range 时字段缺失，宿主直接报 `missing "range"`，
  于是**所有"点开文件看看"的功能全是坏的**（不只产物卡，工作区文件页也一样）。
  实测 `range: {}` 就是"整个文件"；传 `null` 也会被边界校验拒。
- **图片/PDF 这类二进制产物也能预览**：新增 `workspaceFiles/readBytes` 支持。
  它的响应是 **multipart**（不是 JSON），所以新写了字节级解析 ——
  **不能用 `String` 中转**，否则非法 UTF-8 字节会被替换字符吃掉、图片直接打不开
  （单测拿 0x00…0xFF 全量字节和真实 PNG 钉住了这一点；写这条时它确实抓到我一个
  真 bug：要找的 part 排在第二个时永远找不到）。
- 取回后先落临时目录再交给系统 QuickLook（QuickLook 只认本地 URL）；
  文本走 `read`、其余走 `readBytes`，并在打开前先 `stat` 一次，
  这样"文件被删了 / 没权限 / 连不上电脑"能给出不同的说法。

### 顺带

- 工作区文件页（`FilesSheet`）的预览同样受 ② 影响，一并修好。

---

## [0.4.3] — 2026-10-15

这一版收的是"手机上看到的和电脑上不一致 / 看不到"那一类问题，全部来自真机使用反馈。

### Fixed

- **缓存与宿主差异很大时，点进去内容空白、要退出重进**。两个原因叠在一起：
  ① 续拉是**一次性同步循环**（`resume` 里 `for event in ... { apply(event) }`，
  没有分片、没有让出主线程）。缓存很旧时要折几百条事件、内容高度实测从 3206
  涨到 13867，全部发生在同一帧 —— 视图根本没机会在中间滚动，落点被那次暴涨甩到
  内容之外，屏幕一片空白。现在拆成 `beginResume` / 分片 `applyResuming` /
  `finishResume`，每片之后 `publish()` + `requestScrollToBottom()` + 让出主线程。
  ② 续拉那条**提前 return 的分支从来没有请求过"滚到底"**（`requestScrollToBottom()`
  只写在冷启动分支末尾）。于是"缓存越旧、差异越大、越是一片空白"，而退出重进之所以
  能好，是因为那时缓存已被刷新、走的是有滚动请求的冷启动路径。
- **往上翻历史翻不动、必须退出会话重进才正常**。根因：冷启动折叠快照时
  **从没把宿主的 `cursor` 落到 builder 上**，`builder.cursor` 一直是初始值 `-1`；
  而补历史（`session/page`）的 `throughSeq` 用的就是它 —— 实测宿主收到
  `throughSeq: -1` 会回**空页且 `hasMore=false`**，App 于是把 `hasMoreHistory`
  永久置成 false，这个会话再也补不了历史。退出重进之所以"能好"：那条路走缓存恢复，
  `TimelineBuilder.resume(with:)` 会正确地设上 cursor。
  修复：折叠结束后 `builder.setCursor(snapshot.cursor)`；并且 **`cursor < 0` 时不发请求**
  （快照还在分片折叠时自动补历史会踩到），空页也不再无条件当成"没有更早的内容"。
  实测修复后连续翻 10 页、每页 250+ 条事件，`beforeSeq` 持续前进。
- **过程步骤特别多时，展开/收缩掉帧**。两处叠加：
  ① 解析结果**每帧重算** —— `MarkdownBody` / `InlineMarkdown` 把解析放在 `init` 里，
  但 SwiftUI 每次父视图 body 求值都会重建子视图 struct，于是块级解析与
  `AttributedString(markdown:)` 每次都重跑（实测**静置**状态下每 2 秒
  32 次块级 + 222 次内联）。现在按文本缓存（`NSCache`，自带内存压力回收），
  实测同样场景降到 10 次 + 55 次，剩下的都是首次未命中；
  `ToolRow` 的 `prettyPrinted(arguments)` 同理改成构造时算一次（原来每次 body
  求值都跑一遍 `JSONSerialization`）。
  ② 展开/收缩给整段内容做**布局动画**，而一轮最多 176 条过程行 —— 每帧都要重排
  整屏。改成直接瞬切（一次重排）。用户要的是"点开能看到过程"，不是看着它慢慢铺开。
- **交付的文件看不到**。`present` 的产物卡一直是空的 —— 客户端读的是
  `deliverables` / `items` 两个键，而活宿主发的是 **`files`**（每项只有
  `path` + `description`，**没有 `title`**），于是列表永远为空，卡片上只剩一行
  「产物」标题。现在按真实形状解析，`title` 用文件名兜底；形状认不出来时退成一条
  原始事件，不再画空卡、也不吞事件。另外产物卡**不再跟着轮次一起收进折叠区** ——
  一轮跑完收拢成「摘要 + 结论」之后，它紧跟在结论后面显示（它不算进「N 步」）。
- **往上翻历史时，窗口顶部那半截轮次不再逐条摊开**。`session/page` 按 seq 往回翻，
  边界常常落在一轮的中段：这一轮的 `turn/start` 还没加载到，手里只有尾巴和 `turn/end`。
  老代码把这段尾巴里的每一条都当成「轮次之外的独立条目」渲染，于是一轮几十上百条
  过程消息全部摊在屏幕上，只有一路滚到这轮真正的开头才会突然收拢。现在这段尾巴
  连同它的 `turn/end` 收成**一个**轮次块，照常收拢成「摘要 + 结论」；没有 `turn/end`
  （还在跑）时仍按原来的全展开处理。顺带修好一处连带问题：补完历史之后要滚到
  「新进来的第一条」，而那条现在已经在收拢的轮次里 —— 它的 id 不在视图里，
  `scrollTo` 会静默失效（又变成"点了没反应"）。改成滚它所属的**块**。
- **会话菜单去掉重复入口**。「显示模型可见的原始事件」在设置页 → 外观里已经有一份，
  会话菜单里那份删掉；「显示被取代的内容」保留（它是回看被 surface 折叠取代的内容的
  唯一入口）。
- **打开大会话时时间线一片空白，只剩一个「跳到最新」**。根因是"把内容滚到底"这件事：
  `scrollTo(bottomAnchor, anchor: .bottom)` 打在 `LazyVStack` 上不可靠 —— 内容高度是按
  "已实体化的行 + 其余估算"算的，`scrollTo` 一动、实体化的行换一批、高度估算又变，
  落点越漂越远（实测同一会话上高度在 `3155 → 4408 → 3549 → 1272 → 7076` 之间来回跳），
  最后偏移停在内容之外，而且视口里那一批行根本没被实体化。现在交给系统的底部锚点
  （`defaultScrollAnchor`）：初始位置永远贴底；"内容尺寸变化时是否继续贴底"只在
  **用户没手动接管滚动**时开 —— 这个开关单独用一个只由真实拖动手势置位的标志
  （`userTookOverScroll`），不能拿 `isFollowingBottom` 当：它表示"末尾哨兵此刻在不在
  视口里"，内容增长/轮次收拢都会让它短暂变 false，拿它做判断初始加载就会被误判成
  "用户滚走了"、锚点被撤掉、落点停在内容中间。iOS 18 起用
  `defaultScrollAnchor(_:for:)` 分开设这两个角色，iOS 17 退回整锚点。
  另外冷启动分片折叠时**只在折到一个完整的轮次边界才发布**：分片边界落在一轮中段时，
  那一轮会先按"还在跑"全展开、折完再收拢，内容骤减同样会把滚动位置甩到内容之外。
- **重连耗时留下常驻诊断**（不是修 bug，是为了下次能一次看清）。用户反馈过
  "退到后台再回来重连特别慢"，而这条链路的慢点全在 iroh 那一侧（建 endpoint /
  打洞或走中继），当时只能临时插计时才量得出来。现在 `TetherLink` 每次建连记一行
  「iroh 端点 / 连接 / 控制流」各段耗时，`AppModel` 记一行「回到前台重连完成，用时
  Nms」，`TetherSession` 把本地代理启动耗时并进原来那行。三行、低频，不刷日志。
- **缓存 schema 5 → 6**。`deliverables/presented` 的解析改了，而产物条目存在缓存里、
  `resume` 不会再折一遍产物事件 —— 不升版的话旧缓存里那张空产物卡会一直留着，
  修好之后用户还是"看不到交付的文件"且看不出原因。

---

## [0.4.2] — 2026-10-14

收掉 [#1](https://github.com/UnsplashZ/dsh-pocket/issues/1)：英文界面里那一批一直显示中文的文案。

### Fixed

- **英文界面补全**。抽取器过去只认几种调用点形状，源码里另有约 126 条面向人的中文字面量
  从来没进 String Catalog，于是英文设备上直接显示中文 —— 包括主界面那颗**发送 / 排队发送**
  按钮、欢迎页与审批按钮、各种确认弹窗、诊断导出页，以及 DSHKit / TetherKit 返回的全部错误文案。
  现在这些字面量要么落在 SwiftUI 的 key 位置上（抽取模式收下），要么显式写成
  `String(localized:)` —— `Text(String)` 是 verbatim 语义，**光进目录是不够的**。
  目录从 442 条涨到 **604 条**。
- **抽取器补上几类漏掉的形状**：三元的两半、`.alert(` / `.confirmationDialog(` /
  `.accessibilityLabel(`（允许 `(` 与字面量之间换行）、`LabeledContent(` / `ProgressView(` /
  `SecureField(`，以及 `return "…"` 和单独成行的字面量。
- **加了三条兜底，防止再从缝里漏过去**：
  · 源码里任何含中文的字面量，只要没进目录就让 CI 红 —— **包括带 `\(…)` 插值的**
    （早期实现把它们排除在外，于是整个诊断导出页都从检查里消失了）；
  · `return "中文"` 落在 `String` 返回位置上会被单独报出来（那种只进目录、运行时查不到）；
  · 抽取只收面向人的字面量，`"Hm"`（日期模板）、`"MMMdHm"`、`"DEBUG"`（日志级别）
    这类技术字符串不会被误当成待翻译文案。
- **版本号同步补上生成的工程**：`version.sh sync` 现在也会改 `project.pbxproj` 里的
  `MARKETING_VERSION`，CI 的一致性检查一并覆盖它。以前每次发版都会留下一处漂移，
  表现为"谁构建一下，工作区就多出一个他根本没改过的 diff"。

---

## [0.4.1] — 2026-10-14

补丁：0.4.0 里新增的「清缓存」按钮漏了英文文案（英文设备上显示成中文）。

### Fixed

- **「清缓存」按钮缺英文翻译**。这是 CI 的本地化检查抓到的：它拿人写的 `EN` 字典与
  从源码抽出来的 key 对账，缺一条就红。0.4.0 是在这次检查已经变红的情况下发出去的，
  所以这里补一个补丁版本。
- **`.help("…")` 不在抽取模式的覆盖范围里**：`.help(_:)` 收的也是 `LocalizedStringKey`，
  不进目录的话中文机器上一切正常、英文机器上冒出一句中文。现在它也被抽取与检查。

### 文档

- README（中英）不再声称"文案全覆盖"：目录里的 442 条确实两种语言都齐，但源码里还有
  **约 126 条面向人的中文字面量没进目录**（App 92 / DSHKit 34），英文设备上会显示中文。
  已实测统计、写明修法，并开成 [#1](https://github.com/UnsplashZ/dsh-pocket/issues/1)。
- `docs/APP-REVIEW.md` 顶上补了快照说明：那份文档里的「死代码」整条已作废，
  而 `DSHClient.events()` 其实有人在用，别照着删。

---

## [0.4.0] — 2026-10-14

**中文摘要**：冷启动不再闪过已归档的会话，归档的时间线缓存可以单独清掉；
修掉一处会让刷新卡死的等待逻辑、一处解归档后列表不刷新的问题，以及缓存过滤的两个漏洞。

### Added

- **冷启动不再闪过已归档的会话**：`session/list` 不带归档字段，以前打开 App 会先把
  缓存里的全量列表（含已归档的）铺出来，直到 `workspace/follow` 的基线到达才剔掉 ——
  看上去就是"一堆已归档的会话闪一下"。现在把上次同步的归档集合落成快照，
  **读缓存的时候就过滤掉**，并且顺手清掉已归档会话的时间线缓存（它们几乎不会再被点开，
  留着只占 LRU 预算）。
- **「已归档」页新增「清缓存」**：可以一次清掉所有归档会话的本地缓存，不影响未归档的。

### Fixed

- **刷新可能永久挂住**：等 workspace 基线的那段逻辑原本用"延续体 + 超时唤醒"，
  但延续体只能被 resume 一次，超时那一刻并没有人唤醒它（取消任务不会唤醒它），
  而 `withTaskGroup` 在作用域退出时会等所有子任务结束 —— 于是"超时"形同虚设，
  流没起来时这个函数会一直等下去，`refreshSessions()` 的 `defer` 不执行，
  下拉刷新的转圈就一直转。改成有界等待，并如实返回"是否真的等到了"；
  等不到就这次不写缓存（这也正是注释里声称要做、而实际没做的事）。
- **解归档后列表不更新**：会话列表刷新有 15 秒节流，而解归档只有"重新拉一次列表"
  这一条路把会话拉回来，被节流挡掉时用户刚恢复的会话要等十几秒才出现。
  现在这类"刚改完状态必须立刻体现"的刷新会绕过节流。
- **会话列表缓存的过滤有两个漏洞**：只认 `items` 键，遇到老形态的 `sessions` 会
  **静默退化成不过滤**（已归档的又冒出来）；过滤时会把负载里其它字段丢掉。
  现在两个键都认，并且只替换那一个键、其余原样带回去。
- 发布说明里的安装指南链接改成绝对地址 —— GitHub Release 页面不解析相对链接，
  而那个链接恰好是"这个包怎么装"的唯一入口。

---

## [0.3.0] — 2026-10-13

首个公开版本。**只发布未签名的 IPA**，安装时由使用者用自己的 Apple ID 重签
（见 [docs/INSTALL-UNSIGNED-IPA.md](https://github.com/UnsplashZ/dsh-pocket/blob/main/docs/INSTALL-UNSIGNED-IPA.md)）。

First public release. Unsigned IPA only — you re-sign it with your own Apple ID.

**中文摘要**：原生 SwiftUI 客户端全面可用 —— 会话列表/时间线/输入/审批/提问/文件产物/设置/配对都已打通，
对着活着的 DSH 宿主验证过，并有自动化的未签名打包与发布流水线。

### Added

- **会话列表**：按工作区分组、下拉刷新、本地与主机历史搜索、左滑归档、长按重命名/复制 ID、
  空/加载/离线三态、连接状态与重连。
- **会话时间线**：`LazyVStack` + 轮次折叠（带完成动画与自动贴底）、用户气泡、助手卡片
  （Markdown / 代码块复制 / 表格 / 推理折叠）、工具调用折叠成一行（符号 + 状态 + 耗时，可展开
  参数与输出）、子代理卡片、流式追加、「跳到最新」、滚到顶自动补历史。
- **压缩与取代**：`surfaceOp.replace` 按区间重算，被取代的内容收进折叠区，不重复显示。
- **输入区**：1–6 行自适应、发送/停止/排队单按钮聚合、照片与文件附件、乐观插入（按 `rpcId` 收敛）、
  `/` 命令菜单（宿主 6 条 + 本地动作 4 个）、`@` 引用（文件 + 会话）、排队消息面板（可编辑/删除/插队）、
  上下文占用条与会话统计、工作状态与实时计时器。
- **审批与提问**：时间线内卡片 + 本地通知，决策走 DSH 原生 `$events/result`；单选/多选/开放文本提问。
- **文件与产物**：工作区浏览 + 系统 QuickLook，产物卡 + ShareLink。
- **设置**：主机管理、电脑端默认模型与思考等级、提供商与模型（含密钥，**只写不读**）、插件包开关、
  定时提醒、缓存管理、归档、通知、外观（主题 / 字号 / 原始事件 / 默认展开思考）、诊断、许可、隐私。
- **配对**：扫码（VisionKit）/ 粘贴整串 / 手输 6 位码，失败按原因码本地化。
- **无障碍与本地化**：动态字体 AX1–AX5、VoiceOver 标签、深色模式、44pt 触达目标；
  zh-Hans / en 双语完整覆盖。
- **工具链**：`ios/scripts/version.sh`（版本号单一真源）、`ios/scripts/make-ipa.sh`
  （带断言的未签名 IPA 打包）、`ios/scripts/select-xcode.sh`（runner 上挑够新的 Xcode）、
  `ios/scripts/pick-simulator.sh`（机型名不再写死），以及 GitHub Actions 的
  CI 与发版流水线。

### Changed

- **Bundle ID 由上游的 `cc.zexa.*` 改本项目的 `cc.unsplashz.*`**。本项目从未公开发布过，
  因此没有迁移负担；改名避免了与上游包的身份冲突（同一个 bundle id 的两个来源会被 iOS
  视作同一个 App 而互相覆盖），也让自签用户不会误以为这是上游官方包。

  Bundle ID changed from the upstream `cc.zexa.*` to this project's `cc.unsplashz.*`.
  Nothing was ever publicly released under the old ID, so there is no migration path to
  write — the only effect is that a device paired with a pre-release build must pair again.

### 说明 / Notes

- 电脑端需要已安装 `dsh-plugin-tether`（0.1.20 或更新）。本项目**不改动**电脑端任何一行。
- 本项目由 [dsh-tether](https://github.com/zexadev/dsh-tether) 衍生而来，只重写了界面层：
  传输层（iroh 打洞 / 配对 / 中转 / cookie 注入）沿用上游设计。见 [NOTICE.md](NOTICE.md)。

[Unreleased]: https://github.com/UnsplashZ/dsh-pocket/compare/v0.4.1...HEAD
[0.4.1]: https://github.com/UnsplashZ/dsh-pocket/releases/tag/v0.4.1
[0.4.0]: https://github.com/UnsplashZ/dsh-pocket/releases/tag/v0.4.0
[0.3.0]: https://github.com/UnsplashZ/dsh-pocket/releases/tag/v0.3.0
