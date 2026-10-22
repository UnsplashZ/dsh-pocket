# dsh-plugin-uplink · 多路接入

把「手机怎么连上电脑」从**一种协议**变成**一份可勾选的地址清单**：电脑侧起一个带鉴权的网关，
把 dsh 同时暴露在局域网 / 虚拟组网 / 自建中转 / iroh 上；手机侧并行探一下，谁快用谁。

设计见 [`docs/UPLINK-PLUGIN.md`](../../docs/UPLINK-PLUGIN.md)，决策见
[`docs/DECISIONS.md`](../../docs/DECISIONS.md) ADR-0029。

## 为什么需要它

原来的手机连接只有一条路：iroh，且宿主只发布 relay 地址、`presetN0()` 又不含 mDNS，
于是**同一 Wi-Fi 下也绕新加坡中转**。实测同一份 866 KB 的会话快照：

| 路径 | 耗时 |
|---|---|
| 电脑直连自己 | **12 ms** |
| 手机 → n0 中继 → 电脑 | 14~22 s（中位 20.4 s，n=5） |

中继吞吐约 42 KB/s，慢约 1700 倍，而且传完就被掐、掐断后重订阅又重下 —— 这才是
「连不上 / 看不到消息 / 老断开」的主因。

## 它是怎么省事的

四类通路**不是四套协议**，而是同一个网关的四种到达方式：

```
手机（并行探测，谁先 ping 通就用谁）
  ├─ ① 局域网    http://192.168.x.x:18788 ──┐
  ├─ ② Tailscale http://100.x.y.z:18788   ──┤ 同一个监听 socket
  ├─ ③ ZeroTier  http://10.x.y.z:18788    ──┘
  ├─ ④ frp       https://dsh.example.com  ──► frpc ──► 同一端口（公网映射）
  └─ ⑤ iroh      QUIC/UDP + endpointId    ──► tether-host sidecar

              ┌ uplink 网关  0.0.0.0:18788 ┐
              │ 鉴权 → 注入 cookie → 代理 │
              └───────────┬───────────────┘
                          ▼ 127.0.0.1:<dshPort>  dsh web server（只监听回环）
```

- 局域网 / Tailscale / ZeroTier 是**同一个监听**的不同地址（绑 `0.0.0.0` 就都有了），
  新增一档的成本是「枚举地址 + 写进清单」，不是「再实现一套传输」；
- frp 只是把这个端口从公网映射进来，网关一行不改；
- iroh 走 sidecar 的代理流，与本网关无关 —— 它是**唯一**需要额外进程的一档，可整档关掉。

## 装进 dsh

插件跟 dsh 跑在**同一个进程**里，所以改完必须重启 dsh 才生效。

1. profile 的 `package.json`（macOS 上是 `~/.dsh/profiles/<profile>/package.json`）加两处：

   ```jsonc
   "dependencies": {
     "dsh-plugin-uplink": "link:/绝对路径/dsh-pocket/packages/dsh-plugin-uplink"
   },
   "dsh": { "profile": { "bundles": [ /* … */, "dsh-plugin-uplink" ] } }
   ```

2. 装依赖：`pnpm install`。等价的手工做法是 `ln -s` 到 `node_modules/dsh-plugin-uplink`
   —— `link:` 协议生成的就是一个符号链接，两者没有区别。

3. 重启 dsh。终端应当打印（没有 iroh 二进制时不会有 `iroh` 那一行，这是正常的）：

   ```
   [uplink] gateway listening on 0.0.0.0:18788（http）
   [uplink] iroh 兜底档已就绪：cc8a107833d13213…
   [uplink] Bonjour 广播已启动：MMacBook-Pro-local._dsh._tcp.local → …:18788
   [uplink]   lan       http://10.8.54.221:18788
   [uplink]   iroh      endpoint cc8a107833d13213…
   ```

4. 状态、设备与签名密钥在 `$DSH_HOME/uplink/state.json`（0600）；自签证书在
   `$DSH_HOME/uplink/tls/`；iroh 身份在 `$DSH_HOME/uplink/iroh/`；frpc 配置在
   `$DSH_HOME/uplink/frpc.toml`（含明文 token，0600）。

手机要能连上，还得放行入站：macOS 的防火墙如果开着，第一次监听时系统会弹窗问是否允许
`node` 接受连接 —— 必须允许，否则手机侧表现为"局域网地址一直超时"。

