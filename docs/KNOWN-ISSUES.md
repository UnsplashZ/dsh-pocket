# 已知缺口与验证记录（KNOWN-ISSUES）

> 本文档记录 dsh-pocket 当前所有已知问题、欠账与验证结论。
> 基线版本：**v0.4.5**（2026-10-16）。每次发版前应复核本文档并更新状态。
> 例行验证命令见文末附录。

---

## 〇、0.4.5 一轮（2026-10-16）

只改了文件预览链路（F11），并顺手核实两条协议事实（F12/F13）。数字是这一轮重跑的：

| 验证项 | 结果 |
| --- | --- |
| App 层单测（模拟器） | ✅ 62 通过 / 0 失败（比 0.4.2 的 49 条多 13 条：预览格式分派 10 条 + 真实 Markdown 1 条，另 2 条为期间新增） |
| 本地化兜底检查 | ✅ 通过，619 条目录，zh-Hans / en 齐全 |
| `version.sh check 0.4.5` | ✅ 一致 |
| 预览链路（模拟器 + 活宿主，DEV-DIRECT） | ✅ Markdown / 文本 / 图片 / PDF 四类各截一张图核对：**单窗口**且渲染正确；认不出的二进制走 QuickLook 兜底正常 |

复现手段记在这里，下次回归照做即可：
`bash ios/build.sh --test` 跑单测；
`node tools/direct-gateway.mjs` 起 DEV-DIRECT，再用调试深链
`xcrun simctl launch … -DSHOpenPreviewPath <文件> -DSHOpenPreviewScopeId <会话>` 直接落到预览页截图
（模拟器点不了 UI，所以用深链；`ADB`/`devicectl` 同样没有触控能力）。

---

## 一、本次验证结论（2026-10-14 实测）

| 验证项 | 结果 |
| --- | --- |
| DSHKit 单测 | ✅ 96 通过 / 0 失败（另有 20 条实时集成测试默认跳过，见下） |
| TetherKit 单测 | ✅ 33 通过 / 0 失败 |
| App 层单测（模拟器） | ✅ 49 通过 / 0 失败 |
| 实时集成测试（`DSH_LIVE=1`，对活宿主） | ⚠️ 20 条执行：15 通过、1 失败、4 跳过（见 二-2） |
| 本地化兜底检查（604 条目录） | ✅ 通过，zh-Hans / en 齐全 |
| 未签名 IPA 打包全链路 | ✅ 断言全过（版本号 0.4.2、无签名、Payload 结构正确，8.2 MB） |
| `version.sh check 0.4.2` | ✅ 一致 |
| GitHub CI 最近 4 次运行 | ✅ 全部 success |
| 未关闭 issue / 工作区 | ✅ 无 open issue；`main` 与远端同步 |
| 真机冒烟（M1 首轮，iPhone 15 Pro） | ✅ 安装/启动/缓存首屏/连接态横幅/配对/蜂窝网络下实时会话同步全部通过；发现 1 个真机新 bug（F7）；截图见 `docs/artifacts/m1-device/` |

### 本次验证新发现（尚在处理中）

1. **仓库内 `project.pbxproj` 的 MARKETING_VERSION 漂移为 0.4.1**（应为 0.4.2）。
   根因在 `release.yml` 的"版本号有改动就提交到 main"步骤只 `git add ios/VERSION ios/project.yml`，
   没有把 `version.sh` 已同步好的 `project.pbxproj` 一起提交；且 GITHUB_TOKEN 推送不触发 ci，
   漂移从未被 CI 抓到。**已修（db9d667，已在 origin/main）**：release.yml 提交步骤补上 pbxproj；
   `version.sh check 0.4.2` 复核一致（2026-10-14）。
2. **实时集成测试 `testCancelAcceptsBareSessionId` 对活宿主失败**：对一个
   "列表快照里非运行、但属 subagent routing 管辖"的会话调 `session/cancel`，
   宿主返回 `session/agent-busy`（要求走 subagent delivery），与测试
   "对空闲会话 cancel 应是成功空操作"的假设矛盾。
   **客户端侧已收口（2026-10-14，ADR-0027-6/8）**：`session/agent-busy` 映射为
   友好文案（"这个会话由子代理托管，请到它的父会话里操作。"），
   且 `SessionModel.isSubagentSession` 让停止操作**在发 RPC 之前**就给出解释；
   该用例的选人范围排除子代理会话。**仍待上游拍板**：宿主 `session/cancel`
   收到子代理会话 id 时是否自动转发给父会话的 waterfall 应答（属 dsh 本体行为决策）。
