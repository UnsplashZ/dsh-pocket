# dsh-plugin-uplink · 多路接入插件设计

> 状态：**设计稿（待评审）** · 2026-10-22
> 前置调研：[TRANSPORT-UPGRADE.md](TRANSPORT-UPGRADE.md)（为什么必须换路：中继 42 KB/s vs 直连 12 ms）
> 一句话：把「手机怎么连上电脑」从**一种协议**变成**一份可勾选的地址清单** —— 电脑侧起一个网关，
> 把 DSH 同时暴露在若干条路径上；手机侧并行探一下，谁快用谁。

---

## 1. 目标与非目标

**目标**

- 原生支持四类通路，用户可逐项勾选：**局域网**、**虚拟组网**（Tailscale / ZeroTier）、
  **自建中转**（frp / iroh-relay）、**iroh 中转**（n0 兜底）。
- 虚拟组网**自动检测**：装了就自动出现在清单里；装了没登录给出可操作提示；不需要用户填 IP。
- 自建中转**按需填表**：地址、端口、token、TLS 四五项；托管模式由插件自己拉起客户端。
- 手机侧**零手填**：配对一次，之后所有档位复用同一份凭据。

**非目标**

- 不做账号体系、多用户、中继计费。
- 不内嵌 Tailscale / ZeroTier SDK（用官方 App，避开审核与包体问题）。
- 不重写 iroh（继续用 `dsh-tether-host` 的 Rust 实现，见 §15）。

---

## 2. 为什么是新插件，而不是改 tether

现在的 `dsh-plugin-tether` 把四件事焊在一起：iroh sidecar 生命周期、配对与设备白名单、
cookie 兑换与注入、窄屏界面注入。而真正缺的那件事 ——「把 DSH 暴露到局域网 / Tailnet / frp 上」——
它**没有**，也不该有：那是另一层职责。

拆开看，四件事里只有两件是**必须**的（cookie 注入、设备鉴权）；iroh 只是**其中一条路**。
所以新插件的定位是：

> **一个网关（必须）+ N 个发布面（可选）+ 一条控制面（iroh，可关）**

| 职责 | 现状 tether | uplink |
|---|---|---|
| cookie 兑换 / 逐请求注入 | ✅ | ✅（唯一与 dsh 内部耦合的地方） |
| 设备鉴权 | ✅ 白名单（只服务 iroh） | ✅ 令牌（所有档位通用） |
| iroh 传输 | ✅ 硬绑定 | ⭕ 可选（复用同一 sidecar 二进制） |
| 局域网 / 虚拟组网 / 自建中转 | ❌ | ✅ 核心 |
| 窄屏界面注入 | ✅ | ❌ 交给 dsh 自己（手机端是原生 App，不走 Web） |

---

## 3. 核心抽象：一个网关 + N 个面

这是"简洁"的来源：**四类通路不是四套协议，而是同一个网关的四种到达方式。**

```
手机（并行探测，谁先 ping 通就用谁）
  │
  ├─ ① 局域网    http://10.8.54.221:18788 ──┐
  ├─ ② Tailscale http://100.101.2.3:18788 ──┤ 同一个监听 socket
  ├─ ③ ZeroTier  http://10.147.20.5:18788 ──┘
  ├─ ④ frp       https://dsh.example.com  ──► frpc ──► 同一端口（公网映射）
  └─ ⑤ iroh      QUIC/UDP + endpointId    ──► tether-host sidecar（可选）

              ┌──────────────────────────────────────────┐
              │ uplink 网关  0.0.0.0:18788               │
              │ 鉴权 → 注入 cookie → 反向代理 HTTP/WS    │
              └───────────────────┬──────────────────────┘
                                  │ 127.0.0.1:<dshPort>
                                  ▼
                          DSH web server（只监听回环）
```

图中 ①–⑤ 是**具体档位**；产品上归为**四类**：局域网（①）、虚拟组网（②③）、
自建中转（④）、iroh 中转（⑤）。

三条推论：

1. **LAN / Tailscale / ZeroTier 共用同一个监听**。网关绑 `0.0.0.0`，tailnet 地址天然就在这个
   socket 上 —— 这三档的成本只有「枚举地址 + 广播」，**没有额外数据通路**。
2. **frp 不改网关**。它只是把同一个端口从公网映射进来。插件要做的只是生成配置 +
   （可选）拉起 `frpc` + 把公网 URL 写进清单。
3. **iroh 是唯一需要额外进程的一档**，且可以整档关掉。

于是模块只有八个：

