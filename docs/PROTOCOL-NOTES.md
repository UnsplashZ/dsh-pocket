# DSH 客户端协议 · 已核对事实与复现方法

> 本文分两类内容，**请务必分清**：
> - 🔵 **本机核实**：在 `DSH 0.2.0-rc.2`（本机在跑的那份）上直接读过源码或发过请求验证的；
> - 🟡 **文档基线**：来自 [jayantTang/DSH_Mobile `docs/DSH-PROTOCOL.md`](https://github.com/jayantTang/DSH_Mobile/blob/main/docs/DSH-PROTOCOL.md)（3 383 行，对 DSH `0.1.5-rc.1` 活服务器逐条核对过），**尚未在 0.2.0-rc.2 上重新验证**。
>
> M0 的任务就是把 🟡 全部升级为 🔵，产出 `PROTOCOL-0.2.0-rc.2.md`。
>
> **实现语言**：客户端是 Swift（见 [DESIGN.md](DESIGN.md)）。本文描述的是**线上契约**，与语言无关；Swift 侧的模块划分见 DESIGN §4.1，传输与隧道见 [TRANSPORT.md](TRANSPORT.md)。

---

## 1. 传输与认证

### 1.1 🔵 浏览器认证（读自 `@deepseek-ai/dsh-client-connection`）

- 进程启动时生成一个随机 **launch token**，只印在启动 URL 上（`GET /?token=…`）；
- `GET /?token=<正确>` → **303** + `Set-Cookie`，然后重定向到干净路径；不带 cookie 的 `/` 与 `/api` 一律 **401**（本机实测：`GET /` → 401，正文 `dsh web authentication required; …`）；
- cookie 值格式：

```
name  = "dsh-auth-" + base64url(sha256(authority))
value = "v1." + base64url(JSON.stringify(payload)) + "." + base64url(hmac_sha256(secret, body))
payload = { version: 1, authority: "host:port", issuedAt, expiresAt }   // 毫秒时间戳
```

- 签名密钥是 `ctx.credentials` 里 `client-connection/browser-session` 的 32 字节密钥，持久化在 `$DSH_HOME/.credentials.yaml`（mode 600）；
- cookie 属性：`Max-Age`（默认 30 天绝对有效期）、`Path=/`、`HttpOnly`、`SameSite=Strict`，**不带 `Secure`**（因为本地是明文回环 HTTP）；
- `authority = new URL('http://' + Host头).host` —— 即 **cookie 与 host:port 绑定**。

> 本机可直接复现：`node tools/mint-cookie.cjs 127.0.0.1:19387` 现签一个合法 cookie，然后
> `curl -H "Cookie: <输出>" http://127.0.0.1:19387/` 会返回 200 与 SPA 的 index.html。

### 1.2 🔵 请求信任栅栏（`/api` 之前）

每个请求先过 `api-request-trust`：

- `Host` 必须是 **回环**（`localhost` / `127.0.0.0/8` / `[::1]`）或命中配置的 `trustedHosts`；
- 若带 `Origin`，其 authority **必须等于** `Host`；
- `sec-fetch-site: cross-site` 一律 **403**。

🟡 结论：**原生客户端应当干脆不发 `Origin`**；而"从另一个源（如 `tauri://localhost`）的前端直接打 `/api`"必然 403 —— 这正是 [DESIGN.md](DESIGN.md) §3.3 选择"把 SPA 由宿主同源托管"的原因。

### 1.3 🟡 服务端发现（endpoint 文件）

DSH 会写一个 `endpoint.json`（端口 / pid / 是否桌面壳 / 更新时间）。要点：

- **每次连接前重新读**：token 随重启轮换，`Set-Cookie` 必须重新兑换；
- 必须按**字面量 `127.0.0.1:<port>`** 连接：用 `localhost` 即使 cookie 合法也会 401（authority 绑定）。

---

## 2. tether 是怎么解决上面这些的（🔵 读源码）

```
手机侧                                        电脑侧
app/src-tauri/src/lib.rs                     dsh-plugin-tether/index.js
  proxy_port_for(peer)  ← 端口按主机 id 派生    connection.authenticatedUrl('http://127.0.0.1:<port>/')
  TcpListener on 127.0.0.1:<派生端口>            → fetch → 303 → Set-Cookie
  每个 TCP 连接 → iroh 流 ──DLP v1──►           → 把 cookie 与 authority 交给 sidecar
                                              sidecar: rewrite_request_head()
                                                · 注入 Cookie
                                                · 改写 Host 为 authority
                                              → 转发到真实 127.0.0.1:<port>
```

关键设计点（**我们的方案原样保留**）：

1. **cookie 在电脑侧兑换**。手机 WebView 处于跨站上下文，`SameSite=Strict` 的 cookie 根本不会随请求发出，把 token 给手机没用；
2. **端口按主机派生**（`proxy_port_for`）→ 同一台主机的代理 origin 稳定，cookie 的 authority 绑定才不会每次失效；
3. **逐请求注入**发生在代理层，因此**任何**从该 origin 发出的请求（含 WS 升级）都自带认证 —— 我们的 Pocket SPA 因此完全不用碰 token/cookie。

---

## 3. 端点目录（🟡 基线 `0.1.5-rc.1`，共 47 行）

来源：`DSH_Mobile/docs/dsh-rpc-catalog.json`（`generatedAt` 快照）。其中 **45 个是包端点**（4 stream + 41 unary），另 2 个是网关内部端点（`$events`、`$events/result`），后者不在任何包的 FaceModel 里但实现事件通道必须有。

| kind | method | 参数（节选） |
|---|---|---|
| stream | `$events` | — |
| unary | `$events/result` | clientId, eventId, outcome |
| unary | `credentials/describe` | refs |
| unary | `credentials/set` | ref, value |
| unary | `credentials/unset` | ref |
| unary | `directoryPicker/createDirectory` | path, name |
| unary | `directoryPicker/list` | path |
| unary | `directoryPicker/pick` | — |
| unary | `fileReferences/list` | agentId, query |
| unary | `session/attachment` | request |
| unary | `session/cancel` | request |
| unary | `session/canOpenWorkspacePath` | — |
| stream | `session/control` | — |
| unary | `session/create` | request |
| stream | `session/follow` | request |
| unary | `session/fork` | request |
| unary | `session/list` | _request |
| unary | `session/modelCatalog` | — |
| unary | `session/openWorkspacePath` | request |
| unary | `session/page` | request |
| unary | `session/prompt` | request |
| unary | `session/rename` | request |
| unary | `session/search` | request |
| unary | `session/selectModel` | request |
| unary | `session/updateQueue` | request |
| unary | `settings/canOpenAgentPresetDirectory` | — |
| unary | `settings/describe` | — |
| unary | `settings/mutate` | ns, ops, expectedRevision |
| unary | `settings/openAgentPresetDirectory` | agentPreset |
| unary | `settings/openSettingsDocument` | — |
| unary | `settings/replace` | ns, section, expectedRevision |
| unary | `settings/update` | ns, patch, expectedRevision |
| unary | `skills/list` | request |
| unary | `workspace/archiveSession` | request |
| unary | `workspace/create` | request |
| unary | `workspace/delete` | request |
| stream | `workspace/follow` | — |
| unary | `workspace/insertBefore` | request |
| unary | `workspace/insertSessionBefore` | request |
| unary | `workspace/rename` | request |
| stream | `workspaceFiles/changes` | workspaceFileScopeId |
| unary | `workspaceFiles/list` | workspaceFileScopeId, path |
| unary | `workspaceFiles/read` | workspaceFileScopeId, path, range |
| unary | `workspaceFiles/readAll` | workspaceFileScopeId, path |
| unary | `workspaceFiles/readBytes` | workspaceFileScopeId, path, range |
| unary | `workspaceFiles/readRelated` | workspaceFileScopeId, path, relativePath |
| unary | `workspaceFiles/stat` | workspaceFileScopeId, path |

**Pocket 一期只用其中约 20 个**，见 [DESIGN.md](DESIGN.md) §4.2。

---

## 4. 三种调用形态

### 4.1 Unary（🟡）

- `POST /api/<method>`，`Content-Type: application/json`，body 是 JSON；
- **业务错误也返回 HTTP 200** → 必须判响应体里的 `result.ok`，不能看状态码；
- 只有"路由不认识"（未知方法 / 用了 GET）才 404，正文是纯文本 `not found`；
- 参数是**具名对象**：`{"args":{"request":{…}}}`，不是数组；
- 描述符校验双向严格：**多余字段会被拒绝**（这反过来也是运行时探测签名的好办法）。

### 4.2 流（🟡 单条 WebSocket 多路复用）

```
ws://127.0.0.1:<port>/api/remote.mux      Cookie: <cookie>

上行: { "type":"open",   "streamId":"s1", "endpoint":"session/follow", "payload": { "args": {…} } }
      { "type":"cancel", "streamId":"s1" }
下行: { "type":"item",  "streamId":"s1", "value": <一个流值> }
      { "type":"error", "streamId":"s1", "error": { code, message, details } }
      { "type":"end",   "streamId":"s1" }
```

- `streamId` 客户端自选，回显；**开流失败也是 `error` 帧，不是 HTTP 错误**；
- 没有逐流确认；`cancel` 或关socket 即结束该世代。

### 4.3 `$events` 的世代与 waterfall（🟡）

- 必须用**空 args** 打开：`{"args":{}}`（多一个 `null` 都会被拒）；
- 首帧恒为 `{type:'ready', clientId, host:{home}}`，它**绑定本次连接的世代**；重连后旧 `clientId` 失效；
- 之后是 `emit`（通知，无需应答）与 `waterfall`（**必须应答** `$events/result`，否则宿主侧操作一直阻塞）；
- 转发事件是**固定 19 项允许清单**（`approval/request`、`user-questions/request`、`agent-preset/selected` 等）。

---

## 5. 必须记住的坑（🟡 摘自原文档 §6，按对我们的杀伤力排序）

1. **聊天内容不在 `$events`**，在 `session/follow` 的持久事件流里；两处的 `assistant-stream` 又是第三种东西。三条通道别混（原文档 §4.1）。
2. **`surfaceOp: {op:'replace', startSeq, endSeq}`** —— 该事件**取代**区间内的 surface 节点（压缩就是这么干的）。线性追加渲染器会显示重复内容。
3. **`session/page` 必须带 `throughSeq`**（取自 `session/follow` 快照的 `cursor`）。
4. **`session/follow` 快照可以非常大**：实测 279 条记录 / ~670 KB compact JSON 且 `hasMore: true` → 流式解析。
5. **`session/control` 是全宿主范围的**（含每个活会话的队列/任务/投影）→ 只取当前会话。
6. **`maxMessages` 必须是正的 safe integer**（`0` 会被拒）。
7. **`session/list` 的 `cursor` 被忽略**，也没有 `nextCursor` → 不要做分页。
8. **`session/search` 在本部署默认关闭**（索引 `openAt: "never"`）→ 当作可选能力。
9. **`directoryPicker/pick` 会在电脑上弹出系统对话框** → 客户端绝不能投机调用。
10. **`workspaceFiles` 有两套路径词汇**：`list` 用工作区相对路径，`read`/`readBytes`/`readAll`/`stat`/`changes` 用绝对路径。
11. **`workspaceFileScopeId` 就是会话/agent id**，且该会话必须活着。
12. **二进制在 JSON 里是 base64**（`SessionAttachmentValue.data`、`WorkspaceFileBytes.data`；后者的 `bytes` 是完整文件大小而非窗口大小）。
13. **`settings/*` 是乐观并发**（`expectedRevision`），冲突返回 `settings/conflict`。
14. **凭据只写不读**（`credentials/describe` 只回 `{configured, source, writable}`）。
15. **时间戳是 epoch 毫秒**，唯独 `WorkspaceView.createdAt/updatedAt` 是 ISO-8601 字符串。
16. 上游文档自身也承认存在未决项（`team/*` 事件在本机安装里没有声明、源码与活服务器有若干不一致）—— **以活服务器为准**。

---

## 6. 本机现成可用的验证手段

| 目的 | 办法 |
|---|---|
| 拿到"手机看到的那份产物" | `node tools/mint-cookie.cjs 127.0.0.1:19387` → `curl -H "Cookie: …" http://127.0.0.1:19387/ -o index.html` |
| 在桌面浏览器里以手机视口迭代 | Playwright（Chromium / WebKit 均已在本机可用）：`--browser webkit --mobile` + `resize 393 852` |
| 真机截图 | `xcrun devicectl device capture screenshot --device <UDID> --destination x.png` |
| 真机装机 | `dsh-tether/ios-dist/resign-install.sh`（未签名 IPA + 个人团队重签 + `devicectl install/launch`） |
| 实时看事件流 | M0 起用 `tools/dev-proxy.mjs` 把 `/api` 与 WS 转发到 127.0.0.1:19387，DevTools Network 面板直接看帧 |