> **这个插件是完全独立构建的：零依赖。** 不声明 `peerDependencies`/`optionalDependencies`，
> 也不去解析别人的 `node_modules`（早期版本会去翻 `dsh-tether-host-*`，那等于隐式依赖另一个
> 插件，已删掉并有回归测试钉住）。
>
> 所以 iroh 档位的 sidecar 二进制只有两个来路：随本包发布的 `bin/<platform>-<arch>/tether-host`，
> 或包内 `target/release|debug/tether-host`（本地 cargo build）。都没有时**只是这一档不可用**，
> 其余档位照常工作。要临时借一个外部 sidecar，用 `tiers.iroh.binaryPath` 显式指 ——
> 那是你的选择，不是插件的依赖。

## 配置

```yaml
uplink:
  port: 18788            # 默认 18788；被占用自动顺延（真实端口随清单下发）
  bind: 0.0.0.0
  tiers:
    lan:
      enabled: true
      bonjour: true      # 广播 _dsh._tcp，手机零配置发现
      tls: false         # 自签 TLS：局域网也加密（手机侧用 Network 框架固定指纹）
    tailscale: { enabled: true }     # 自动检测，检测不到自动跳过
    zerotier:  { enabled: true }
    frp:
      enabled: false
      mode: managed                  # managed（插件拉起 frpc）| byo（只填公网 URL）
      serverAddr: ""
      serverPort: 7000
      remotePort: 18788
      token: ""
      tls: false
      publicUrl: ""                  # byo 模式填 https://dsh.example.com
      frpcPath: ""                   # 可选：显式指定 frpc
    iroh:
      enabled: true
      relay: n0                      # n0 | custom（自建 iroh-relay）
      customRelay: ""
      binaryPath: ""                 # 可选：显式指定 tether-host
      dataDir: ""                    # 默认 $DSH_HOME/uplink/iroh
```

```yaml
  # 自动探测漏掉的地址可以手填（见下面「探测模型」）
  tiers:
    tailscale: { addresses: ["100.101.2.3"] }   # 只收 IPv4 字面量，填一次永久有效
    zerotier:  { addresses: [] }
  extraAddresses: ["https://dsh.example.com"]   # 完整 URL 或 ip[:port]，档位按地址段猜
  singbox:                                      # 可选：只用来回答"ts endpoint 在不在"
    apiUrl: "http://127.0.0.1:19090"
    apiSecret: ""
```

**配置只描述"允许哪些档位"，不描述地址。** 地址永远在运行时算出来 —— 换 Wi-Fi、
Tailscale 重新分配地址、笔记本换网段，配置文件都不用改。

## 探测模型：宿主只负责"别漏"，手机才是权威

宿主**永远无法判断"这个地址手机能不能到"** —— 路由表在手机上。所以探测分两层：

**第一层：宿主枚举候选**（四个来源，各回答不同问题）

| 来源 | 能回答 | 代价 |
|---|---|---|
| 网卡枚举 | 真的绑在接口上的地址（`lan` / `tailscale` / `zerotier` / `tunnel`） | 免费 |
| `tailscale status --json` | 官方客户端的 tailnet IP 与 `BackendState` | 需要官方 App 真的在跑（**执行验证**，不看文件是否存在） |
| sing-box Clash API `/proxies` | **有没有 tailscale endpoint、叫什么 tag** | 免费，不需要 root |
| 手填 `addresses` / `extraAddresses` | 用户知道、但探测原理上看不到的地址 | 一次手工 |

**第二层：手机并行探测**（`GET /uplink/ping`，800ms 上限，先通者胜）。只有这一层能确认可达。

### sing-box 的 Tailscale endpoint 是个特例

sing-box 1.11+ 自带 `tailscale` endpoint（用户态 tsnet），**不把 tailnet IP 绑到任何网卡上**。
于是两条老路同时失效：看网卡找不到 `100.x`，官方 CLI 也可能根本没装（装了的还可能是
一个指向已删除 App 的坏 shim —— 本机就是这样）。

插件能做的、和**不做**的：

- ✅ 通过 Clash API 确认 `type: Tailscale` 的 endpoint 存在（本机实测认出 `ts-ep`），
  并在 `reason: 'ip-not-exposed'` 里如实说明"拿不到 IP"；
- ❌ **不去读 `<state_directory>/tailscaled.state`**。那文件是 root 0600 且**含机器密钥**，
  为了探测去放开权限是本末倒置。

拿到"手机能连的 ts 地址"只有两条正路：