```
index.js            cordis 入口：读配置、起网关、装配各面、注册管理路由
core/cookie.js      兑换 + 12h 续期（唯一碰 dsh 内部的地方）
core/gateway.js     HTTP/WS 反向代理 + 注入 + 鉴权中间件
core/auth.js        设备密钥、挑战-应答、短期票据、限流
core/detect.js      接口枚举 + tailscale/zerotier 命令探测 + 网络指纹
core/publish.js     Bonjour 广播 + 清单(descriptor)构造
tiers/iroh.js       sidecar 生命周期（可选依赖）
tiers/frp.js        frpc 配置生成 / 托管
```

---

## 4. 配置模型

一份 YAML，就是用户在设置页看到的那张表：

```yaml
uplink:
  port: 18788            # 网关端口；0 = 自动分配
  bind: 0.0.0.0          # 想让 tailnet 连进来就必须是 0.0.0.0（默认只绑 lan 接口列表）
  tiers:
    lan:
      enabled: true
      bonjour: true      # 广播 _dsh._tcp，手机零配置发现
    tailscale:
      enabled: true      # 自动检测；检测不到自动跳过，不报错
    zerotier:
      enabled: true
    frp:
      enabled: false
      mode: managed      # managed（插件拉起 frpc）| byo（只填公网 URL）
      serverAddr: ""
      serverPort: 7000
      remotePort: 18788
      token: ""
      tls: false         # true = 公网侧必须 https
      publicUrl: ""      # byo 模式填 https://dsh.example.com
    iroh:
      enabled: true
      relay: n0          # n0 | custom
      customRelay: ""    # 自建 iroh-relay 的 URL
```

界面映射：每档一个开关；虚拟组网那两个默认打开并标注「已自动检测到 100.101.2.3」；
自建中转是折叠表单；iroh 单独一组（关掉就只剩内网/自建）。

---

## 5. 网络环境自动检测

### 5.1 接口分类

`os.networkInterfaces()` 逐条 IPv4，按下表归类；表外一律丢弃（回环、`169.254/16`、
`fe80::/10`、`utun` 上的 IPv6）。

| 判据 | 归类 | 说明 |
|---|---|---|
| 接口名 `zt*` / `feth*` | **zerotier** | ZeroTier 的虚拟网卡命名，**优先于网段判断** |
| `100.64.0.0/10` 且接口 `utun*` | **tailscale** 候选 | CGNAT 段，Tailscale 默认网段 |
| `10/8`、`172.16/12`、`192.168/16` | **lan** 候选 | 私有网段 |
| 其它公网地址 | wan | 仅记录，不默认启用 |

**接口名优先于网段**：ZeroTier 允许自定义网段（可以是 10/8），只看网段会把 ZT 误判成 LAN，
进而把一个"只有装了 ZeroTier 的手机才可达"的地址当成局域网地址广播出去。

### 5.2 命令探测（一条实测教训）

**只 `existsSync` 会误判。** 本机实测：`/usr/local/bin/tailscale` 存在，但它是个
`exec /Applications/Tailscale.app/Contents/MacOS/Tailscale` 的 shim，而那个 App 已经不在了 ——
直接执行报 `cannot execute: No such file or directory`。所以探测一律**执行命令并解析输出**：

- **Tailscale**：按 `tailscale`（PATH）→ `/Applications/Tailscale.app/Contents/MacOS/Tailscale`
  → `/usr/local/bin/tailscale` → `/opt/homebrew/bin/tailscale` 顺序试 `status --json`。
  - 成功 → 取 `Self.TailscaleIPs` 里第一个 IPv4、`BackendState`、`Self.Online`。
  - `BackendState !== "Running"` → 档位不可用，UI 提示「Tailscale 已安装但未登录 / 未连接」。
  - 全部失败 → 档位隐藏（不是报错）。
- **ZeroTier**：同样多路径找 `zerotier-cli`，跑 `-j listnetworks`，取 `status === "OK"` 的
  `assignedAddresses` 里的 IPv4。
- 单次探测超时 800 ms，结果缓存 30 s；`enabled` 但探测失败的档位在 UI 上显示灰条 + 原因。

### 5.3 网络指纹

用来判断「换网了没有」，决定要不要清空粘滞与缓存：

```
fingerprint = sha256( sorted(本机所有私有 IPv4) + "|" + wifiSsid? + "|" + 默认路由接口名 )
```

macOS 取 SSID 用 `networksetup -getairportnetwork <dev>`（失败就只用地址）。
指纹变化 → 清空 lastGood、立刻重新探测、重置降级粘滞。

