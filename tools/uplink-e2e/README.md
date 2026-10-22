# uplink-e2e —— 在 Mac 上验证 iroh 档位

手机侧一时验不了（没 Wi-Fi / 装不上）时，用它证明 **iroh 这条路本身是通的**：
TetherKit 支持 macOS 14.5，`Iroh.xcframework` 也带 `macos-arm64` 切片，所以同一套客户端
代码能在 Mac 上直接跑，不需要手机。

## 跑法

```bash
# 1) 起一个独立的 sidecar（不依赖正在运行的 dsh 插件），并把 cookie 递过去
node tools/uplink-e2e/host.mjs          # 配对串写到 /tmp/uplink-e2e-pairing.txt

# 2) 用真客户端连上去
cd tools/uplink-e2e
swift build -c release
./.build/release/uplink-e2e --reset "$(cat /tmp/uplink-e2e-pairing.txt)"
```

期望输出：

```
[e2e] 连上了，本地代理 http://127.0.0.1:23112，用时 2093ms
[e2e] GET / → HTTP 200，40709 字节，是 dsh 页面: true
PASS
```

## 它抓到过的真 bug

第一次跑通时 `GET /` 返回 **401（68 字节）**：iroh 能连上、控制流正常、本地代理也起得来，
但每个页面都是 401 —— 因为插件**从来没把浏览器 cookie 交给 sidecar**。
sidecar 的 `proxy-auth` 是 stdin 协议，漏掉这一步它就只能转发裸请求。

这个 bug 在单元测试里看不出来（谁都没跑过真连接），一跑端到端立刻暴露。
修完之后 `GET /` 是 200 + 40709 字节，与直连逐字节一致。

## 两个坑

1. **身份与主机簿必须一起持久化**。早先每次跑都开一个 UUID 临时目录放身份，
   而 TetherKit 的主机簿是全局的 → 第二次跑主机簿说"已配对"于是发 `hello`，
   电脑端白名单里只有上一轮那个旧身份，判成协议错误 `close(1, "protocol")`。
   现在两者都用默认位置（`~/Library/Application Support/DSHPocket/`），`--reset` 一起清。
2. **iroh 的 URL 空间与 uplink 网关不同**：iroh 直连的是 dsh 本身（sidecar 的
   `--proxy-target`），所以 `/uplink/ping` 在 iroh 下必然 404 —— 这不是错误。
   两条路最终都落在同一个 dsh 上：网关档是「手机 → 网关(鉴权+注入) → dsh」，
   iroh 档是「手机 → iroh → sidecar(注入) → dsh」。
