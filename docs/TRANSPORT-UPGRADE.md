# 传输方案升级：LAN → 虚拟组网 → 自建中转 → tether 兜底

> 调研日期：2026-10-22。依据：10-19 至今的真机日志（`scripts/pull-logs.sh`，4569 行）、
> 本机直连宿主的对照实验、`dsh-plugin-tether` 与 `iroh-ffi` 的实际 API 面。
> 结论先行：**"连不上/看不到消息/老断开"里绝大部分是网络，不是 App 逻辑。**

## 1. 网络到底占多大比重

全日志统计（10-19 至今）：

| 指标 | 数量 |
|---|---|
| mux 断开 | 60 |
| 会话流断开 | 42 |
| 前台重连 | 68 |
| `rpc ✗` | 25 |
| 传输断开（tether 层） | 20 |

快照大小 → 等待时间（同一台电脑、同一个会话）：

| 快照 | 大小 | 等待 |
|---|---|---|
| 3 条事件 | ~90 KB | 890 ms |
| 58 条事件 | ~210 KB | 940 ms |
| **309 条事件** | **866 KB** | **20448 ms（中位数，n=5）** |

对照实验（同一份 866 KB 快照，一条 WS 消息）：

| 路径 | 耗时 | 连接 |
|---|---|---|
| Mac 直连宿主 `127.0.0.1:63978` | **12 ms** | 稳挂 90 s 不断 |
| 手机 → iroh 中继 → 电脑 | **14~22 s** | 传完即被掐（5/5） |

→ 中继吞吐约 **42 KB/s**，比直连慢 **~1700 倍**。而"传完即断"又触发重连重下，
形成 20 秒一轮的死循环（0.4.26 已用小窗口把循环掐断）。

**归因结论**：

- **网络导致的**：所有"连接中/正在重连/看不到消息/会话加载十几秒"——即日志里那 60+42+68+25+20 条。
- **App 逻辑导致的**（已单独修）：跳到最新常驻、菜单项错位、文件点不开、图片不能缩放、
  取消被记成失败、会话流永久卡在 reconnecting。这些与网络无关。

所以：**升级传输是本轮最值得做的事**，收益远大于继续在 App 层做兜底。

## 2. 现状链路（谁在做什么）

```
手机 DSH Pocket                    iroh（公网）                    Mac
┌───────────────┐                ┌──────────┐              ┌──────────────────────┐
│ DSHClient     │  http/ws       │ 中继 aps1 │  QUIC/UDP    │ tether-host（sidecar）│
│  ↓            │ ─────────────► │ (新加坡)  │ ◄──────────► │  ↓ 逐请求注入 cookie  │
│ 127.0.0.1:23072│                └──────────┘              │ 127.0.0.1:63978 (DSH) │
│ 本地 TCP 代理  │                                            └──────────────────────┘
└───────────────┘
```

- **TetherKit（App 内）**：`TetherLink`（iroh 连接 + 控制流）+ `LocalProxyServer`
  （回环 TCP → 代理流），上层完全用系统 `URLSession` 打 `http://127.0.0.1:<派生端口>`。
- **dsh-plugin-tether（DSH 插件，Node）**：拉起 `tether-host` sidecar，
  用进程 token 换浏览器 cookie（`GET /?token=`），再通过 `proxy-auth` 把 cookie
  交给 sidecar **逐请求注入**；配对/设备撤销走它注册的 `/dsh-tether/*` 路由。
- **地址来源**：只有 n0 DNS 发现（`_iroh.<z32>.dns.iroh.link TXT`），且记录里
  **只有 relay、没有直连地址**；`presetN0()` 不含 mDNS，所以**同一 Wi-Fi 下也不走局域网**。
- **已有但没启用的路**：App 里已经有 `TransportMode.directGateway`（填地址 + Bearer token），
  电脑侧有 `tools/direct-gateway.mjs`（注入 cookie 的 HTTP/WS 代理）—— 但后者是手工跑的
  开发脚本，前者没有 UI 入口、也没有发现机制。

## 3. 根因链（为什么慢、为什么断）

1. iroh 只拿到 relay 地址（无直连地址）→ 全部流量绕新加坡中继；
2. 中继吞吐 42 KB/s，且**一次 866 KB 的单条 WS 消息传完就会把连接掐掉**；
3. 掐断后三条流立刻重订阅 → 重新下 866 KB → 再被掐（死循环，0.4.26 已缓解）；
4. 会话页/首页的"卡住"体验，都是这条链的下游。

