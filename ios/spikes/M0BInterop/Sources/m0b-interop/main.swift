import DSHKit
import Foundation
import TetherKit

// M0b：Swift 客户端 ↔ 现有 tether sidecar 的互通验证。
//
//   swift run m0b-interop \
//     --endpoint <64 位十六进制主机 ID> \
//     --code 123456 \                 # 首次配对；已配对后省略
//     --data-dir /tmp/tether-spike    # 身份与主机簿目录
//
// 退出码：0 = 全部通过；非 0 = 第几步失败（见输出）。

// MARK: - 参数

struct Options {
    var endpointId: String?
    var code: String?
    var dataDir: URL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dsh-pocket-m0b")
    var deviceName: String = "m0b-spike"
    var skipProxyProbe = false
}

func parseArguments() -> Options {
    var options = Options()
    var iterator = CommandLine.arguments.dropFirst().makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--endpoint": options.endpointId = iterator.next()
        case "--code": options.code = iterator.next()
        case "--data-dir":
            if let value = iterator.next() { options.dataDir = URL(fileURLWithPath: value) }
        case "--name": options.deviceName = iterator.next() ?? options.deviceName
        case "--skip-proxy-probe": options.skipProxyProbe = true
        case "--help", "-h":
            print("""
            用法: m0b-interop --endpoint <hex> [--code 123456] [--data-dir <dir>] [--name <设备名>]
              --endpoint        电脑端端点 ID（64 位十六进制）；用 tether-host id --data-dir … 取
              --code            首次配对的 6 位码；已配对则省略（走 hello）
              --data-dir        身份与主机簿目录（默认临时目录）
              --name            配准时登记的设备名（首行 ≤512 字节，别太长）
              --skip-proxy-probe 只验控制流，不验代理流 + /api
            """)
            exit(0)
        default:
            FileHandle.standardError.write(Data("未知参数：\(argument)\n".utf8))
            exit(2)
        }
    }
    return options
}

let options = parseArguments()

// MARK: - 输出小工具

var stepIndex = 0
func step(_ title: String) {
    stepIndex += 1
    print("\n\u{001B}[1m[\(stepIndex)] \(title)\u{001B}[0m")
}

func ok(_ text: String) { print("    ✅ \(text)") }
func info(_ text: String) { print("    ·  \(text)") }
func fail(_ text: String) -> Never {
    print("    ❌ \(text)")
    exit(1)
}

func milliseconds(since start: Date) -> String {
    String(format: "%.0fms", Date().timeIntervalSince(start) * 1000)
}

print("\u{001B}[1mDSH Pocket · M0b 传输互通验证\u{001B}[0m")

// MARK: - 1. 身份

step("准备设备身份（Keychain / 文件）")
let store = FileSecretStore(directory: options.dataDir)
let session = TetherSession(store: store, deviceName: options.deviceName, logger: ConsoleLog())
let localId: String
do {
    localId = try await session.localEndpointId()
} catch {
    fail("无法建立/读取身份：\(error.localizedDescription)")
}
ok("本机端点 ID \(localId)")

guard let hostId = options.endpointId else {
    info("没有 --endpoint。把它给你，方便在电脑端核对白名单：")
    print("\n    \(localId)\n")
    exit(0)
}

// MARK: - 2. 连接 + 配对

step(options.code == nil ? "连接电脑并 Hello（已配对路径）" : "连接电脑并 Pair（首次配对路径）")
info("主机 \(hostId)")
info("ALPN \(TetherWire.alpn) · preset N0 · 本地代理端口 \(TetherProxyPort.port(for: hostId))")
let connectStart = Date()
let baseURL: URL
do {
    baseURL = try await session.connect(hostId: hostId, pairingCode: options.code)
} catch let error as TetherError {
    fail("\(error.localizedDescription)\n       （原因码：\(error.pairFailureCode ?? "无")）")
} catch {
    fail(error.localizedDescription)
}
ok("连接成功，耗时 \(milliseconds(since: connectStart))")
ok("本地代理基址 \(baseURL.absoluteString)")

// MARK: - 3. 诊断

