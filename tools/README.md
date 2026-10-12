# tools

本机开发/验证用的小工具。都在电脑上跑，不参与手机端运行。

## `mint-cookie.cjs`

为某个 DSH host authority 现签一个合法的浏览器会话 cookie。

```bash
node tools/mint-cookie.cjs 127.0.0.1:19387
# 输出：dsh-auth-XXXXXXXX=v1.XXXX.XXXX   （一整行，可当 Cookie 头用）
```

也可以当模块用：

```js
const { cookieFor } = require('./tools/mint-cookie.cjs')
const cookie = cookieFor('127.0.0.1:19387')
```

### 它做了什么

读 `$DSH_HOME/.credentials.yaml` 里 `client-connection/browser-session` 的 32 字节密钥，按 DSH 的格式现签：

```
name  = "dsh-auth-" + base64url(sha256(authority))
value = "v1." + base64url(JSON({version:1, authority, issuedAt, expiresAt})) + "." + base64url(hmac_sha256(secret, body))
```

### 边界与注意

- **等价于你本人的浏览器会话凭据**：不要外传、不要入 git、不要贴进聊天记录。
- cookie **绑定 authority**：给 `127.0.0.1:19387` 签的不能用于 `localhost:19387`（DSH 会 401）。
- 默认有效期 30 天（与 DSH 自己的 `cookieMaxAgeDays` 默认一致），可随时重签。
- 只在**本机**有意义（手机端不需要它：代理层会逐请求注入 cookie）。

## `dev-proxy.mjs`（M0 计划中）

给 Pocket UI 的开发服务做代理：把 `/api/*` 与 WS 升级转发到 `127.0.0.1:19387`，并自动附加 `mint-cookie.cjs` 生成的 cookie。这样 UI 用 Vite dev server 热更新开发，协议请求与真机同源行为一致。