---

## 6. 清单（descriptor）与下发

清单是**手机侧唯一的输入**：

```json
{
  "v": 1,
  "hostId": "69c0863d…",
  "name": "MacBook Pro",
  "port": 18788,
  "tiers": [
    { "kind": "lan",       "url": "http://10.8.54.221:18788", "prio": 10 },
    { "kind": "tailscale", "url": "http://100.101.2.3:18788", "prio": 20 },
    { "kind": "frp",       "url": "https://dsh.example.com",  "prio": 40,
      "tls": { "sha256": "AB:CD:…" } },
    { "kind": "iroh",      "endpointId": "69c0863d…", "relay": "https://…", "prio": 50 }
  ],
  "issuedAt": 1761000000,
  "ttl": 300
}
```

下发三条路，按可用性取第一条：

1. **控制面（首选）** —— iroh 隧道里打一条 `GET /uplink/descriptor`，宿主现算现回。
   这条通道本身加密且已配对，是唯一可信的通道 —— 所以清单里可以安全携带 **TLS 证书指纹**。
2. **Bonjour 引导** —— 广播 `_dsh._tcp` 的 TXT 只放 `id` / `port` / `v`，**不放地址、不放密钥**；
   手机拿到后打 `GET /uplink/hello` 取一份不含地址的公开信息（确认是哪台电脑），
   再用配对密钥做一次挑战-应答换清单。
3. **二维码 / 手动** —— 电脑侧设置页显示二维码（内容 = 清单 JSON 的 base64url）。
   iroh 整档关掉时这是唯一的引导方式。

清单带 `ttl`，手机侧缓存并在过期后重取；取不到就继续用旧的（离线可用），但标「可能已过期」。

---

## 7. 鉴权：长期密钥不上明文网络

- **配对一次**（走 iroh 或二维码）：生成 `deviceId` + 32 字节 `secret`。
  电脑存 `uplink-devices.json`（0600），手机存 Keychain。
- **每次连接换票**：

  ```
  POST /uplink/auth
  { "deviceId": "…", "ts": 1761000000, "nonce": "…",
    "proof": HMAC-SHA256(secret, "auth|deviceId|ts|nonce") }

  → 200 { "ticket": "…", "ttl": 900 }
  ```

  `ticket = HMAC-SHA256(serverKey, "ticket|deviceId|ts|exp")`，服务端**无状态可验**。
  `ts` 偏差 > 120 s 拒绝（防重放），`nonce` 30 s 内去重。
- 之后所有 HTTP / WS 请求带 `Authorization: Bearer <ticket>`；到期前 60 s 自动续。
- **撤销设备** = 删记录 + 提升 `serverKey` 版本 → 所有在途 ticket 立即失效。
- **限流**：同 IP 10 次/分钟认证失败 → 封 5 分钟。
- **公网档强制 TLS**；LAN / Tailnet 可选自签 TLS（指纹随清单下发，见 §6）。

> 为什么不直接放一个长期 Bearer：局域网是明文，长期令牌一旦被旁路嗅探就是永久授权。
> 换票后泄露窗口只有 15 分钟，且绑 deviceId 可单独撤销。

---

## 8. 网关实现要点

- **只转发到** `127.0.0.1:<dshPort>`，**不做通用正向代理**（不能被当跳板）。
- `Host` 头改写为 dsh 的 authority；注入 `x-forwarded-for` 与 `x-dsh-device`（设备名，
  让 dsh 日志与审批界面能显示"这条请求来自哪台手机"）。
- **cookie**：沿用 `ctx.inject(['connection'])` → `connection.authenticatedUrl()` 兑换，
  取出 `Set-Cookie` 后**逐请求注入**；每 12 h 续期；兑换失败重试 3 次后返回明确的 502
  文案（「电脑端认证失败，重启 dsh」），**不要静默 401** —— 今天 401 白屏的坑就在这。
- **WebSocket**：处理 `upgrade` 事件，双向 pipe；注意 backpressure（`drain`）与 half-close；
  **不设空闲超时**（实测宿主自己也不关空闲 WS）。
- **请求体流式转发**，不缓冲（附件上传）。
- **免票路由**只有两条：`GET /uplink/hello`（仅公开信息）、`GET /uplink/ping`
  （`{ok, hostId, v}`，供探测）。
- **日志**：每条连接记 `档位 / 设备名 / 首字节时间 / 字节数 / 结束原因`；
  档位切换与降级各记一行 —— 这两行是后续所有排障的抓手。

