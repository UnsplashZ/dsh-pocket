# M0b 验证记录：Swift 客户端 ↔ 现有 tether sidecar 互通

> 结论：**通过**。这是整个方案里唯一能推翻设计的风险（DECISIONS ADR-0002），
> 现在用真实代码、真实 sidecar、真实 DSH 跑通了。
>
> 复现命令在文末。下面是 2026-10-12 本机原始输出（去掉时间戳与无关的系统日志）。

---

## 验证的是什么

不是"某个 API 能编译"，而是**一条完整链路**，中途没有任何桩：

```
TetherKit（Swift，iroh-ffi 1.1.0）
  → QUIC / ALPN dsh-tether/0 / preset N0
    → 电脑侧 tether-host（iroh 1.0.3）
      → DLP 配对（6 位码）
        → DLP 代理流（首行 {"type":"proxy"} + 原始字节）
          → 手机侧本地 TCP 代理 127.0.0.1:29582（端口由主机 ID 派生）
            → DSHKit（URLSession）
              → POST /api/session/list          ✅ 真实数据
              → WS /api/remote.mux → $events    ✅ 世代就绪
              → session/follow                  ✅ 快照 263 条事件
```

其中**每一个箭头**都是本项目的代码或电脑端原样的插件二进制。

---

## 原始输出

```
DSH Pocket · M0b 传输互通验证

[1] 准备设备身份（Keychain / 文件）
    ·  [tether] 设备身份 6c5ba341e523…
    ✅ 本机端点 ID 6c5ba341e5231359fea32aeb01efd910430c6e694ca2831c8e6be8c3f80f3475

[2] 连接电脑并 Pair（首次配对路径）
    ·  主机 832eaab05b415f641c42fb687f90ef9413a41bc20cfd1ff150d8095814cc56e3
    ·  ALPN dsh-tether/0 · preset N0 · 本地代理端口 29582
    ·  [tether] 连接电脑 832eaab05b41…（preset N0，ALPN dsh-tether/0）
    ·  [tether] 配对成功
    ·  [tether] 控制流就绪；远端 832eaab05b41
    ·  [tether] 本地代理已就绪 127.0.0.1:29582
    ·  [tether] 已连接并起好本地代理：http://127.0.0.1:29582
    ✅ 连接成功，耗时 1115ms
    ✅ 本地代理基址 http://127.0.0.1:29582

[3] iroh 路径诊断
    ✅ 路径：direct（NAT 打洞成功）
    ·  远端地址 10.8.54.221:49466
    ·  RTT 0ms
    ·  绑定套接字 0.0.0.0:65280, [::]:62877
    ·  本地代理端口 29582

[4] 经代理流打真实 DSH：session/list
    ✅ GET /api/session/list 成功，耗时 45ms
    ✅ 拿到 59 个会话
    ·  session-50f323ca-f04…  空闲  seq=1094  构建仓库数据查询分析模式
    ·  session-d7b56d6f-2fb…  运行中  seq=892  阅读该会话：session-8983df4d-910a-
    ·  session-5443fdff-628…  空闲  seq=1244  有没有iPhone客户端 可以远程控 (1)

[5] 经代理流开 WebSocket：$events 世代
    ·  [dsh] mux 已连接 ws://127.0.0.1:29582/api/remote.mux
    ✅ $events 就绪 clientId=0196678a-8f3… home=/Users/example

[6] 经代理流订阅会话流：session/follow
    ✅ 快照 263 条事件，cursor=1094，折叠出 118 个条目

[7] 结论
    ✅ iroh-ffi(Swift, 1.1.0) ↔ 宿主 iroh 1.0.3 互通
    ✅ DLP 配对与代理流可用，DSH 的 RPC + mux + 会话流全部经这条链路跑通

M0b 通过。 真机路径与之一致（同一份 TetherKit/DSHKit 代码）。
```

## 顺带验证到的两条路径

| 场景 | 结果 |
|---|---|
| 首次配对（`{"type":"pair"}`） | 1115ms，`pair-ok` |
| 已配对重连（`{"type":"hello"}`） | 849ms，无需配对码 |
| 打洞成功 | `direct`，RTT 0–1ms，远端是局域网地址 |
| 回退中转 | `relay`，RTT 761ms，远端是 `*.relay.n0.iroh.link`（只看到密文） |
| 配对窗口已关 | `pair-fail {reason:"no-window"}` → 客户端渲染成"电脑上没有开着的配对窗口…" |

最后一条是意外收获：为了抓干净证据重开了一次配对窗口，第一次跑正好撞上
"窗口已被上一次成功配对消耗掉"，于是把 `pair-fail` 的原因码分支也实测过了 ——
**线上只传码、客户端本地化**这条设计（TRANSPORT §2）在真实链路上成立。

---

## 复现

```bash
# 1) 电脑侧：不用开 DSH 桌面端，用 dev 工具起 sidecar（它会扮演插件把 cookie 交给 sidecar）
node tools/tether-host-dev.mjs --data-dir /tmp/tether --pair
#    输出里有 endpoint_id 与 6 位配对码

# 2) 客户端：跑同一个 Swift 包
cd ios/spikes/M0BInterop
swift run m0b-interop \
  --endpoint <上一步的 endpoint_id> \
  --code <6 位配对码> \
  --data-dir /tmp/m0b-client

# 再跑一次（省略 --code）验证已配对重连
swift run m0b-interop --endpoint <endpoint_id> --data-dir /tmp/m0b-client
```

## 验证过程中抓到的一个真 bug

第一次跑通之后，为了抓干净证据重启了 sidecar，再跑就报：

```
ConnectionLost(ApplicationClosed(ApplicationClose { error_code: 1, reason: b"protocol" }))
```

电脑端 `reason: b"protocol"` 的含义是"已配对连接的首行不是 Hello"（`host/src/main.rs`
的 `_ =>` 分支）。可我们发的就是 Hello。真正的原因是**设备身份没有持久化**：

```swift
try value.write(to: temporary, options: [.atomic, .completeFileProtectionUnlessOpen])
```

`.completeFileProtection*` 是 **iOS 的**数据保护类。在 macOS 上带着它写出来的文件
**写不报错、但读不回来**（`Data(contentsOf:)` 直接返回 nil）。于是每次运行
`TetherIdentity.loadOrCreate` 都读不到旧身份、生成一把新密钥 —— 对电脑端来说
这就是一台从未配对过的新设备，Hello 自然被拒。

修法是分平台给写选项（`TetherFileWrite.options`）。这个 bug 在**真机上不会出现**
（iOS 上数据保护类是正常工作的），所以它只会在 `swift test` 与命令行 spike 上炸 ——
而那两个正是我们用来验证真机路径的东西。`TetherContractTests` 里的
`testFileSecretStoreRoundTripAndPermissions` 现在会把它钉住。

修完之后重跑：第一次配对成功，第二次**沿用同一把身份**走 Hello，不再需要配对码。

## 这次验证改变了什么

1. **ADR-0002 的回退方案不需要了**：iroh-ffi 1.1.0 ↔ iroh 1.0.3 直接互通，
   不需要自建 xcframework、也不需要 UniFFI 桥。
2. **电脑端确实一行没改**：跑的就是 `dsh-plugin-tether@0.1.20` 自带的
   `tether-host` 二进制（`tools/tether-host-dev.mjs` 只是替插件把
   `proxy-auth` 这条 stdin 消息发过去）。
3. **真机路径与之一致**：iOS 上用的是同一份 `TetherKit` / `DSHKit` 代码，
   差别只有 `TetherSecretStore`（Keychain vs 文件）。