不是 iroh 的问题，是**路径**的问题：直连宿主 12 ms，说明协议栈本身没问题。

## 4. 候选方案对比

| 方案 | 吞吐/延迟 | 手机侧成本 | 电脑侧成本 | 适用 | 主要风险 |
|---|---|---|---|---|---|
| **A. 局域网直连** | ~Wi-Fi 上限（几十 MB/s，<5 ms） | Bonjour 发现 + 地址记忆 | 起一个带 token 的网关（插件内） | 同 Wi-Fi 办公/家里（最高频场景） | 需「本地网络」权限；不同网段/AP 隔离会失败 |
| **B. Tailscale** | 直连时接近 LAN；打洞失败走 DERP（境外，可能慢） | 装 Tailscale App（用户自己） | 装 Tailscale（用户自己） | 跨网络（公司↔家、4G） | 依赖第三方；国内 DERP 不稳；需登录账号 |
| **C. ZeroTier** | 同 B（自建 moon 可改善） | 装 ZeroTier One | 装 ZeroTier | 同 B，且可自建 planet/moon | 同 B；国内中转节点质量参差 |
| **D. 自建中转** | 取决于 VPS 带宽（国内 VPS 常见 5~30 Mbps，比 42 KB/s 快 10~70 倍） | 填一个 URL + token | 部署 frp/rathole 或自建 iroh-relay | 出门在外、没有虚拟组网 | 要维护一台服务器；公网暴露需 TLS |
| **E. iroh + 自建 relay** | 同 D，但保留现有代码与打洞能力 | 配置 `RelayMode.custom`（FFI 已支持） | 跑 `iroh-relay` | 想保留 iroh 语义、只换中转 | relay 需公网 + TLS 证书；仍需 UDP 可达 |
| **F. 现状 tether（n0 中继）** | 42 KB/s，会掐 | 无 | 无 | 兜底 | 就是当前问题 |

关键判断：

- **A 是收益/成本比最高的**：它不引入任何第三方，只在插件里加一个监听 + 发现，
  就能把最常见的"在家/在公司"场景从 42 KB/s 提到 Wi-Fi 上限。
- **B/C 不需要我们写协议**：对 App 来说它们只是"另一个能路由到的 TCP 地址"，
  复用 A 的同一条 `directGateway` 通路即可，工作量主要在**发现与选择**。
- **D/E 是"出门在外"的解**：D 最省事（任何 TCP 隧道都行，App 零改动）；
  E 更优雅（保留 iroh 的打洞/加密语义），但需要一台有公网 IP 的机器 + 证书。

## 5. 推荐架构

```
连接时按优先级尝试（每档有超时，失败就降级）：

  ① LAN 直连      http://192.168.x.x:<gwPort>      发现：Bonjour `_dsh._tcp`
  ② 虚拟组网      http://100.x.y.z:<gwPort>        发现：宿主下发 / 手动填
  ③ 自建中转      https://relay.example.com        （frp/rathole 或 iroh-relay）
  ④ tether/iroh   现状（n0 中继）                   永远保留
```

三条设计原则：

1. **对上层透明**：所有档位最终都表现为"一个能打 HTTP/WS 的 baseURL + 鉴权头"，
   `DSHClient`/`MuxClient`/`SessionModel` 一行都不用改（今天 `.directGateway` 就是这个形状）。
2. **凭据复用现有配对**：不引入第二套配对。配对成功后，App 通过**已有的隧道**打一条
   `GET /dsh-tether/gateway`（插件注册的路由，和 `/pairing`、`/devices` 同一套），
   拿回 `{ token, port, urls[] }` 存进 Keychain，之后所有档位都用同一个 token。
   这样**不需要改 Rust sidecar 的线协议** —— 插件在 Node 侧就能把这件事做完。
3. **地址由宿主下发**：宿主最清楚自己的局域网 IP / Tailscale IP / 公网域名，
   让它算好、通过控制流发给手机并缓存 —— 手机不需要猜。

## 6. 分阶段实施计划

### P0 · 先把"是不是网络"变成可观测（0.5 天）

- 诊断页显示：当前走的是哪一档、baseURL、最近 5 分钟的吞吐（KB/s）与 RTT。
- 日志：每次连接记录 `传输档位=LAN/Tailscale/Relay/Tether`。
- 验收：用户报"卡"时，看一眼诊断页就能定位是不是走了中继。

