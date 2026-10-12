# spikes

一次性的验证脚本：把协议事实钉死，**不是产品代码**。对应 [ROADMAP.md](../docs/ROADMAP.md) 的 M0a / M0b。

## `m0-probe.mjs`（M0a，已完成大半）

零依赖（Node ≥ 22 自带 `fetch` 与 `WebSocket`）。默认对着 `127.0.0.1:19387`，可用 `DSH_AUTHORITY` 覆盖。

```bash
node spikes/m0-probe.mjs unary session/list '{"_request":{}}'   # 列会话（含 projections）
node spikes/m0-probe.mjs unary session/modelCatalog             # 模型目录
node spikes/m0-probe.mjs events 10                              # $events 流（首帧应为 ready）
node spikes/m0-probe.mjs follow <sessionId> 10                  # 会话流（首帧应为 snapshot）
```

已核对结论见 [docs/PROTOCOL-0.2.0-rc.2.md](../docs/PROTOCOL-0.2.0-rc.2.md)。

> 为什么用 Node 而不是 Swift 先做：探针只是**证明线上契约成立**，结论与语言无关；Node 迭代最快、零依赖。真正的客户端实现是 Swift（见 [docs/DESIGN.md](../docs/DESIGN.md) §4）。

## `m0b-iroh-interop`（M0b，待建）

**最高风险的验证**：一个最小 Swift 程序连上现在正在跑的 `dsh-plugin-tether` sidecar。

要证明的事：

1. `iroh-ffi`（Swift，v1.1.0）能连上宿主（Rust，`iroh 1.0.3`）：ALPN `dsh-tether/0`、preset N0；
2. 控制流写 `{"type":"hello","name":"…"}` 后连接保持、可继续读；
3. 开一条代理流写 `{"type":"proxy"}`，随后用 `URLSession` 打 `GET /api/session/list` 拿到 200；
4. 摸清 `IrohLib` 的读取原语（是否只有 `readExact`），据此定下 JSON-lines 读行的实现。

做法：一个 SwiftPM 可执行目标（`swift run` 直接跑，不必先建 iOS App）；代码骨架见 [docs/TRANSPORT.md](../docs/TRANSPORT.md) §1、§4。

**若这一步失败**：回退方案见 [docs/DECISIONS.md](../docs/DECISIONS.md) ADR-0002 —— 而且必须在写任何界面代码之前就决定。
