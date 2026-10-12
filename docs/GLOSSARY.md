# 术语表

| 术语 | 含义 |
|---|---|
| **DSH** / DeepSeek Harness | DeepSeek 的 agent 运行时。本项目的"服务端"就是它，**不改上游** |
| **host / 宿主** | 跑着 DSH 的那台电脑与那个进程。会话、工具执行、模型调用都在这里发生 |
| **电脑端 / 客户端** | 本项目的两侧：电脑端 = Mac 上的 DSH + 插件；客户端 = iPhone 上的 App |
| **`dsh-plugin-tether`** | 电脑端插件（npm）。负责 iroh endpoint、配对窗口、设备白名单、cookie 兑换与逐请求注入、代理流。**本项目原样复用，一行不改**（ADR-0003） |
| **sidecar / `tether-host`** | 上面那个插件拉起的原生进程（Rust）。iroh 连接与代理流实际由它处理 |
| **DLP v1** | 手机与电脑之间的线协议（控制流 JSON-lines + 代理流原始字节）。契约在 `tether-core/src/lib.rs` |
| **endpoint / endpoint id** | iroh 的一个节点与其 64 位十六进制公钥 ID。**手机的公钥就是它的设备身份**，配对即把它写进电脑端白名单 |
| **配对串** | 电脑端显示的 `<endpointId>#<6位码>`，手机扫码或粘贴 |
| **配对窗口** | 电脑端点「连接手机」后开的 10 分钟窗口，允许 3 次尝试 |
| **relay / 中转** | iroh 的公共中转（preset N0 自带）。打洞失败时兜底，**只看到密文** |
| **direct 路径** | 打洞成功、两端直连。诊断页要显示当前是 direct 还是 relay |
| **世代 / generation** | 一次 `$events` 连接的生命周期，由首帧 `ready` 里的 `clientId` 标识；重连即新世代，旧的不再有效 |
| **mux / `streamId`** | 所有流共用一条 WebSocket（`/api/remote.mux`）；`streamId` 由客户端自选，用于区分逻辑流 |
| **`$events`** | DSH 推应用事件给客户端的唯一通道。首帧 `ready`，之后是 `emit`（通知）与 `waterfall`（**必须应答**） |
| **waterfall** | 宿主向客户端"提问"（审批、提问）。用 `$events/result` 应答；不能答就回 `{kind:'next'}` 委派，**不能不答** |
| **`session/follow`** | 会话流：首帧是快照，之后是持久事件与（可选）实时助手帧。**聊天界面要的一切都在这里**，不在 `$events` |
| **`SessionWireEvent`** | 持久事件的信封：`{type, seq, time, data, surfaceOp?, …}`。56 种类型（`turn/start`、`tool/call`…） |
| **`surfaceOp` / `replace`** | 事件的"落位"声明。`{op:'replace', startSeq, endSeq}` 表示该事件**取代**区间内的 surface 节点（压缩会用）。线性追加渲染器必须处理它，否则重复 |
| **`seq`** | 会话内单调递增的事件序号。断线续拉、去重、排序都靠它 |
| **`cursor` / `throughSeq`** | `session/follow` 快照给出的游标；`session/page` 必须带 `throughSeq` 才能向上翻历史 |
| **projections** | `session/list` 返回的会话投影（标题、最后一轮问答、token、上下文压力、是否在跑）。**够撑列表页，不必开会话流** |
| **turn / step** | 一轮对话 / 轮内的一个步骤。时间线按 turn 分组、按 step 排列 |
| **approval / user-questions** | 审批与提问：agent 停下来等人。移动端最不可替代的价值就在这里 |
| **`present`** | agent 明确交付的文件/产物（图片、报告），需要客户端展示或分享 |
| **HIG** | Apple Human Interface Guidelines。本项目的界面验收依据是 [IOS-DESIGN.md](IOS-DESIGN.md) |
| **动态字体 / Dynamic Type** | 系统字号设置（AX1–AX5）。界面必须在全部档位不破版 |
| **VoiceOver** | iOS 读屏。验收要求：能独立完成"选会话 → 读对话 → 发消息 → 批审批" |
| **ATS** | App Transport Security。本项目只开 `NSAllowsLocalNetworking`（回环 + .local） |
| **本地网络权限** | iOS 14+ 对同网段私网收发的内核级管控。缺 `NSLocalNetworkUsageDescription` 会静默超时（tether issue #6 的方向） |
| **个人团队 / 描述文件** | 免费 Apple 开发者账号的签名方式：证书 **7 天**过期，需要重新签名安装 |
| **TestFlight** | Apple 的测试分发。需要付费账号；构建 90 天过期 |
| **ADR** | Architecture Decision Record，见 [DECISIONS.md](DECISIONS.md) |
| **DEV-DIRECT** | 开发模式：App 直连 Mac 上的 dev 代理（注入 cookie），绕开 iroh，见 [DECISIONS.md](DECISIONS.md) ADR-0009 |
