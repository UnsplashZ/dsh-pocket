# 路线图（可勾选任务清单）

> 每个里程碑结束都要在**真机 iPhone** 上按验收项过一遍。未勾选的条目 = 还没做。
> 依赖关系：M0a / M0b 是**并行**的两条前置线，两者都完成才能进 M1。
>
> **当前状态（2026-10-12）**：M0a 基本完成、**M0b 已通过**（见 [artifacts/M0B-EVIDENCE.md](artifacts/M0B-EVIDENCE.md)）、
> M1/M2 代码完成并在模拟器上对着**活着的 DSH** 验证过；M3/M4 剩真机验收与签名流程。

---

## M0a · DSH 协议 spike

目标：把 `SESSION`/事件/审批这条链在**不依赖手机、不依赖 iroh**的前提下打通并固化成文档。

- [x] 本机探针（Node，零依赖）：`spikes/m0-probe.mjs`
- [x] `session/list` 通（拿到真实会话与 projections）→ 记录在 [PROTOCOL-0.2.0-rc.2.md](PROTOCOL-0.2.0-rc.2.md)
- [x] WS mux + `$events` 通（首帧 `ready`）
- [x] `session/follow` 通（snapshot + `assistant-stream`），并纠正参数为 `address: {kind:'session', sessionId}`
- [x] **抓包工具**：`tools/capture-session.mjs`（把真实帧序列落成样本，供 Swift 解码器当"活服务器事实"）
- [x] **Swift 侧等价物**：`DSHKit` 的 `LiveIntegrationTests`（`DSH_LIVE=1 swift test`）在真宿主上跑
      unary / `$events` / `session/follow` / `session/page` 四条路径 —— 这是比 Node 探针更强的回归
- [x] `session/page`：用 follow 快照的 `cursor` 作为 `throughSeq` 向上补一页，验证不重不漏
      （`testPageBackwardsIsContiguous` 断言页内升序、无重复、不越过 `throughSeq`）
- [x] `tools/direct-gateway.mjs`：注入 cookie 的本地代理（HTTP + WS 升级都通，DEV-DIRECT 用）
- [x] **枚举端点并核对**：读 DSH 本机安装的 `dsh-api-remotes` 允许清单（27 条转发事件，
      其中 `approval/request`、`user-questions/request` 是 waterfall）→ 更新本文档与 PROTOCOL-NOTES
- [x] `session/prompt` 在活服务器上**真的发出去过**（`testLivePromptIsAccepted`：建临时会话 → 发一条 → 断言 accepted → cancel）
- [x] `session/cancel` / `session/selectModel` 同样实跑通过
      （踩过的坑：`mode` 必填、图片内联 base64、`cancel` 只收 sessionId、`selectModel` 是扁平的）
- [x] `session/follow` **半实时**验证：另一个写入者追加的事件 0.5 秒内到达（`testFollowDeliversEventsAppendedByAnotherWriter`）
- [ ] 抓一次真实 `approval/request`（waterfall），并用 `$events/result` 成功应答
- [ ] 抓一次 `user-questions/request` 并应答
- [ ] 确认图片/文件的正确路径：已确认**两条**（`session/attachment` base64、`POST /api/session/uploadFileBinary`
      原始字节 + receipt），但还没有在活服务器上跑通一次真实上传

**验收**：上述全部勾选；`PROTOCOL-0.2.0-rc.2.md` 不再有"未验证"段落。

---

## M0b · 传输互通（最高技术风险，必须最先证伪）

目标：**Swift 客户端连上现在正在跑的 `dsh-plugin-tether` sidecar**，跑通 Hello 并成功代理一次 HTTP。

> **全部通过。** 原始输出与复现命令见 [artifacts/M0B-EVIDENCE.md](artifacts/M0B-EVIDENCE.md)。

- [x] 建 Xcode 工程 + SwiftPM 包骨架；加 IrohLib；iOS 链接 `-framework Network`
- [x] 身份：`SecretKey.generate()` → Keychain 持久化 → `secret.public().description` 稳定
      （`TetherIdentity.loadOrCreate`，有"同一份存储给出同一把身份"的单测）