3. **文档过期**：`LiveIntegrationTests.swift` 的注释与跳过提示引用
   `tools/dev-proxy.mjs`，该文件已更名为 `tools/direct-gateway.mjs`。
   实测 `node tools/direct-gateway.mjs`（绑 127.0.0.1:8788，逐请求注入 cookie）+
   `DSH_LIVE=1 swift test --filter LiveIntegrationTests` 即可跑通。
4. **devicehub 未找到**：本机与 Kimi 插件市场均无 devicehub。真机通道目前
   可用的是 `xcrun devicectl`（已能连到本机 iPhone 15 Pro）+ 已就位的
   dsh-tether 链路（见 三-1），若 devicehub 是另一套工具需补充安装信息。
5. **真机实测：电脑端重装插件后旧设备 ID 永久超时（2026-10-14）**。
   tether 插件中午重装后 sidecar 的 `identity.key` 重建（`~/Library/Application Support/dsh-tether/`，
   14:16 生成），设备 ID 整个换掉，配对白名单同时清空。手机拿着缓存里的旧 ID 去连，
   iroh 层 `Connect timed out`、连续失败 6 次——与 App 内报错文案预设的场景一致，
   文案指引（「设置 → 主机」删旧电脑重新配对）有效。
   用 `node tools/tether-status.mjs --pair` 重开配对窗口、真机重新配对后即恢复。
   **但配对成功后 App 卡在「连接中」**——根因不是"配对没唤醒重连"，
   而是一个早前排队的自动重连迟到醒来：`connect()` 无条件把 UI 打成「连接中」，
   而 `TetherSession.connect` 对已连接的同 id 是空操作、不会再广播 `.connected`，
   界面从此无人救回，需杀进程重启。已修（F7，2026-10-14），修复包已装真机复验。

---

## 二、功能缺口（已对照代码核实仍存在）

### 1. 需要真机或外部条件

| # | 项 | 说明 | 状态 |
| --- | --- | --- | --- |
| M1 | 真机逐项过 HIG | VoiceOver 全流程、动态字体 AX1/AX3/AX5、Increase Contrast、Voice Control | **冒烟已过（2026-10-14）**：安装/启动/配对/实时同步通过（见 §三-1）；交互式 HIG 项仍需人工在机上操作（devicectl 无触控能力） |
| M2 | 干净设备首跑 | 含首次「本地网络」权限询问的完整首次体验 | 未做 |
| M3 | ~~TestFlight 上架~~ | **已决定不做**（需付费开发者账号；项目定位即未签名 IPA 自行签名） | 不做 |

### 2. 代码内已核实的功能缺