---

## 9. 自建中转三选一

| 方式 | 电脑侧 | 手机侧 | 结论 |
|---|---|---|---|
| **frp** | 托管 `frpc`（插件生成 toml 并 spawn）或 BYO | 无（直连公网端口） | **先做这个**：最通用，且手机零依赖 |
| **iroh-relay** | 跑 `iroh-relay`，host 侧 `RelayMode.custom` | **零改动** | 优雅，但需要一台公网机 + 证书 |
| **supernode (n2n)** | `edge` | ❌ 无官方客户端 | **不做一等公民**，见下 |

**iroh-relay 为什么手机零改动**：iroh 每个端点启动时向自己的 home relay 注册，而 peer 的
relay URL 是**随地址一起下发**的 —— 我们的 `TetherDiscovery` 已经从 TXT 记录解析 `relay=`
并塞进 `EndpointAddr`。所以宿主换 relay，手机自然跟着换，**一行 Swift 都不用改**。
前提：自建 relay 公网可达 + TLS（内网调试可用 dev 模式）。

**supernode 为什么降级**：n2n 的 edge 客户端在 iOS 上没有官方实现，只有第三方
（[happynios](https://github.com/happynclient/happynios)、商业版 HappyN），装不装、能不能用
都不由我们控制；[社区长期结论](https://blog.margrop.net/post/what-is-n2n/)也是 iOS 未跟上。
想自建虚拟组网，推荐 **Tailscale（iOS 官方 App）** 或 **WireGuard（iOS 官方 App）** ——
两者都能被 §5 的检测覆盖（WireGuard 走 `utun*` + 用户手填网段）。

---

## 10. 手机侧改动

`DSHHostProvider`（`baseURL` / `requestHeaders` / `webSocketURL` / `isReady`）是唯一接缝，
**协议层与界面一行都不用改**（ADR-0004 的收益）。

| 模块 | 改动 |
|---|---|
| `AppSettings` | `gatewayURL` / `gatewayToken` → `UplinkConfig`（启用档位、优先级、自建中转、lastGood、设备密钥引用）；旧键做一次性迁移 |
| `UplinkDirectory`（新） | `NWBrowser(_dsh._tcp)` + 清单拉取 / 缓存（secret 进 Keychain，清单进磁盘 + ttl） |
| `UplinkProbe`（新） | **并行**探测所有启用档位：`GET /uplink/ping`，400~800 ms 超时，**先成功者胜** |
| `HostCoordinator` | `mode` 增加 `.uplink(tier:url:)`；`baseURL()` 返回当前档位；`requestHeaders()` 返回 ticket |
| `AppModel.connect()` | 连接链改为 `并行探测 → 选中档位 → 失败逐个降级 → iroh 兜底`；状态机加 `connecting(tier:)` |
| 设置页 | 新增「连接方式」：勾选 + 优先级 + 自建中转表单 + 每档「测试」按钮 |
| 诊断页 | 当前档位、各档 RTT、最近切换原因、降级历史 |
| `Resources/Info.plist` | 补 `NSBonjourServices = ["_dsh._tcp"]`（`NSLocalNetworkUsageDescription` 已有，见 60 行） |

**粘滞**：某档成功后在 5 分钟内优先它；一次降级后 5 分钟内不再回头试上一档（否则每次连接
都要先等一次超时）。换网（§5.3 指纹变化）立刻失效。

### 10.1 两个必须知道的平台约束

**(a) ATS 不挡 IP 字面量。** `http://10.8.54.221:18788` 这种明文请求在 iOS 10+ **总是放行**
（Apple 工程师在 [论坛明确说明](https://developer.apple.com/forums/thread/66417)：
"It has no effect on IP address loads. On iOS 10 and later such loads are always allowed"）。
所以 LAN / Tailnet 档**不需要**给 Info.plist 加 ATS 例外，直接 `http://<ip>:<port>` 即可。

**(b) 但自签 TLS 走 URLSession 会被 ATS 拦。** ATS 对证书链做强制校验，没有"允许不受信证书"
的 plist 键。要上自签 TLS，正确做法是**复用 ADR-0004 那一层**：用 `Network` 框架
（`NWConnection` + `.tls`，手工校验证书指纹）建一条到宿主的连接，再在 `127.0.0.1` 上开一个
明文本地端口给 `URLSession` —— 和 TetherKit 的 `LocalProxyServer` 完全同构。
ATS 不适用于 `Network` 框架，所以这条路绕开整个问题。**M2 再做，M0/M1 用明文。**

---

## 11. 失败与降级矩阵

| 现象 | 处理 |
|---|---|
| LAN 端口不通（换网 / 防火墙 / AP 隔离） | 800 ms 超时 → 降级；同指纹下 5 分钟不再试 |
| Tailscale 装了没登录 | 检测阶段就排除，UI 灰条 +「去登录」提示 |
| frp 服务端挂了 | 该档标 unhealthy，10 分钟后重试；不阻塞其它档 |
| cookie 兑换失败 | 502 + 明确文案，不静默 401 |
| 全部档位失败 | 回落 iroh；iroh 也关了就显示「无可达路径」+ 引导二维码 |
| 明文网络上 ticket 被截 | ticket 900 s + 绑 deviceId，泄露窗口有限；可开自签 TLS 消除 |

---

## 12. 验收指标

| 指标 | 今天 | 目标 |
|---|---|---|
| 同 Wi-Fi 冷启动打开 309 事件会话 | 20.4 s（中位，n=5） | **< 300 ms** |
| 30 分钟内 mux 断开次数 | 中位 23 s 一次 | **0** |
| 档位探测总耗时 | — | p95 **< 600 ms**（并行竞速） |
| 降级后重复试错 | — | 5 分钟内 0 次 |

---

## 13. 安全边界

- 网关只转发到回环上的 dsh，**不是通用代理**。
- 默认绑 `0.0.0.0`，但**只对已配对设备放行**；未配对一律 401，`/uplink/hello` 只回公开信息。
- Bonjour 广播**不含地址与密钥**（`_dsh._tcp` 只说明"这里有个 DSH"）。
- 公网档强制 TLS；LAN 可选自签 + 指纹固定。
- 撤销设备立即生效（ticket 带 deviceId + serverKey 版本）。
- 与今天本地代理的已知边界一致（[TRANSPORT.md](TRANSPORT.md) §8 第 5 条）：同网段其它设备能连到端口，
  靠令牌兜住。

---

## 14. 分阶段

| 阶段 | 内容 | 估时 | 可独立验收 |
|---|---|---|---|
| **M0** | 网关 + 鉴权 + 清单 + 单档 LAN（Bonjour）+ 诊断接口 | 1.5 d | 手机走 LAN 打开会话 < 300 ms |
| **M1** | TS/ZT 自动检测 + 并行竞速 + 粘滞 + 降级 | 1.5 d | 4G 下自动走 Tailscale |
| **M2** | frp 托管 + iroh-relay 配置 + 自签 TLS（本地 TLS 代理） | 1.5 d | 无虚拟组网时走自建中转 < 3 s |
| **M3** | 手机 UI（勾选 / 优先级 / 表单 / 诊断）+ 二维码兜底 | 1.5 d | 全程零手填地址 |
| **M4** | 迁移、文档、指标回收 | 1 d | 30 分钟无断开 |

M0 结束就能拿到 §12 前两行指标 —— 也就是说**最高频场景的收益在第一阶段就到手**。

---

## 15. 与现有 tether 的关系

**依赖它的二进制，不依赖它的插件。** `dsh-tether-host-*` 是独立 npm 包，新插件 `spawn` 它、
沿用它的 `host --proxy-target` 参数与 stdin/stdout JSON-lines 控制流，只多要一件事：
把 `pairing` / `devices` 消息接进自己的配对流程。

- 好处：iroh 档位零 Rust 工作量，上游升级我们只跟很小的控制流。
- 代价：多一个 npm 依赖；它不在时 `iroh` 档位自动隐藏，其余档位照常工作。
- **共存**：两个插件可以同时装（tether 走 iroh，uplink 走 LAN/TS/frp），但端口与配对会重复。
  建议 M0 起就关掉 tether 的传输、由 uplink 统一管理 —— 翻案理由见
  [DECISIONS.md](DECISIONS.md) ADR-0029。

---

## 16. 待定（需要你拍板）

1. **插件名**：`dsh-plugin-uplink`（中文「多路接入」）可以吗？
2. **iroh 档位要不要留**：留 = 出门在外永远有兜底；不留 = 少一个 npm 依赖与一个 Rust 进程。
3. **自建中转先做哪个**：frp（最通用、手机零依赖）还是 iroh-relay（手机零改动但需公网机）？
4. **多主机**：一个手机连多台电脑，还是先只支持一台？（影响清单结构）
5. **端口**：固定 `18788` 还是每次随机？（随机更安全，但 Bonjour 必须可靠）