### P1 · LAN 直连（收益最大，3~4 天）

电脑侧（`dsh-plugin-tether`，Node，全部在插件里，不动 Rust sidecar）：

- 起一个网关监听 `0.0.0.0:<gwPort>`：HTTP + WS 升级透传，逐请求注入已有的 cookie，
  校验 `Authorization: Bearer <perDeviceToken>`（token 在配对时签发、可撤销）。
- Bonjour 广播 `_dsh._tcp`（TXT：`id`/`port`/`ver`），供手机零配置发现。
- 配对成功时通过控制流下发 `{ token, port, urls }`。

手机侧：

- `Info.plist` 补 `NSBonjourServices`（`_dsh._tcp`）；已有 `NSLocalNetworkUsageDescription`。
- `.directGateway` 今天是**开发者模式**（设置页只有一条"开发者模式"横幅 + 恢复默认），
  P1 要把它提升成一等公民：新增"连接方式"区块，显示自动选中的档位与地址，可手动锁定。
- `NWBrowser` 发现 + 地址缓存（上次成功的优先）；`TransportMode.lan` 走现有
  `directGateway` 通路（Bearer token）。
- 连接链：LAN 尝试 2 s → 失败降级 tether。

验收（硬指标）：

- 同一 Wi-Fi 下打开 309 条事件的会话：**< 300 ms**（今天 20 s）。
- 连续 30 分钟无 mux 断开（今天中位数 23 s 一次）。

### P2 · Tailscale / ZeroTier（1~2 天）

- 不写协议：把"宿主在虚拟组网里的地址"当成第 ② 档 baseURL 即可。
- 发现：宿主枚举自己的接口（`100.64/10` = Tailscale，`10.x/172.x` 可能是 ZeroTier），
  随 `urls[]` 一起下发；App 按"上次成功 > LAN > 虚拟组网"顺序试。
- 文档：给出两端装 Tailscale/ZeroTier 的三步说明（我们不做账号体系）。

验收：关掉 Wi-Fi 只留 4G（Tailscale 打洞成功时）打开会话 < 2 s。

### P3 · 自建中转（1 天，可选）

- 最省事：文档 + 一个 `scripts/relay-example/`（rathole 或 frp 配置），
  把网关端口用 TLS 暴露到公网，App 里填 `https://...` + token（`.directGateway` 已支持）。
- 更优雅（可选）：`RelayMode.custom(map:)` + `insertRelay` 指向自建 `iroh-relay`，
  保留打洞能力；FFI 已支持，不需要改 Rust。
- 验收：4G + 无虚拟组网时，866 KB 快照 < 3 s（国内 VPS 5 Mbps 即可）。

### P4 · 兜底与切换策略（1 天）

- 传输选择器：自动（按优先级）/ 手动锁定某一档（排障用）。
- 降级要**粘住**：一次降级后 5 分钟内不再反复试上一档（避免每次连接都等 2 s 超时）。
- 诊断页把每次切换的原因记下来。

### 不做（避免过度设计）

- 不做自研 P2P 打洞/自有加密协议（iroh 已经做了，且直连时是 12 ms）。
- 不做账号/多用户体系（单机单用户场景）。
- 不在 App 里内嵌 Tailscale SDK（用户装官方 App 更稳，也避免审核与包体问题）。

## 7. 安全边界

- 网关**默认只监听局域网**；要暴露公网必须显式开启 + 强制 TLS + 独立 token。
- token 按设备签发（复用现有配对白名单），可单独撤销；轮换不要求重新配对。
- 网关只转发到 `127.0.0.1:<DSH 端口>`，不做通用正向代理（防止被当成跳板）。
- 局域网内其它 App 仍可能连到网关端口 —— 与今天本地代理的已知边界一致（TRANSPORT §8.5），
  用 token 兜住。

## 8. 一句话结论

**是网络。** 而且不需要发明新协议：App 里已经有 `directGateway`（TCP + Bearer token）这条完整的路，
电脑侧的插件也已经握有 cookie 与端口 —— 缺的只是"在插件里起一个带 token 的网关 + 让手机能发现它"。
先做 P1（LAN），就能把最高频场景从 42 KB/s 提到 Wi-Fi 上限；P2/P3 覆盖"出门在外"。
