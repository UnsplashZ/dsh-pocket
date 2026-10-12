# M0 核对结果：DSH `0.2.0-rc.2` 上的协议实测

> 起点：`docs/PROTOCOL-NOTES.md`（🟡 基线为 `0.1.5-rc.1`）
> 本轮：在**本机正在跑的 `0.2.0-rc.2`** 上用 [`spikes/m0-probe.mjs`](../spikes/m0-probe.mjs) 直接发请求验证
> 状态：进行中（截至 2026-10-12 12:2x）

## 1. 已验证可用（🔵 本机实测）

| # | 结论 | 证据 |
|---|---|---|
| 1 | **认证**：用 `tools/mint-cookie.cjs` 现签的 cookie，`GET /` 返回 200；不带 cookie 返回 401 | curl 对照 |
| 2 | **unary 信封**：`POST /api/session/list`，body `{type:'client-request', rpcId, method, payload:{args}}` → 200 + `{type:'server-response', rpcId, result:{ok:true, value}}` | `m0-probe.mjs unary session/list` |
| 3 | **`session/list` 参数名是 `_request`**（下划线开头），空对象即可 | 同上 |
| 4 | **WS 多路复用可用**：`ws://127.0.0.1:19387/api/remote.mux`，用 `{type:'open', streamId, endpoint:'$events', payload:{args:{}}}` 打开后**首帧确实是 `ready`**，带 `clientId` 与 `host.home` | `m0-probe.mjs events` |
| 5 | **`session/follow` 参数形状**：`{request:{address:{kind:'session', sessionId}, assistantStream:true}}` —— 我最初写成 `{request:{sessionId}}` 会被 `gateway/input-invalid` 拒（`details.field:"request"`），**必须用结构化 `address`** | 先失败后成功，两次抓包 |
| 6 | **`session/follow` 首帧是 `snapshot`**，随后是 `assistant-stream` 帧（会话在跑时持续来 `chunk`/`reasoning-delta`） | 同上 |
| 7 | **快照确实很大**：本次实测单会话快照 **831 077 字符**（比基线记录的 ~670 KB 还大）→ 流式解析是硬要求 | 同上 |
| 8 | Node 24 的全局 `WebSocket` **支持自定义 `headers`**（用于带 cookie），无需任何依赖 | spike 代码 |
| 9 | `session/list` 的 `value.items[].projections` 是 `{kind:'sequenced', asOfSeq, values:{…}}`，含 `title`、`turnOutline`、`tokenUsage`、`contextPressure`、`contextBreakdown`、`inbox`、`sessionStats`、`agentPreset`、`userQuestions`、`subagent*`、`agentTeam`、`permissions` | 实测 JSON |

**意义**：移动端最核心的两条路径（列会话、订阅会话流）在 `0.2.0-rc.2` 上确认可用，且用一段零依赖 Node 脚本就能验证 —— 说明协议层完全可以按 [DESIGN.md](DESIGN.md) §4 的方式在 **Swift** 里实现（探针只是"先证明契约成立"，结论与语言无关）。

## 2. 观察到的响应形状（结构，非原文）

```jsonc
// session/list →
{ "type":"server-response", "rpcId":"…",
  "result": { "ok": true, "value": {
    "items": [ {
      "sessionId": "session-<uuid>",
      "updatedAt": 1791778585376,          // epoch ms
      "agentAvailable": true, "running": true, "blank": false,
      "cwd": "/Users/…",
      "projections": { "kind":"sequenced", "asOfSeq": 275, "values": {
        "title": "…", "goal": null,
        "tokenUsage": { "uncachedInputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens" },
        "contextPressure": { "pressureTokens", "projectedTokens", "contextWindow" },
        "contextBreakdown": { "systemTokens", "toolsTokens", "messageTokens" },
        "inbox": { "next-turn": [], "next-step": [] },
        "sessionStats": { "turns", "steps", "llmMs", "toolMs", "ttftMs", … },
        "turnOutline": [ { "turn", "seq", "prompt", "response" } ],
        "agentPreset": "standard",
        "userQuestions": { "active": [], "settled": [] },
        "subagentCatalog": [], "subagentTiming": { "settledMs" },
        "subagent": null,
        "agentTeam": { "members": [ { "id", "name", "role", "phase" } ], "tasks": [] },
        "permissions": { "currentValue": "danger-full-access" }
      } }
    } ]
  } } }

// session/follow 首帧 →
{ "type":"item", "streamId":"s1", "value": {
    "type":"snapshot",
    "header": { "version":4, "id":"session-…", "createdAt":…, "cwd":"…", "isSeeded":false, "agentPreset":"standard" },
    "cursor": 315,                     // 就是 session/page 要的 throughSeq
    "records": [ { "type":"event", "event": { "type":"assistant/message", "seq":39, "time":…, "data":{…} } } ],
    "hasMore": true,
    "projections": { … } } }

// 随后的实时帧 →
{ "type":"item", "streamId":"s1", "value": {
    "type":"assistant-stream",
    "frame": { "type":"chunk", "attemptId":"session-…:52", "revision":29129, "index":241,
               "time":…, "chunk": { "type":"reasoning-delta", "index":0, "text":"…" } } } }
```

> 真实抓包含私人会话内容，因此**不入库**：`docs/artifacts/samples/` 已在 `.gitignore` 里，需要时用自己的 spike 现场生成。

## 3. 尚未验证（M0 剩余项）

- [ ] `session/prompt` 提交一条消息、并在 `session/follow` 里看到对应的完整事件序列（`turn/start` → `step/start` → `assistant/message` → `tool/call` → `tool/result`）
- [ ] `session/cancel` 打断
- [ ] `session/page`（带 `throughSeq`）+ `hasMore` 的补历史闭环
- [ ] `approval/request` 的 waterfall 抓一次真实样本，并成功用 `$events/result` 应答
- [ ] `user-questions/request` 同上
- [ ] `session/attachment` 与文件上传的确切路径（base64 vs 流式路由）
- [ ] `workspace/follow`、`workspaceFiles/*`（两套路径语义各验一次）
- [ ] 端点在 `0.2.0-rc.2` 上的**完整重新枚举**（对照基线的 47 行，标出新增/删除/改名）
- [ ] 宿主版本兼容区间：确定一个可断言的判据（端点探测 or 版本字段）

## 4. 对方案的回写

1. **DESIGN.md §4.2 的子集确认可用**，一期范围不需调整；
2. **`session/follow` 的快照比预期更大**（831 KB 量级）→ timeline 层必须"先出骨架、再增量填"，不能等待完整快照；
3. 因为 `assistant-stream` 帧带 `attemptId`/`revision`/`index`，**流式渲染可以做成可重放/可去重**的，不必依赖"到达顺序"；
4. `session/list` 的 `projections` 信息量足够撑起**会话列表页**（标题、最后一轮 prompt/response、token、上下文压力、是否在跑）——**列表页不需要再打开每条会话的流**，这是移动端省电省流的关键。