| # | 项 | 位置 / 证据 | 影响 |
| --- | --- | --- | --- |
| F1 | ~~审批推送通知没有操作按钮~~ **已修（2026-10-14，ADR-0027-1）** | `NotificationCenterAdapter` 注册「批准一次 / 拒绝」category，响应路由回 `AppModel.decide`；请求已不在待处理里就忽略 | 审批类通知体验打折 → 已解决 |
| F2 | ~~计划模式输入框占位文案未接~~ **已修（2026-10-14，ADR-0027-2）** | `SessionModel.planState` 接 `projections.plan`，`Composer.placeholder` 按 `isActive` 切换「描述你的任务以生成计划」 | 占位文案与桌面端一致 |
| F3 | ~~待办面板无空态引导~~ **已修（2026-10-14，ADR-0027-5）** | 会话页出现过待办后被清空且轮次在跑时，显示一行「这轮还没有待办」；没用过待办的会话不显示 | 新用户不知道有这功能 → 已解决 |
| F4 | ~~切换权限在时间线留 `⌘ permission` note~~ **已修（2026-10-14，ADR-0027-3）** | 抑制标志进 `TimelineBuilder.State`（缓存 schema 4→5），跨快照重建不再漏；有单测钉住。电脑端改权限的 note 照常显示（有意设计） | 时间线噪音 → 已解决 |
| F5 | 计时器起点在"有界快照切掉本轮开头"时偏短 | **已做客户端能做的部分（2026-10-14，ADR-0027-7）**：起点非真实 `turn/start` 时显示「≥」如实说明是下界（`TurnTimer.startWithConfidence`，有单测）；时钟偏移校正抽成 `HostClockOffset` 纯函数 | 精确起点仍需宿主协议补"本轮从何时开始"字段，客户端单方面做不到与电脑端完全一致 |
| F6 | ~~`refreshSessions()` 15 秒节流同样作用于下拉刷新~~ **已修（2026-10-14，ADR-0027-4）** | 下拉走 `refreshSessions(force: true)`；节流只作用于程序性刷新 | 下拉静默无反应 → 已解决 |
| F7 | ~~配对成功后 App 卡在「连接中」，需重启才完成握手~~ **已修（2026-10-14）** | 根因：早前排队的自动重连迟到醒来，`connect()` 无条件把 UI 打成「连接中」，而 `TetherSession.connect` 对同 id 是空操作、不会再广播 `.connected`，界面无人救回。修复：`connect()` 入口对已连接同 id 直接收工并对齐 UI；已装真机验证正常重连路径不受影响 | 配对流程最后一环体验断裂 → 已解决 |
| F8 | ~~交付的文件看不到~~ **已修（2026-10-14）** | 两层叠加：① `deliverables/presented` 读的是不存在的 `deliverables`/`items` 键，活宿主发的是 **`files`**（每项只有 `path` + `description`，没有 `title`），于是产物列表恒为空、卡片只剩一行「产物」标题；② 产物卡跟着轮次一起被收进折叠区，收起后连那张空卡都看不见。修复：按真实形状解析（`title` 用文件名兜底，认不出的形状退成原始事件不吞掉）；产物卡不参与折叠，收起时紧跟结论显示。**缓存 schema 5 → 6**：产物条目存在缓存里、`resume` 不会再折一遍产物事件，不升版的话旧缓存那张空卡会一直留着 | 交付物整条链路在手机上不可见 → 已解决 |
| F9 | ~~打开积压很多轮的会话时时间线一片空白，只剩一个「跳到最新」~~ **已修（2026-10-14）** | 根因是"把内容滚到底"这件事：`scrollTo(bottomAnchor, anchor: .bottom)` 打在 `LazyVStack` 上不可靠 —— 内容高度按"已实体化的行 + 其余估算"算，`scrollTo` 一动、实体化的行换一批、估算又变，落点越漂越远（实测同一会话上高度在 `3155 → 4408 → 3549 → 1272 → 7076` 之间跳，偏移最后停在内容之外，且视口里那批行根本没被实体化）。修复：改用系统底部锚点 `defaultScrollAnchor`（iOS 18 起用 `defaultScrollAnchor(_:for:)` 把"初始贴底"与"内容变化时是否跟随"分成两个角色；跟随开关单独用只由真实拖动手势置位的标志，**不能拿 `isFollowingBottom` 当**——它表示"末尾哨兵此刻在不在视口里"，内容增长/轮次收拢都会让它短暂变 false）。另修：冷启动分片折叠只在折到**完整轮次边界**才发布（分片边界落在一轮中段时那一轮先按"还在跑"全展开、折完再收拢，内容骤减同样会把滚动位置甩出去） | 打开大会话看不到任何内容 → 已解决 |
| F10 | **流式输出中做长距离程序化滚动（补历史）可能停在内容之外** | 只在我用调试钩子人为构造的状态上复现过：会话正在流式输出（每 16ms 重新发布一次时间线）时，在"贴底跟随"状态下强行触发一次**长距离**补历史滚动。真实手势到不了这个状态（补历史只在用户已经滚到顶部时才触发），而无头模拟器给不了真实手势，所以**未能用真手势复现**。已知动画/非动画都试过，不是动画的问题 | 若真机上"一边输出一边往上翻历史"遇到白屏，就是它。正解是把整条滚动链迁到 `scrollPosition(id:)`（iOS 17+）—— 它由 SwiftUI 托管滚动位置，不依赖"估算末尾"；改动面覆盖 `scrollToBottom` / 跳到最新 / 补历史 / 审批定位四处，本次未动 |
| F11 | ~~Markdown 文件在预览里显示成原始语法；点开文件连跳两个窗口~~ **已修（2026-10-16，ADR-0028）** | ① `.md` 以前交给系统 QuickLook，而 QuickLook 不渲染 Markdown（把 `#`/`**`/`|` 原样画出）；② `FilePreviewScreen` 取回成功后又 `.sheet` 推一个全屏 QuickLook，于是连跳两个窗口。现在按扩展名分派到原生渲染器（Markdown / 文本 / 图片 / PDF），全在**同一页**；只有认不出的二进制才用 QuickLook 兜底 | 预览链路体验断裂 → 已解决 |
| F12 | **`workspaceFiles/readAll` 在本部署里没有实现** | 协议表列出了这个 unary，但活宿主对 `/api/workspaceFiles/readAll` 返回纯文本 `not found`（2026-10-16 实测）。客户端因此**不调用它** | 想要"一次拿全量文本"的调用方会拿到 404。绕开办法：`readBytes`（实测逐字节一致） |
| F13 | **`workspaceFiles/read` 的 `offset` 分页拼不回原文** | `read` 的窗口是 5000 行；`offset` 是**行号**，每页末尾**不含**换行而下一页也不重复它 → 逐页拼接的字节与磁盘**不一致**（页交界处丢内容，2026-10-16 实测）。`range.limit` 上限也只有 5000 | 客户端**不做翻页拼接**：超过窗口且 ≤ 8 MB 时改走 `readBytes` 整份取回；再大的只显示开头并如实说明。属宿主行为，已记入 `PROTOCOL-NOTES` §5 的 17-19，留待上游 |

