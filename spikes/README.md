# spikes

一次性的验证脚本，用来把协议事实钉死（对应 [DESIGN.md](../docs/DESIGN.md) 的 M0）。不是产品代码。

## `m0-probe.mjs`

零依赖（Node ≥ 22 自带 `fetch` 与 `WebSocket`）。默认对着 `127.0.0.1:19387`，可用 `DSH_AUTHORITY` 覆盖。

```bash
node spikes/m0-probe.mjs unary session/list '{"_request":{}}'   # 列会话
node spikes/m0-probe.mjs unary session/modelCatalog             # 模型目录
node spikes/m0-probe.mjs events 10                              # $events 流（应首帧 ready）
node spikes/m0-probe.mjs follow <sessionId> 10                  # 会话流（应首帧 snapshot）
```

已核对结论记录在 [docs/PROTOCOL-0.2.0-rc.2.md](../docs/PROTOCOL-0.2.0-rc.2.md)。
