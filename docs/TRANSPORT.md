# 传输层：iroh + DLP 线协议 + Swift 客户端实现配方

> 目标：**Swift 客户端与当前已安装的 `dsh-plugin-tether` sidecar 直接互通，电脑端零改动。**
> 契约真源：[`dsh-tether/tether-core/src/lib.rs`](https://github.com/zexadev/dsh-tether/blob/main/tether-core/src/lib.rs)（`Wire` 枚举）与 `host/src/main.rs`。
> iroh 版本：电脑端 `iroh 1.0.3`（`presets::N0`）；客户端用官方 Swift 包 **IrohLib**（iroh-ffi v1.1.0，预编译 xcframework，无需 Rust 工具链）。

---

## 1. iroh 层

| 项 | 值 |
|---|---|
| ALPN | `dsh-tether/0`（常量，电脑端硬编码） |
| preset | **N0**（电脑端 `Endpoint::builder(presets::N0)` ↔ Swift `presetN0()`）→ 公共发现 + 默认中转 |
| 端点 ID | 64 位十六进制（`secret.public().description`） |
| 身份密钥 | 客户端的 iroh `SecretKey` 就是**设备身份**：配对后电脑端按这把公钥做白名单。必须持久化（Keychain），否则每次启动都变新设备、需重新配对 |

### 1.1 绑定与连接（已核对过的 Swift API）

```swift
import IrohLib

// 1) 身份：首次生成并存入 Keychain，之后复用
let secret: SecretKey
if let bytes = Keychain.read("iroh.secretKey"), let s = try? SecretKey.fromBytes(bytes: bytes) {
    secret = s
} else {
    secret = SecretKey.generate()
    Keychain.write("iroh.secretKey", secret.toBytes())
}
let endpointId = secret.public().description          // 64 hex，配对串的前半段

// 2) 绑定端点（ALPN 必须与电脑端一致）
let ep = try await Endpoint.bind(options: EndpointOptions(
    preset: presetN0(),
    secretKey: secret.toBytes(),
    alpns: [Data(Tether.alpn.utf8)]                   // "dsh-tether/0"
))

// 3) 连接主机
let peer = try EndpointId.fromString(s: hostEndpointIdHex)
let addr = EndpointAddr(id: peer, relayUrl: nil, addresses: [])
let conn = try await ep.connect(addr: addr, alpn: Data(Tether.alpn.utf8))
let id   = conn.remoteId().description                // 用于本地簿去重
```

> 命名以 IrohLib 的 DocC 为准（<https://n0-computer.github.io/iroh-ffi/swift/documentation/irohlib/>）。以上名字取自官方示例 [hello-iroh-ffi](https://github.com/n0-computer/hello-iroh-ffi)。

### 1.2 Xcode 工程必须做的三件事

1. **链接 Network.framework**：target → Build Settings → Other Linker Flags，给 `iphoneos` / `iphonesimulator` 各加 `-framework Network`。不加会报 `Undefined symbols: _nw_interface_get_index`。
2. **关掉 Xcode Previews**（Xcode 16 与 SwiftPM 同图时的已知问题）：Enable Previews = No（Debug/Release）。否则报 `product being built is not an allowed client of SwiftUICore`。
3. **Info.plist 两条**（与 tether 一致，见 §6）。

### 1.3 【必须先验证】互通性

电脑端是 iroh **1.0.3**，客户端是 iroh-ffi **1.1.0**。两者同属 iroh 1.x，线协议应互通，但**这是 M0b 的第一件事**：写一个 20 行的 Swift 程序，连上现有 sidecar，完成 Hello，并成功开一条代理流取到 `GET /` 的响应头。**在这之前不要写任何界面。**

---

## 2. 配对

- 电脑端在 DSH 侧栏底部「连接手机」生成配对串：`<endpointId>#<6 位数字>`。
- 窗口有效期 **10 分钟**、**3 次**尝试；过期/超次/错码各有原因码。
- 客户端行为：`conn.openBi()` → 首行写 `{"type":"pair","code":"<6位>","name":"<设备名>"}` → 读一行应答：
  - `{"type":"pair-ok"}` → 记入本地主机簿（`id` = endpointId，`label` = 用户起的名字）；
  - `{"type":"pair-fail","reason":"no-window|expired|too-many-attempts|bad-code"}` → 按**本地化文案**渲染原因（线上只传码，电脑端 0.1.16 及更早会直接发中文句子，认不出的原样显示）。**不要**把原因码直接显示给用户。
- 电脑端对**未配对连接的首行**限长 **512 字节**（防止未授权方喂大负载）—— 所以 pair 消息要短：`name` 不要塞长文本。

---

## 3. DLP 线协议（控制流）

一条连接**第一条 bi 流**是控制流：JSON-lines（每行一条 JSON，`\n` 结尾），单行上限 **64 KiB**（`MAX_LINE`）。

| 方向 | 消息 | 说明 |
|---|---|---|
| 手机 → 电脑（首行，二选一） | `{"type":"hello","name":"…"}` | 已配对后每次连接的首行 |
| | `{"type":"pair","code":"123456","name":"…"}` | 首次配对 |
| 电脑 → 手机 | `{"type":"pair-ok"}` / `{"type":"pair-fail","reason":"…"}` | 配对应答 |
| 电脑 → 手机 | `{"type":"approval","id":"…","toolName":"…","reason":"…"}` | agent 等审批 |
| 电脑 → 手机 | `{"type":"approval-cancel","id":"…"}` | 审批已失效，撤掉卡片 |
| 手机 → 电脑 | `{"type":"decision","id":"…","outcome":"…"}` | 对上述审批的决定 |

> **注意**：这里的 `approval/*` 是 tether 自己的"审批遥控"通道（电脑端插件观察 DSH 的审批后转发）。它与 DSH 原生协议里的 `$events` waterfall `approval/request`（见 [PROTOCOL-NOTES.md](PROTOCOL-NOTES.md) §4.3）是**两条不同的路**。
> 本方案的做法：**审批决策走 DSH 原生通道**（`$events/result`），因为原生通道能给出完整上下文且不依赖插件；tether 的 `approval` 消息**只用来触发本地通知**（它已经替我们把"有一条审批在等你"推过来了，省一次轮询）。两条路都收，但**只答一条**（原生），避免重复决策。

---

## 4. 代理流与本地 TCP 代理

### 4.1 线协议

控制流建立之后，**同一连接的后续每条 bi 流都是代理流**：

```
手机 → 电脑：首行 {"type":"proxy"}
之后：该流上双向流动的就是原始 TCP 字节（电脑端把它接到 127.0.0.1:19387）
```

电脑端在这一层做两件事（我们无需实现，只需知道）：
1. 把请求头里的 `Host` 改写成已授权的 authority；
2. **注入浏览器会话 cookie**（它自己在电脑侧兑换好的，因为手机的跨站上下文发不出 `SameSite=Strict` 的 cookie）。

**因此客户端完全不需要处理 token/cookie/认证** —— 这是复用电脑端方案最大的红利。

### 4.2 为什么保留"本地 TCP 代理"这一层

我们本可以在 iroh 流上自己实现 HTTP/WS。**选择不做**，理由是：

| 保留本地代理 | 自实现 HTTP/WS over iroh |
|---|---|
| 直接用 `URLSession` / `URLSessionWebSocketTask`（原生、成熟、自动重试与连接复用） | 要自己写 HTTP/1.1 解析、chunked、WS 握手与帧 |
| ATS 例外只需覆盖 `127.0.0.1` | 无 ATS 问题，但要自己处理一切 |
| 与电脑端现有实现完全一致，行为可对照 | 多一套实现，多一类 bug |
| 调试时可以用 curl/浏览器直接打这个端口 | 不行 |

代价是进程内多一个 loopback 监听。**可接受。**

### 4.3 端口派生（要与电脑端公式一致）

电脑端 Rust：

```rust
fn proxy_port_for(peer: &EndpointId) -> u16 {
    let b = peer.as_bytes();
    20000 + u16::from_be_bytes([b[0], b[1]]) % 12000      // 20000..31999
}
```

Swift 等价：

```swift
func proxyPort(for peerHex: String) -> UInt16 {
    let b = [UInt8](hexToBytes(peerHex))                  // 32 字节
    return 20000 + (UInt16(b[0]) << 8 | UInt16(b[1])) % 12000
}
```

要点：

- 端口**按主机派生且稳定**（不同主机不同端口）。tether 这么做是为了让 DSH 网页的 `localStorage` 源保持稳定；对我们仍有价值：URLSession 的连接复用/凭据上下文一致、调试可复现、多主机互不串。
- 端口被占用时**回退 OS 分配**（电脑端如此）；但注意 authority 会随之变化 —— 因为 cookie 由电脑端按 `Host` 头注入并绑定 authority，回退端口也能工作（电脑端用的是它自己授权过的 authority）。**客户端不要缓存 authority**。

  ⚠️ **实现这个回退时踩到的坑**（真机上表现为
  `本地代理启动失败：Network.NWError 错误 48 - Address already in use`）：
  `NWListener(using:on:)` 在端口冲突时**不会同步抛错** —— 绑定失败是异步地通过
  `stateUpdateHandler` 的 `.failed` 送来的。只 `catch` 同步抛错等于没处理，
  而且监听对象还留着继续占端口，下一次重连必然再撞一次。正确做法是：
  把 `.failed` 也当成"这个端口不可用"，**先 `cancel()` 收掉再回退**，
  并用一把锁保证 continuation 只被 resume 一次（`.ready` 与 `.failed` 都可能到达）。

  还有一个实测事实：`NWListener.cancel()` 是**异步**的，端口不会立刻释放 ——
  重启监听时很容易撞上自己刚放掉的那个端口。所以"能起来"才是要求，
  "拿到同一个端口"不是（再次印证：**不要缓存 authority**）。
- 范围 20000–31999 避开了 iOS 临时端口区（49152 起）。

### 4.4 代理循环（骨架）

```swift
let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
listener.newConnectionHandler = { tcp in
    tcp.start(queue: .global())
    Task {
        let bi = try await conn.openBi()
        let send = bi.send()
        try await send.writeAll(buf: Data(#"{"type":"proxy"}"#.utf8) + Data([0x0A]))
        // 两个方向各自拷贝：
        //   TCP → send.writeAll(...)
        //   bi.recv() → tcp.send(content:)
        // 任一侧关闭即关闭整条流
    }
}
listener.start(queue: .global())
```

> **待验证（M0b）**：`IrohLib` 的读取原语。官方示例用的是 `recv.readExact(size:)`；而 DLP 控制流是 **JSON-lines**，需要"读到 `\n`"的语义。
> 处理办法：优先找 `read(size:)`/流式 API；若只有 `readExact`，则对**控制流**退化为逐字节读到 `\n`（控制流消息量极小，代价可忽略），**代理流**本来就是原始字节、按块读即可（用 `readExact(size: 64*1024)` + 实际长度处理，或等价的 `read`）。

### 4.5 认证之后

本地代理起来之后，剩下的都是普通 HTTP：

```
GET  http://127.0.0.1:<port>/api/session/list      （POST，见 PROTOCOL-NOTES §4.1）
WS   ws://127.0.0.1:<port>/api/remote.mux          （见 PROTOCOL-NOTES §4.2）
```

`Origin` 头不要发（原生客户端默认不发；发了必须与 Host 相同）。`Host` 由电脑端改写，不用管。

---

## 5. 连接生命周期

```
未配对 ──pair──► 已配对 ──hello──► 控制流就绪 ──► 起本地代理 ──► 协议层连 /api 与 WS
   │                                    │                              │
   └── 失败：原因码渲染                  └── 断开：重连（指数退避+抖动）  └── 世代失效 → 重订阅
```

- 连接断开（`accept_bi`/读循环报错）→ 整个代理随之失效（本地 TCP 上的请求会失败）→ UI 必须立刻切到"已断开"而不是假装在线；
- 退到前台 → 立即重连（iOS 不允许常驻后台，见 [DESIGN.md](DESIGN.md) §9）；
- 重连后必须**重新 `$events`（新 clientId）**并按本地最后 `seq` 续拉 `session/follow`；
- 电脑端同一身份只允许一个连接：第二个连接会把第一个顶掉（日志里是 `4001 superseded`）。**App 内不要并发建立两条连接。**

---

## 6. Info.plist / 权限（照 tether 的实测结论）

```xml
<!-- 只放行回环 + .local + 链路本地；不要用 NSAllowsArbitraryLoads 全关 -->
<key>NSAppTransportSecurity</key>
<dict><key>NSAllowsLocalNetworking</key><true/></dict>

<!-- iOS 14 起，同网段私网 IP 的收发受内核层 Local Network Privacy 管控；
     iroh 用的原始 UDP socket 同样受限。缺这个键系统既不弹窗也不放行，
     表现为 connect timed out 且电脑端完全收不到连接（tether issue #6 的根因方向） -->
<key>NSLocalNetworkUsageDescription</key>
<string>用于发现并直连同一局域网内已配对的电脑，不走公网中转时更快、更省流量。</string>
```

**验收要求**：首次在同一 Wi-Fi 下连接时，系统应弹出"本地网络"询问；若没弹且连接超时，App 内要给出可执行的指引（去 设置 → 隐私与安全性 → 本地网络 检查），并在诊断页显示当前走的路径是 direct 还是 relay。

---

## 6.5 连接方式的选择（含代理 / VPN 场景）

三条路在协议层看来**完全一样**（都只是一个 base URL），区别只在"这个 URL 是怎么来的"。
客户端因此只需要换一个 `DSHHostProvider`：

| | iroh（`dsh-plugin-tether`） | 直连网关（`tools/direct-gateway.mjs`） |
|---|---|---|
| 走什么 | QUIC / UDP，打洞成功直连；失败回退 n0 中转 | 普通 HTTP/WS over TCP |
| 公网可用 | ✅ 不需要开任何端口 | 需要自己解决可达性（Tailscale / 反代） |
| 加密 | iroh 端到端；中转只见密文 | 依赖承载层（WireGuard / TLS） |
| **TUN 类代理（sing-box / Clash）** | ⚠️ 隧道会接管 UDP：打洞多半退化成中转，分流规则禁 UDP 时直接不通 | ✅ TCP，隧道友好 |
| 认证 | 配对码 + 设备公钥白名单 | 共享令牌（`Authorization: Bearer`） |

**实测**：iPhone 在 5G 上、电脑在 Wi-Fi 上，iroh 也能打洞直连成功
（sidecar 日志 `peer-path {"kind":"direct","remote":"114.246.237.30:65180"}`）。
所以 iroh 这条路是通的；但**电脑上常驻 TUN 代理时它会更脆**，这时直连网关更稳。

### 为什么直连网关必须带令牌

它会**代替你**向 DSH 认证（逐请求注入会话 cookie）。也就是说：谁能连上它，
谁就等于拿到了你的 DSH —— 不需要配对码、不需要设备公钥。所以绑非回环地址时
脚本强制要求 `--token`，并在比较时用定长比较避免计时侧信道。

Tailscale / 局域网本身有加密与设备认证，令牌是第二道门；公网场景必须再加 TLS。

## 7. 故障排查对照表

| 现象 | 先看 | 原因 |
|---|---|---|
| 连不上、超时 | 电脑端 sidecar 进程在不在（`ps -eo command \| grep tether-host`） | 插件没运行 / endpoint id 写错 |
| 超时且同 Wi-Fi | 系统「本地网络」权限 | 见 §6 的 issue #6 类问题 |
| 配对报 `no-window` | 电脑端是否刚点过「连接手机」 | 窗口没开 |
| 配对报 `expired` / `too-many-attempts` | —— | 10 分钟过期 / 错 3 次 |
| 连上但 `/api` 401 | 代理是否真的起了、Host 是否被改写 | 代理流没通/端口回退 |
| 日志出现 `4001 superseded` | 是否跑了第二个客户端 | 电脑端同身份只允许一条连接 |
| 连上一会儿就断、之后连不回来 | App 的诊断页看"会话流（mux）" | iroh 控制流断开后**不会自己回来**，必须由 App 的传输监督器重建；手机开着 TUN 代理时尤其容易触发 |
| 打洞总是失败、退化成中转 | 电脑或手机是否开着 TUN 类代理 | 隧道接管了 UDP；改用直连网关（TCP） |
| 代理流开了但请求不通 | 电脑端 DSH 是否还在 `127.0.0.1:19387` | 宿主重启换了端口 |

---

## 8. 安全边界（原样继承 tether 的声明，并在 UI 上如实告知用户）

1. **配对码**：6 位 CSPRNG、10 分钟、3 次尝试；
2. **配对后**访问权由手机的 iroh 公钥决定（TLS 验证，无法伪造）；未配对连接最多只能发 512 字节；
3. **端到端加密**：打洞成功时不经第三方；回退中转时中转只看到密文；
4. **电脑端的已知边界**（tether README 明写）：本机进程能伪造回环 `Host` 通过栅栏，**已经能在你电脑上执行代码的人可以自签配对码把自己配成"手机"**。→ 在电脑端设置页与 App 的说明页如实写清；
5. **手机端的已知边界**：App 的本地代理只监听 `127.0.0.1`，但**手机上其它 App 可以连上它**，且端口由主机 ID 派生（可推算）。→ 一期文档与 App 内说明都要写；后续可加一个进程内的随机握手令牌（需要电脑端配合，列为待办）。
