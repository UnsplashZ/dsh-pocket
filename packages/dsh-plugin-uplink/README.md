# dsh-plugin-uplink · 多路接入

把「手机怎么连上电脑」从**一种协议**变成**一份可勾选的地址清单**：电脑侧起一个带鉴权的网关，
把 dsh 同时暴露在局域网 / 虚拟组网 / 自建中转上；手机侧并行探一下，谁快用谁。

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
- iroh 走 sidecar 的代理流，与本网关无关。

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

3. 重启 dsh。终端应当打印：

   ```
   [uplink] gateway listening on 0.0.0.0:18788
   [uplink]   lan       http://10.8.54.221:18788
   ```

4. 状态、设备与签名密钥在 `$DSH_HOME/uplink/state.json`（0600）。

手机要能连上，还得放行入站：macOS 的防火墙如果开着，第一次监听时系统会弹窗问是否允许
`node` 接受连接 —— 必须允许，否则手机侧表现为"局域网地址一直超时"。

## 配置

```yaml
uplink:
  port: 18788            # 默认 18788；被占用自动顺延（真实端口随清单下发）
  bind: 0.0.0.0
  tiers:
    lan:       { enabled: true }
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
    iroh:      { enabled: true, relay: n0, customRelay: "" }
```

**配置只描述"允许哪些档位"，不描述地址。** 地址永远在运行时算出来 —— 换 Wi-Fi、
Tailscale 重新分配地址、笔记本换网段，配置文件都不用改。

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
| `GET /uplink/state` | 端口、档位、环境探测、设备列表、统计 |
| `POST /uplink/pair` | 开一个配对窗口，返回配对串 |
| `GET/POST /uplink/devices` | 列设备 / 撤销设备 |
| `POST /uplink/rotate` | 轮换签名密钥（踢掉所有在途票据，设备不必重配） |
| `GET /uplink/probe` | 立刻重新探测网络环境 |

## 安全边界

- 只转发到**回环上的 dsh**，不做通用正向代理 —— 不是跳板；
- 未配对请求一律 401；`/uplink/hello` 只回公开信息；
- 公网档必须 TLS；局域网可选自签 TLS（指纹随清单下发）；
- 撤销设备立即生效。

## 现状

| 阶段 | 内容 | 状态 |
|---|---|---|
| M0 | 网关 + 鉴权 + 清单 + 局域网单档 | ✅ 已完成 |
| M1 | TS/ZT 自动检测 + 并行竞速 + 粘滞 + Bonjour 广播 | 🚧 进行中 |
| M2 | frp 托管 + 自签 TLS | ⬜ |
| M3 | 手机 UI + 二维码兜底 | ⬜ |
| M4 | 迁移、文档、指标回收 | ⬜ |
| M5 | 自建 iroh-relay（可选） | ⬜ |

M0 的实测结果（对真 dsh 跑通）：

| 指标 | 结果 |
|---|---|
| 首页 61 KB 经网关 vs 直连 | p50 **2.0 ms vs 1.9 ms**（网关开销 ≈0.1 ms） |
| 正文逐字节一致 | ✅ 61477 bytes 完全相同 |
| WebSocket `api/remote.mux` | ✅ 101 Switching Protocols |
| 未带票访问 | ✅ 401，且请求到不了 dsh |
| cookie 拿不到 | ✅ 502 + 一句人话（不是静默 401） |

尚未做：Bonjour 广播（M1）、iroh 档位接线（M1）、frp 托管（M2）、手机侧 UI（M3）。

## 测试

```bash
node --test        # 50 条：配置归一化 / 网卡归类 / Tailscale·ZeroTier 探测 / 鉴权 / 网关集成
```

网关集成测试是真的起一个假 dsh + 真网关，覆盖：免票路由、未认证拦截、换票、
cookie 注入与 Host 改写、撤销即时生效、大响应透传、WebSocket 升级（带票 / 不带票）、
端口被占用时顺延。

## 已知坑（改代码前先读）

1. **`existsSync` 判 CLI 会误判**。开发机上 `/usr/local/bin/tailscale` 存在，但它是
   `exec /Applications/Tailscale.app/...` 的 shim，而那个 App 已被删除。探测一律
   **执行命令并解析输出**。
2. **接口名优先于网段**。ZeroTier 允许把网段改成 `10/8`，只看网段会把 ZT 误判成局域网，
   进而广播一个"只有装了 ZeroTier 的手机才可达"的地址。
3. **Node 不会为升级过的连接递减 `server._connections`**。`closeAllConnections()` 清不掉
   它们，`server.close()` 的回调永远不来 —— 插件卸载会把宿主卡在退出路上。
   所以网关自己记账 `upgradedSockets`，`close()` 时显式销毁。
