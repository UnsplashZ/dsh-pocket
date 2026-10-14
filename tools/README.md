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

## `tether-status.mjs`

在**命令行**查看 `dsh-plugin-tether` 的配对码与连接状态 —— **不改插件一行**。

```bash
node tools/tether-status.mjs            # 端点 ID + 已配对手机 + 在线情况
node tools/tether-status.mjs --pair     # 另开配对窗口，打印完整配对串（10 分钟有效）
node tools/tether-status.mjs --watch    # 持续轮询，只在状态变化时打印
node tools/tether-status.mjs --forget <id前缀>   # 撤销一台手机（前缀需唯一，要确认）
node tools/tether-status.mjs --json     # 机器可读
```

### 它做了什么

插件自己往 DSH 的 web server 上注册了三个**只服务本机**的路由，它界面上那个弹窗就是调这几个：

| 路由 | 作用 |
| --- | --- |
| `GET /dsh-tether/pairing` | 开一个配对窗口 → `{pairingString, expiresInSec}` |
| `GET /dsh-tether/devices` | 已配对手机 + `online` 状态（sidecar 不在时 502） |
| `POST /dsh-tether/devices` | 撤销一台手机（body `{"id":"<64 位十六进制>"}`） |

插件的信任栅栏只挡浏览器（Host 必须回环、拒 `sec-fetch-site: cross-site`、带 Origin 时必须同源），
**不挡本机进程** —— 本机请求的 Host 天然是 `127.0.0.1:<port>`，直接通过，**也不需要浏览器会话 cookie**。
所以 curl/本脚本就能用，桌面端弹窗出不来时这是等价入口。

端点 ID 由 `identity.key`（32 字节 ed25519 私钥）**只读**推公钥得到（iroh 的 endpoint id 就是它），
不起进程、不开窗口、不动文件权限。

### 边界与注意

- `--pair` **每次调用都作废上一个码**并开新窗口（插件与 sidecar 的行为，非本脚本造成）。
- 端口默认 `19387`（可用 `--port` 或 `DSH_TETHER_PORT` 覆盖）；默认端口不对时用 `lsof` 扫本机监听端口找到装了插件的那台。
- 「当前是 P2P 直连还是 relay 中转」只在插件日志（stdio）里，本工具拿不到；这里能看的是**在线/离线**。
- `identity.key` 命中的是 sidecar 的 data-dir：macOS `~/Library/Application Support/dsh-tether`（可用 `--data-dir` 覆盖）。
- 不想跑脚本也行，浏览器地址栏直接开 `http://127.0.0.1:19387/dsh-tether/pairing`（顶层导航无 Origin，同样过栅栏），
  拿到的是原始 JSON；但**撤销设备只能走 POST**，那条得用脚本或 curl。

## `direct-gateway.mjs`（M0 计划中）

给 Pocket UI 的开发服务做代理：把 `/api/*` 与 WS 升级转发到 `127.0.0.1:19387`，并自动附加 `mint-cookie.cjs` 生成的 cookie。这样 UI 用 Vite dev server 热更新开发，协议请求与真机同源行为一致。
