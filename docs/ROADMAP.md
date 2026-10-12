# 路线图（可勾选任务清单）

> 每个里程碑结束都要在**真机 iPhone** 上按验收项过一遍。未勾选的条目 = 还没做。
> 依赖关系：M0a / M0b 是**并行**的两条前置线，两者都完成才能进 M1。

---

## M0a · DSH 协议 spike

目标：把 `SESSION`/事件/审批这条链在**不依赖手机、不依赖 iroh**的前提下打通并固化成文档。

- [x] 本机探针（Node，零依赖）：`spikes/m0-probe.mjs`
- [x] `session/list` 通（拿到真实会话与 projections）→ 记录在 [PROTOCOL-0.2.0-rc.2.md](PROTOCOL-0.2.0-rc.2.md)
- [x] WS mux + `$events` 通（首帧 `ready`）
- [x] `session/follow` 通（snapshot + `assistant-stream`），并纠正参数为 `address: {kind:'session', sessionId}`
- [ ] `session/prompt`：提交一条消息，并在同一 `session/follow` 里看完整事件序列（`turn/start` → `step/start` → `assistant/message` → `tool/call` → `tool/result`）
- [ ] `session/cancel`：打断正在跑的一轮，确认成功信号
- [ ] `session/page`：用 follow 快照的 `cursor` 作为 `throughSeq` 向上补一页，验证不重不漏
- [ ] 抓一次真实 `approval/request`（waterfall），并用 `$events/result` 成功应答
- [ ] 抓一次 `user-questions/request` 并应答
- [ ] 确认图片/文件的正确路径（`session/attachment` base64 vs 文件上传路由）
- [ ] 以 `0.2.0-rc.2` 重新枚举端点，与基线 47 行 diff（新增/删除/改名）→ 更新 [PROTOCOL-0.2.0-rc.2.md](PROTOCOL-0.2.0-rc.2.md)
- [ ] `tools/dev-proxy.mjs`：注入 cookie 的本地代理（供 DEV-DIRECT 用）

**验收**：上述全部勾选；`PROTOCOL-0.2.0-rc.2.md` 不再有"未验证"段落。

---

## M0b · 传输互通（最高技术风险，必须最先证伪）

目标：**Swift 客户端连上现在正在跑的 `dsh-plugin-tether` sidecar**，跑通 Hello 并成功代理一次 HTTP。

- [ ] 建 Xcode 工程 + SwiftPM 包骨架；加 IrohLib 包；iOS 链接 `-framework Network`；关 Previews
- [ ] 身份：`SecretKey.generate()` → Keychain 持久化 → `secret.public().description` 稳定
- [ ] `Endpoint.bind(preset: presetN0(), secretKey:, alpns: ["dsh-tether/0"])`
- [ ] `EndpointId.fromString` + `EndpointAddr(id:relayUrl:nil,addresses:[])` + `ep.connect`
- [ ] 控制流：`conn.openBi()` → 写 `{"type":"hello","name":"…"}` → 保持读循环
- [ ] 代理流：`conn.openBi()` → 写 `{"type":"proxy"}` → 原始字节双向拷贝
- [ ] 本地监听 + 端口公式（`20000 + u16([b0,b1]) % 12000`）→ 用 `URLSession` 打 `GET /api/session/list` 拿到 200
- [ ] **确认 IrohLib 的读取原语**（是否只能 `readExact`）→ 定下 JSON-lines 读行的实现（[TRANSPORT.md](TRANSPORT.md) §4.4）
- [ ] 配对流程：`{"type":"pair","code":"…"}` → `pair-ok` / `pair-fail` 全部分支
- [ ] 记录实测结论（iroh-ffi 1.1.0 ↔ iroh 1.0.3 互通性、RTT、是否走了 direct）

**验收**：真机上完成一次配对 + 一次 `/api/session/list` 成功；`CONNECTED` 后电脑端日志无异常。
**若失败**：回退方案见 [DECISIONS.md](DECISIONS.md) ADR-0002（自建 xcframework / 或改走 UniFFI 桥）。

---

## M1 · 只读客户端（第一个"像正经 App"的版本）

- [ ] 工程结构：`DSHPocket/`（Features, DesignSystem, Resources）+ `DSHKit` + `TetherKit`
- [ ] `DSHKit`：RPC 客户端、Mux 客户端、`$events`、`session/list`、`session/follow`、`Timeline` 投影
- [ ] `SessionListView`（[IOS-DESIGN](IOS-DESIGN.md) S1）：分组、行、下拉刷新、空/加载/离线态
- [ ] `SessionView`（S2）：`LazyVStack` 时间线、turn 分组、用户/助手消息、工具折叠行、流式追加、贴底策略 + 「跳到最新」
- [ ] 断线重连：世代失效 → 重订阅 → 按 `seq` 补齐；UI 三态
- [ ] 设计令牌落地：语义字体/颜色、圆角、SF Symbols、触感、材质
- [ ] 深色模式 + 动态字体 AX1/AX5 初检

**验收（真机）**：滚动流畅无残影；历史与实时都正确；断网 30s 恢复后自动补齐；AX1/AX5 不破版；深色正常。

---

## M2 · 可交互

- [ ] `Composer`（S3）：多行、附件、发送/停止形态切换、草稿持久化
- [ ] `session/prompt` / `session/cancel` 接通，发送后立即乐观插入并在流里对齐（以 `seq` 收敛）
- [ ] 工具调用展开/收起 + 长结果「查看全部」+ 代码块复制
- [ ] 审批（S4）：时间线卡片 + 通知；决策走 `$events/result`；「稍后」
- [ ] 提问（`user-questions/request`）：单选/多选/开放文本
- [ ] 模型切换（`session/modelCatalog` / `session/selectModel`）
- [ ] 图片（`PhotosPicker`）与文件（`.fileImporter`）上传
- [ ] 文件浏览（S5）：`workspaceFiles/list|stat|read` + QuickLook
- [ ] `present` 产物的取回与分享（QuickLook / ShareLink）

**验收（真机）**：完整跑一轮"提需求 → 看工具 → 批一次审批 → 收结果"；发图后在会话里可见；审批通知可点开并作答。

---

## M3 · 打磨与 HIG 审计

- [ ] 逐项过 [IOS-DESIGN.md](IOS-DESIGN.md) §11 自检清单（100%）
- [ ] VoiceOver 全流程走一遍（选会话 → 读对话 → 发消息 → 批审批）
- [ ] 触感、转场、`reduceMotion`、`Increase Contrast` 全过
- [ ] iPad `NavigationSplitView` 两栏
- [ ] 设置页（S6）：主机管理、通知开关、外观、**诊断页**（direct/relay 路径、DSH 版本、端点自检、日志导出）
- [ ] `PrivacyInfo.xcprivacy` + Info.plist 复核
- [ ] 首次启动的说明页（隐私 + 安全边界 + 用途）
- [ ] 本地化 zh-Hans/en 完整；配对失败原因码本地化

**验收**：自检清单全绿；无 P0/P1 级无障碍问题。

---

## M4 · 分发

- [ ] `scripts/install-device.sh`：`xcodebuild -allowProvisioningUpdates` + `devicectl install/launch`，含描述文件续期提示
- [ ] 版本号与构建号策略（`CFBundleVersion` 单调递增）
- [ ] 若用 TestFlight：需要付费账号；写清楚审核说明与演示路径
- [ ] README 的"从 0 到可用"步骤复核（换一台干净设备走一遍）
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
