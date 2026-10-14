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

[Unreleased]: https://github.com/UnsplashZ/dsh-pocket/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/UnsplashZ/dsh-pocket/releases/tag/v0.4.0
[0.3.0]: https://github.com/UnsplashZ/dsh-pocket/releases/tag/v0.3.0