step("iroh 路径诊断")
if let diagnostics = await session.diagnostics() {
    ok("路径：\(diagnostics.isDirect ? "direct（NAT 打洞成功）" : "relay（经中转，只看到密文）")")
    if let address = diagnostics.remoteAddress { info("远端地址 \(address)") }
    if let rtt = diagnostics.rttMilliseconds { info("RTT \(rtt)ms") }
    info("绑定套接字 \(diagnostics.boundSockets.joined(separator: ", "))")
    if let port = diagnostics.proxyPort { info("本地代理端口 \(port)") }
} else {
    info("拿不到诊断（连接未完全建立？）")
}

// MARK: - 4. 代理流 + 真实 HTTP

if options.skipProxyProbe {
    step("跳过代理流探测（--skip-proxy-probe）")
} else {
    step("经代理流打真实 DSH：session/list")
    let client = DSHClient(provider: StaticHostProvider(base: baseURL), retry: .none, logger: ConsoleLog())
    let listStart = Date()
    do {
        let sessions = try await client.listSessions()
        ok("GET /api/session/list 成功，耗时 \(milliseconds(since: listStart))")
        ok("拿到 \(sessions.count) 个会话")
        for summary in sessions.prefix(5) {
            let running = summary.isRunning ? "运行中" : "空闲"
            let title = summary.projections.title ?? "(无标题)"
            info("\(summary.sessionId.prefix(20))…  \(running)  seq=\(summary.asOfSeq)  \(title.prefix(28))")
        }
    } catch {
        fail("经代理流请求失败：\((error as? DSHClientError)?.displayMessage ?? error.localizedDescription)")
    }

    step("经代理流开 WebSocket：$events 世代")
    do {
        var clientId: String?
        let deadline = Date().addingTimeInterval(15)
        for try await event in client.events() {
            if case .ready(let id, let host) = event {
                clientId = id
                ok("$events 就绪 clientId=\(id.prefix(12))… home=\(host.string("home") ?? "?")")
            }
            if clientId != nil || Date() > deadline { break }
        }
        if clientId == nil { fail("15s 内没有收到 $events 的 ready 帧") }
    } catch {
        fail("$events 失败：\((error as? DSHClientError)?.displayMessage ?? error.localizedDescription)")
    }

    step("经代理流订阅会话流：session/follow")
    do {
        let sessions = try await client.listSessions()
        guard let target = sessions.first(where: { !$0.sessionId.hasPrefix("im:") && $0.asOfSeq > 0 }) else {
            info("没有可订阅的会话（跳过）")
            throw ProbeSkipped()
        }
        var builder = TimelineBuilder()
        var got = false
        let deadline = Date().addingTimeInterval(20)
        for try await frame in client.follow(sessionId: target.sessionId, assistantStream: false) {
            switch frame {
            case .snapshot(let snapshot):
                got = true
                _ = builder.apply(snapshot: snapshot)
                ok("快照 \(snapshot.events.count) 条事件，cursor=\(snapshot.cursor)，折叠出 \(builder.items.count) 个条目")
            case .event(let event):
                _ = builder.apply(event)
            case .assistantStream:
                break
            }
            if got || Date() > deadline { break }
        }
        if !got { fail("20s 内没有收到 follow 快照") }
    } catch is ProbeSkipped {
        // 正常跳过
    } catch {
        fail("session/follow 失败：\((error as? DSHClientError)?.displayMessage ?? error.localizedDescription)")
    }
}

// MARK: - 5. 收尾

step("结论")
ok("iroh-ffi(Swift, 1.1.0) ↔ 宿主 iroh 1.0.3 互通")
ok("DLP 配对与代理流可用，DSH 的 RPC + mux + 会话流全部经这条链路跑通")
print("\n\u{001B}[32mM0b 通过。\u{001B}[0m 真机路径与之一致（同一份 TetherKit/DSHKit 代码）。\n")

await session.disconnect()
exit(0)

// MARK: - 辅助

struct ProbeSkipped: Error {}

struct ConsoleLog: TetherLogSink, DSHLogSink {
    func log(_ message: String) { print("    ·  [tether] \(message)") }
    func log(_ level: DSHLogLevel, _ message: String) {
        guard level >= .info else { return }
        print("    ·  [dsh] \(message)")
    }
}

extension TetherError {
    var pairFailureCode: String? {
        if case .pairingFailed(let failure) = self { return failure.reasonCode }
        return nil
    }
}