### 3. 实时集成测试欠账（已清账）

- 20 条 `LiveIntegrationTests` 之前从未在发版时跑过（默认跳过）。2026-10-14 对活宿主实测：
  首轮 15 通过 / 1 失败（见 一-2，客户端侧已收口）/ 4 跳过；
  宿主在线后补跑 `DSH_LIVE_PROMPT=1` 的 3 条 prompt 级用例**全部通过**，
  并新增 2 条探针（审批往返、图片/文件附件，见 T2）——现共 22 条，
  `DSH_LIVE=1` + `DSH_LIVE_PROMPT=1` 下 **22 通过 / 0 失败**。
- **注意副作用**：这批测试会在宿主上真实建会话 / fork 会话（如
  `testCreateSessionLandsInTheChosenWorkspace`、`testForkCreatesANewSession`），
  各用例结束时会自行归档；跑挂（超时强杀）的残留要手动补归档。

---

## 三、测试与真机验证路线

### 1. 已具备的条件（本次已探测）

- **配对码**：`node tools/tether-status.mjs --pair` 打开配对窗口并打印完整配对串
  （10 分钟有效）；`--pairing` 之外还可 `--watch` / `--forget`。
  本机 tether 插件在线（`http://127.0.0.1:19387`），已有 1 台 iPhone 配对且**在线**。
  **真机实测（2026-10-14）**：电脑端重装插件会重建 `~/Library/Application Support/dsh-tether/identity.key`，
  设备 ID 与配对白名单一起作废，手机端表现为 iroh `Connect timed out`；重开配对窗口重新配对即恢复。
- **真机连接**：`xcrun devicectl list devices` 可见本机 iPhone 15 Pro（UDID `00008130-001475D90EE3803A`），
  可经 `devicectl` 安装 / 启动 / 截图；`bash ios/build.sh --device` 为真机构建入口（需签名）。
  用户另有本地 Xcode 应用 **devicehub.app**（自称与 devicectl 等价），
  尚未在本机定位到路径，确认后补记于此。
- **真机签名（无 Xcode 登录账号时的可行路径，2026-10-14 验证）**：
  Xcode 无登录账号，但 keychain 有有效 `Apple Development` 证书、
  `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` 有有效描述文件（团队 JQLTF5R83N）。
  仓库 bundle id `cc.unsplashz.dshpocket` 无对应描述文件，现成有效的是 `cc.zexa.dshpocket`；
  **不能**用命令行全局覆盖 `PRODUCT_BUNDLE_IDENTIFIER`（内嵌 Frameworks 会撞 id）。
  做法：临时改 `ios/project.yml` App target 的 bundle id → `xcodegen` →
  构建（`CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=JQLTF5R83N`，不加 `-allowProvisioningUpdates`）→
  成功后立即 `git checkout -- ios/project.yml ios/DSHPocket.xcodeproj/project.pbxproj` 并重新 `xcodegen` 还原。
  注意：换 bundle id 后钥匙串里的 iroh 身份不随包迁移（按 App 隔离），**相当于一台新手机，必须重新配对**。
