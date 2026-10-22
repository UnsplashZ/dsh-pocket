import Foundation
import TetherKit

/// 端到端验证 iroh 档位：连上 sidecar → 通过它派生的本地代理打 `/uplink/ping`。
///
/// 它不依赖 App、不依赖手机，也不依赖局域网 —— 只要有 `endpointId#code` 就能跑。
/// 这正是 iroh 作为"兜底档"的意义：**任何网络**下都能连回来。

let arguments = Array(CommandLine.arguments.dropFirst())
let flags = Set(arguments.filter { $0.hasPrefix("--") })
let positional = arguments.filter { !$0.hasPrefix("--") }
guard let raw = positional.first else {
    FileHandle.standardError.write(Data("用法: uplink-e2e [--reset] <endpointId>#<code>\n".utf8))
    exit(2)
}
let parts = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
let endpointId = String(parts[0])
let code = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil

func log(_ message: String) {
    FileHandle.standardError.write(Data("[e2e] \(message)\n".utf8))
}

/// TetherKit 只要求一个 `log(_:)`，没有内置的闭包适配器 —— 这里就地实现一个。
struct StderrSink: TetherLogSink {
    func log(_ message: String) { TetherLog(message) }
}

func TetherLog(_ message: String) {
    FileHandle.standardError.write(Data("[tether] \(message)\n".utf8))
}

/// 身份与主机簿**用同一套默认位置**（`~/Library/Application Support/DSHPocket/`）。
///
/// 这里踩过一次：早先每次跑都开一个 UUID 临时目录放身份，而 TetherKit 的主机簿是
/// 全局的 —— 第二次跑时主机簿说"已配对"于是发 `hello`，而电脑端白名单里只有上一轮
/// 那个旧身份，被判成协议错误 `close(1, "protocol")`。
/// **身份与主机簿必须一起持久化**，否则两边认知永远对不上。
if flags.contains("--reset") {
    try? FileManager.default.removeItem(at: TetherStorage.directory())
}
let store = FileSecretStore()

let session = TetherSession(store: store, deviceName: "uplink-e2e", logger: StderrSink())

do {
    log("本机身份 \(try await session.localEndpointId().prefix(12))…")
    log("连 \(endpointId.prefix(12))…（配对码 \(code == nil ? "无" : "有")）")
    let started = Date()
    let base = try await session.connect(hostId: endpointId, pairingCode: code)
    log("连上了，本地代理 \(base.absoluteString)，用时 \(Int(Date().timeIntervalSince(started) * 1000))ms")

    // iroh 档位直连的是 **dsh 本身**（sidecar 的 --proxy-target），不经过 uplink 网关 ——
    // 所以这里验的是 dsh 首页，而不是网关的 /uplink/ping（那在 iroh 下必然 404）。
    // 两条通路最终都落在同一个 dsh 上，只是 URL 空间不同：
    //   uplink 档：手机 → 网关(鉴权+注入 cookie) → dsh
    //   iroh  档：手机 → iroh → sidecar(注入 cookie) → dsh
    var page = URLRequest(url: base)
    page.timeoutInterval = 20
    let (pageData, pageResponse) = try await URLSession.shared.data(for: page)
    let pageStatus = (pageResponse as? HTTPURLResponse)?.statusCode ?? -1
    let html = String(data: pageData, encoding: .utf8) ?? ""
    log("GET / → HTTP \(pageStatus)，\(pageData.count) 字节，是 dsh 页面: \(html.contains("<html"))")

    // 顺带确认"uplink 网关的路由在 iroh 下不存在"，这不是错误而是设计
    var ping = URLRequest(url: base.appendingPathComponent("uplink/ping"))
    ping.timeoutInterval = 10
    let pingStatus = (try? await URLSession.shared.data(for: ping))
        .flatMap { ($0.1 as? HTTPURLResponse)?.statusCode } ?? -1
    log("GET /uplink/ping → HTTP \(pingStatus)（iroh 不走网关，404 属预期）")

    await session.disconnect()
    print(pageStatus == 200 && pageData.count > 1000 ? "PASS" : "FAIL")
    exit(pageStatus == 200 && pageData.count > 1000 ? 0 : 1)
} catch {
    log("FAIL：\(error)")
    exit(1)
}