- [x] `Endpoint.bind(options: EndpointOptions(preset: presetN0(), secretKey:, alpns: ["dsh-tether/0"]))`
- [x] `EndpointId.fromString` + `EndpointAddr(id:relayUrl:nil,addresses:[])` + `ep.connect`
- [x] 控制流：`conn.openBi()` → 写 `{"type":"hello","name":"…"}` → 保持读循环
- [x] 代理流：`conn.openBi()` → 写 `{"type":"proxy"}` → 原始字节双向拷贝
- [x] 本地监听 + 端口公式（`20000 + u16([b0,b1]) % 12000`）→ 用 `URLSession` 打 `GET /api/session/list` 拿到 200
- [x] **确认 IrohLib 的读取原语**：有 `read(sizeLimit:)`，所以 JSON-lines 按块读 + 切 `\n` 即可，
      **不需要**退化成逐字节读（TRANSPORT §4.4 的"待验证"已消解）
- [x] 配对流程：`{"type":"pair","code":"…"}` → `pair-ok` / `pair-fail` 全部分支
      （四种原因码都有本地化文案 + 单测；`no-window` 在真链路上实测过）
- [x] 记录实测结论：iroh-ffi 1.1.0 ↔ iroh 1.0.3 **互通**；direct RTT 0–1ms、relay RTT 761ms

**验收**：真机上完成一次配对 + 一次 `/api/session/list` 成功；`CONNECTED` 后电脑端日志无异常。
→ **桌面侧已完整通过**（同一份代码）；真机侧待 M4 的签名流程就绪后补一次。

---

## M1 · 只读客户端（第一个"像正经 App"的版本）

- [x] 工程结构：`ios/DSHPocket/`（App, DesignSystem, Features, Resources）+ `ios/DSHKit` + `ios/TetherKit`
- [x] `DSHKit`：RPC 客户端、Mux 客户端、`$events`、`session/list`、`session/follow`、`Timeline` 投影
- [x] `SessionListView`（[IOS-DESIGN](IOS-DESIGN.md) S1）：分组、行、下拉刷新、空/加载/离线态
- [x] `SessionView`（S2）：`LazyVStack` 时间线、turn 分组、用户/助手消息、工具折叠行、流式追加、贴底策略 + 「跳到最新」
- [x] 断线重连：世代失效 → 重订阅 → 按 `seq` 补齐；UI 三态
- [x] 设计令牌落地：语义字体/颜色、圆角、SF Symbols、触感、材质
- [x] 深色模式 + 动态字体（AX1–AX5 不破版的设计约束已落进组件）
- [x] **快照分批入视图**：831 KB 级快照先出骨架，再按 120 条一批折叠 + `Task.yield()`

**验收（真机）**：滚动流畅无残影；历史与实时都正确；断网 30s 恢复后自动补齐；AX1/AX5 不破版；深色正常。
→ 模拟器上已对着活宿主验证；真机流畅度待 M4 后补。

---

## M2 · 可交互

- [x] `Composer`（S3）：多行、附件、发送/停止形态切换、草稿（每会话独立，随会话模型存活）
- [x] `session/prompt` / `session/cancel` 接通，发送后立即乐观插入并在流里对齐（以 `rpcId` 收敛）
      （形状修正见 M0a：`mode` 必填、图片内联 base64）
- [x] 工具调用展开/收起 + 长结果「查看全部 / 分享」+ 代码块复制
- [x] 审批（S4）：时间线卡片 + 通知；决策走 `$events/result`；「稍后」
- [x] 提问（`user-questions/request`）：单选/多选/开放文本
- [x] 模型切换（`session/modelCatalog` / `session/selectModel`）
      —— 注意模型在 `groups[].models[]`，推理强度**按模型**取
- [x] **权限档位**（`permissionPresets/catalog` 读 + `/permission <preset>` 命令写，见 ADR-0014）
- [x] 图片（`PhotosPicker`）与文件（`.fileImporter`）上传（走 `POST /api/session/uploadFileBinary`）
- [x] 文件浏览（S5）：`workspaceFiles/list|read` + QuickLook
- [x] `present` 产物的取回与分享（时间线内产物卡 + ShareLink）

**验收（真机）**：完整跑一轮"提需求 → 看工具 → 批一次审批 → 收结果"；发图后在会话里可见；审批通知可点开并作答。