1. **子网路由（推荐，uplink 零配置）** —— 让 Mac 的 endpoint 广播局域网段：
   `advertise_routes: ["10.8.54.0/22"]`（[sing-box 文档](https://core-tutorial.argsment.com/singbox/tailscale)），
   在 Tailscale 后台批准后，手机在 4G 下直接打 `http://10.8.54.221:18788` 就能通 ——
   **局域网档自动覆盖出门场景**，不需要单独的 Tailscale 档。
2. **手填 tailnet IP** —— `tiers.tailscale.addresses: ["100.x.y.z"]`。
   前提是该节点接受入站（sing-box 的 endpoint 是出站语义，通常不监听自己的 tailnet IP，
   所以更常见的是第 1 条）。

`system_interface: true` 会让 sing-box 建一个真实 TUN 并持有 tailnet IP，
那时网卡枚举就能自动发现它 —— 这条不需要任何手工配置。

运行时也可以用 `POST /uplink/tiers` 临时开关某一档（设置页的勾选框走这条）；
但它**不落盘**，重启后回到配置文件的值 —— 配置文件才是唯一事实来源。

## 鉴权：长期密钥不上明文网络

局域网是明文的。如果手机每次带一个长期 Bearer，嗅到一次就是永久授权。所以：

1. **配对一次**：生成 per-device 的 32 字节 `secret`（电脑 0600 文件 / 手机 Keychain）；
2. **每次连接换票**：

   ```
   POST /uplink/auth
   { deviceId, ts, nonce, proof: HMAC-SHA256(secret, "auth|deviceId|ts|nonce") }
   → { ticket, ttl: 900000 }
   ```

3. 之后所有 HTTP / WS 请求带 `Authorization: Bearer <ticket>`。
   票据无状态可验（`HMAC(serverKey, payload)`），泄露窗口只有 15 分钟，且绑 deviceId 可单独撤销。

失败限流：同 IP 10 次/分钟 → 封 5 分钟。

## HTTP 接口

网关端口（手机访问）：

| 路径 | 鉴权 | 说明 |
|---|---|---|
| `GET /uplink/ping` | 免票 | `{ok, hostId, v}`，探测用 |
| `GET /uplink/hello` | 免票 | `{v, hostId, name, version}`，**不含地址与档位** |
| `POST /uplink/auth` | 挑战-应答 | 换票 |
| 其它 | 要票 | 反向代理到 dsh，逐请求注入浏览器 cookie |

dsh 自己的端口（只有本机可达，用于管理）：

| 路径 | 说明 |
|---|---|
| `GET /uplink/state` | 端口、scheme、TLS 指纹、各档真实状态、环境探测、设备列表、统计、warnings |
| `POST /uplink/pair` | 开一个配对窗口：`{pairingString, urls, iroh, irohPairing}` |
| `POST /uplink/tiers` | 运行时开关档位 `{enabled:{lan:false,…}}`，只重启受影响的组件 |
| `GET/POST /uplink/devices` | 列设备 / 撤销设备 |
| `POST /uplink/rotate` | 轮换签名密钥（踢掉所有在途票据，设备不必重配） |
| `GET /uplink/probe` | 立刻重新探测网络环境 |

`/uplink/pair` 同时回两样东西，因为它们的生命周期完全不同：

- `pairingString`（`dshuplink://…`）：**长期**凭据，含 deviceId + secret + 地址清单 + iroh endpointId；
- `irohPairing`：**一次性**配对码（默认 600 秒），手机拿到就要立刻用掉，不能存起来。

## 安全边界

- 只转发到**回环上的 dsh**，不做通用正向代理 —— 不是跳板；
- 未配对请求一律 401；`/uplink/hello` 只回公开信息；
- Bonjour 的 TXT 只有 `id` / `port` / `v`，**不含地址、不含密钥**；
- 公网档必须 TLS；局域网可选自签 TLS（指纹随清单下发）；
- 撤销设备立即生效；`/uplink/rotate` 一次踢掉所有在途票据。

## 各档实测

| 档位 | 状态 | 实测 |
|---|---|---|
| 局域网 | ✅ | 首页 61 KB 经网关 p50 **2.0 ms** vs 直连 1.9 ms，正文逐字节一致 |
| WebSocket | ✅ | `api/remote.mux` 经网关拿到 **101 Switching Protocols** |
| Bonjour | ✅ | `dns-sd` 能发现、解析 SRV/TXT/A；stop 时发 TTL=0 告别包 |
| iroh | ✅ | 真 sidecar 起来，endpoint `cc8a1078…`，`openPairing` 拿到 `endpointId#code`（600 s），stop 后无残留。**注意**：0.3.0 起不再借用外部包，需自带二进制或配 `binaryPath` |
| 自签 TLS | ✅ | openssl 三档降级链（`-addext` → `-extfile` → `-config`），指纹与 `openssl x509 -fingerprint -sha256` 逐字符一致 |
| frp | ⚠️ 仅单测 | 本机没装 frpc，managed 模式只能靠注入 `spawnImpl` 验证"活过 1.5 秒"；`status().note` 里已如实标注**未验证连通性** |
| Tailscale / ZeroTier | ⚠️ 仅单测 | 本机没装（`/usr/local/bin/tailscale` 是个指向已删除 App 的坏 shim），探测逻辑用假命令覆盖 |

## 测试

```bash
node --test        # 119 条
```

| 文件 | 覆盖 |
|---|---|
| `config.test.js` | 配置归一化、非法值回退、优先级顺序、新档位字段 |
| `detect.test.js` | 网卡归类、坏 shim 淘汰、TS/ZT 命令解析、网络指纹 |
| `auth.test.js` | 0600 权限、HMAC 应答、重放、时钟偏差、撤销、票据过期、密钥轮换、限流 |
| `descriptor.test.js` | 清单排序、公开身份不泄露、配对串往返与非法输入 |
| `gateway.test.js` | 免票路由、未认证拦截、换票、cookie 注入与 Host 改写、大响应透传、WS 升级、端口顺延 |
| `publish.test.js` | PTR/SRV/TXT/A/ANY、`_services._dns-sd._udp`、无关查询不应答、stop 后不再应答 |
| `iroh.test.js` | ready/pairing 解析、超时、stop 清理、无二进制 |
| `frp.test.js` / `tls.test.js` | toml 生成、byo/managed 分支、证书指纹与幂等、openssl 不支持时的降级 |
| `plugin.test.js` | 装配与卸载、管理路由信任栅栏、档位开关、state 真实性 |

## 已知限制

1. **mDNS 不做名字冲突探测**（RFC 6762 §9）。同网段有两台同名实例时会出现两个同名条目。
2. **A 记录会带上 docker bridge 之类的虚拟网卡地址**（它们是私有网段）；换网后要 stop/start 才刷新。
3. **只发 IPv4，无 AAAA**。
4. **frp managed 的 `up` 只是"没立刻退出"**，不代表已连通 —— 真连通要等手机打过来。
5. **iroh 的 relay 字段拿不到**：当前 sidecar 的 `ready` 消息不带 relay，所以 `status().relay` 恒为 null。
   手机侧仍能从 iroh DNS TXT 记录里解析出 relay，功能不受影响。
6. **运行时开关不落盘**，重启回到配置文件的值。
7. **`utun*` 上的私有地址不自动广播**：它们可能是 WireGuard（有用）也可能是 Docker（无用），
   自动广播只会让手机白等一次超时。需要就把地址填进 `extraAddresses`。
8. **拿不到 sing-box 的 tailnet IP**：见上面「探测模型」。这是刻意不做的事（那文件含机器密钥）。
9. **iroh 档位不自带二进制**：包体里没有 18 MB 的平台二进制（也不该塞进 git）。
   要么自己 cargo build 到 `target/release/`，要么放进 `bin/<platform>-<arch>/`，
   要么用 `tiers.iroh.binaryPath` 指一个现成的。

## 改代码前先读这三个坑

1. **`existsSync` 判 CLI 会误判**。开发机上 `/usr/local/bin/tailscale` 存在，但它是
   `exec /Applications/Tailscale.app/...` 的 shim，而那个 App 已被删除。探测一律
   **执行命令并解析输出**。
2. **接口名优先于网段**。ZeroTier 允许把网段改成 `10/8`，只看网段会把 ZT 误判成局域网，
   进而广播一个"只有装了 ZeroTier 的手机才可达"的地址。
3. **Node 不会为升级过的连接递减 `server._connections`**。`closeAllConnections()` 清不掉
   它们，`server.close()` 的回调永远不来 —— 插件卸载会把宿主卡在退出路上。
   所以网关自己记账 `upgradedSockets`，`close()` 时显式销毁。
4. **`openssl req` 不认 `-extfile`**（那是 `openssl x509` 的选项），OpenSSL 3.x 与 LibreSSL
   都不认。真正的兜底是 `-config` 临时配置文件 + `-extensions`。