- **真机冒烟结果（2026-10-14，M1 首轮）**：安装 → 启动 → 缓存会话列表 + 「连接中」横幅 →
  重新配对 → 蜂窝网络（5G，走 relay）下实时会话同步，全链路通过。
  截图证据在 `docs/artifacts/m1-device/`（01–05，含 iroh 超时报错屏）。
  devicectl 无触控/滚动能力，VoiceOver、动态字体等交互式 HIG 项仍需人工在机上操作。
- **协议层验证不需要手机**：`tools/direct-gateway.mjs` + `DSH_LIVE=1`（见 一-3）。

### 2. 仍欠的测试债

| # | 项 | 说明 |
| --- | --- | --- |
| T1 | ~~`SessionModel`（900+ 行）几乎无单测~~ | APP-REVIEW 建议：把队列合并、计时器起点、折叠后滚动抽成纯函数下沉 DSHKit 后再测。**已清（2026-10-14 两批）**：计时器起点（`TurnTimer`，含置信度）与时钟偏移（`HostClockOffset`）已在 DSHKit 有单测，`Composer.elapsedText` 有 App 层测试；队列合并（`applyingInboxSplice`）此前已在 DSHKit；流帧处置（`StreamFlowPolicy`：什么帧亮灯/灭灯、合帧还是立刻落屏）已抽成 DSHKit 纯函数，8 条决策表单测。16ms 合帧定时器本身是 MainActor Task，留在 App 层 |
| T2 | ~~M0a 三条协议探针未做~~ | **已做（2026-10-14，宿主在线实测）**：① `approval/request` 抓真 + `$events/result` 应答往返——新增 `testApprovalRoundTripActuallyReachesTheAgent`（read-only 档位下写盘必触发审批；实测发现 `workspace-write` + 写 /tmp 在 policy=ask 下宿主**不**审批，已写进测试注释）；② `user-questions/request` 往返——`testUserQuestionRoundTripActuallyReachesTheAgent` 通过；③ 图片（内联 base64）/文件（uploadFileBinary → receiptId）——新增 `testPromptWithImageAndFileAttachmentsIsAccepted` 通过。三条全绿，探针会话已清理归档 |
| T3 | 真机 HIG 走查 | 见 M1；可用 devicectl 驱动真机逐屏验证 |
| T4 | ~~`gen-strings.py` 已知边界~~ | **已修（2026-10-14）**：抽取与兜底扫描改用配对感知的字面量扫描器（`read_string_literal`，插值内嵌引号/嵌套括号递归处理），不再截出假 key；三引号多行块整块跳过。新增 `--selftest` 钉住扫描器行为。实测对照：清掉 8 条假 key/误收（插值碎片、「启用」来自日志行），补回 6 条完整字面量；目录 key 净变化 = 删 `启用`、删 `：%@`（均为旧误收），无新增遗漏 |

---

## 四、文档欠账

| # | 项 | 状态 |
| --- | --- | --- |
| D1 | ~~ROADMAP 中"更新 GLOSSARY/DECISIONS 中产生偏差的部分"~~ | 已做（2026-10-14）：易漂移点逐项核对一致，新偏差记入 ADR-0027，ROADMAP 已勾选 |
| D2 | `docs/` 设计文档仅中文 | 英文 README 已如实注明 |
| D3 | ~~`LiveIntegrationTests` 注释引用已更名 `dev-proxy.mjs`~~ | 已改（2026-10-14，与 KNOWN-ISSUES 同批提交） |

## 五、项目主动延后的方向（非缺陷）

Android 客户端、手机本地跑 dsh、App Intents / 快捷指令 / Widget、APNs 远程推送、
与桌面端的"正在输入 / 焦点同步"；两个上游 PR（tether 注入改可选开关、
修 `navList` 漏复位 `overflow-y`）。

---

## 附录：例行验证命令

```bash
# 三个测试套件
(cd ios/DSHKit && swift test) && (cd ios/TetherKit && swift test) && bash ios/build.sh --test

# 实时集成测试（需本机 DSH 宿主在跑）
node tools/direct-gateway.mjs &
DSH_LIVE=1 swift test --filter LiveIntegrationTests   # 在 ios/DSHKit 下

# 本地化与版本号
python3 ios/scripts/gen-strings.py --check
bash ios/scripts/version.sh check "$(bash ios/scripts/version.sh get)"

# 打包全链路
bash ios/scripts/make-ipa.sh
```