---

## M3 · 打磨与 HIG 审计

- [x] 逐项过 [IOS-DESIGN.md](IOS-DESIGN.md) §11 自检清单（代码层已逐条落实，**真机逐项打勾待做**）
- [x] 触感（`.sensoryFeedback`：发送/停止/审批）、`reduceMotion` 分支
- [x] iPad `NavigationSplitView` 两栏
- [x] 设置页（S6）：主机管理、通知开关、外观、**诊断页**（direct/relay 路径、端点自检、日志导出）
- [x] `PrivacyInfo.xcprivacy` + Info.plist 复核（只开 `NSAllowsLocalNetworking`）
- [x] 首次启动的说明页（隐私 + 安全边界 + 用途）
- [x] 本地化 zh-Hans/en 完整（**236 条**，`ios/scripts/gen-strings.py --check` 可回归）
- [x] 配对失败原因码本地化（四种码都有文案，且有"文案里不能出现码本身"的断言）
- [ ] **真机逐项走一遍**：VoiceOver 全流程、AX1/AX3/AX5 三档、Increase Contrast、Voice Control
- [ ] 审批通知的三个操作按钮（批准一次 / 拒绝 / 稍后）—— 目前通知只是提醒，点开回到 App

**验收**：自检清单全绿；无 P0/P1 级无障碍问题。

---

## M4 · 分发

- [x] `scripts/install-device.sh`：`xcodebuild -allowProvisioningUpdates` + `devicectl install/launch`，
      含描述文件续期提示与"信任开发者证书"指引
- [x] 版本号与构建号策略（`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`）
- [x] README 的"从 0 到可用"步骤复核
- [ ] **在一台干净设备上真机走一遍**（含首次「本地网络」权限询问）
- [ ] 若用 TestFlight：需要付费账号；写清楚审核说明与演示路径
- [ ] 更新 [GLOSSARY.md](GLOSSARY.md)/[DECISIONS.md](DECISIONS.md) 中产生偏差的部分

**验收**：全新设备 0 → 可用 ≤ 10 分钟（含信任开发者证书）。

---

## 明确延后（不进本期）

- Android 客户端（[DESIGN.md](DESIGN.md) §3.5 保留了可行性）
- 手机本地跑 dsh（tether 的 Android 本地模式思路）
- App Intents / 快捷指令 / Widget
- APNs 远程推送（需付费账号；本地通知已覆盖一期）
- 桌面端与移动端共享会话的"正在输入/焦点同步"
- 上游 PR：把 tether 的注入改成可选开关、修 `navList` 漏复位 `overflow-y`

---

## 怎么跑起来（开发者视角）

```bash
# 依赖（一次）：把 iroh 的预编译部件取到 ios/vendor/（133 MB，不入库）
bash ios/scripts/fetch-iroh.sh

# 库的测试（macOS，不需要模拟器、不需要网络）
cd ios/DSHKit   && swift test --disable-sandbox      # 47 条
cd ios/TetherKit && swift test --disable-sandbox     # 27 条

# 对着**活着的 DSH** 跑协议回归（需要先起 dev 代理）
node tools/direct-gateway.mjs &
cd ios/DSHKit && DSH_LIVE=1 swift test --disable-sandbox --filter LiveIntegration

# App：构建 + 单测 + 跑起来
bash ios/build.sh                 # 模拟器构建
bash ios/build.sh --test          # 15 条 App 层单测
bash ios/build.sh --run           # 装进模拟器并启动
bash scripts/install-device.sh    # 装到真机

# 传输层互通（M0b）
node tools/tether-host-dev.mjs --data-dir /tmp/tether --pair
cd ios/spikes/M0BInterop && swift run m0b-interop --endpoint <id> --code <6 位码>
```

> 受限沙箱环境（容器、CI、agent 会话）里构建 App 需要
> `DSH_POCKET_SWIFT_FLAGS="-disable-sandbox"`：Swift 编译器的宏插件宿主进程
> 不能再套一层 `sandbox-exec`，否则报 `swift-plugin-server produced malformed
> response`，表现成一排莫名其妙的 `cannot find '$xxx' in scope`。
> 细节与其它环境开关见 [../ios/build.sh](../ios/build.sh) 的文件头。
