import DSHKit
import Foundation
import Network
import TetherKit
import XCTest

@testable import DSHPocket

/// 多路接入的**传输层**测试：本地回环代理、NWConnection 探测、首行策略自愈。
///
/// 这一组测的是"真连"的东西（回环上的假服务器、`NWConnection`、ATS 的真实行为），
/// 不是纯逻辑 —— 因为上一轮的教训正是"纯逻辑全绿、真机上一条都连不上"。
final class UplinkTransportTests: XCTestCase {
    // MARK: 工具：回环上的假网关

    /// 一个只监听回环的假 TCP 服务器：收到请求后回一段固定字节，然后关连接。
    ///
    /// 用 `NWListener` 而不是 Python/`nc`：测试必须自带依赖，CI 上没有那些东西。
    final class FakeServer: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "test.uplink.fake-server")
        private let handler: @Sendable (String) -> Data
        private let lock = NSLock()
        private var connections: [NWConnection] = []
        private var requests: [String] = []

        init(handler: @escaping @Sendable (String) -> Data) throws {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredInterfaceType = .loopback
            self.listener = try NWListener(using: parameters)
            self.handler = handler
        }

        func start() async throws -> UInt16 {
            let gate = Gate()
            return try await withCheckedThrowingContinuation { continuation in
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        gate.once { continuation.resume(returning: self.listener.port?.rawValue ?? 0) }
                    case .failed(let error):
                        gate.once { continuation.resume(throwing: error) }
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.start(queue: queue)
            }
        }

        func stop() {
            listener.newConnectionHandler = nil
            listener.stateUpdateHandler = nil
            listener.cancel()
            lock.lock()
            let active = connections
            connections = []
            lock.unlock()
            for connection in active { connection.cancel() }
        }

        var received: [String] {
            lock.lock(); defer { lock.unlock() }
            return requests
        }

        private func accept(_ connection: NWConnection) {
            lock.lock()
            connections.append(connection)
            lock.unlock()
            connection.start(queue: queue)
            receive(connection, buffer: Data())
        }

        private func receive(_ connection: NWConnection, buffer: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                data, _, isComplete, error in
                var accumulated = buffer
                if let data { accumulated.append(data) }
                let text = String(decoding: accumulated, as: UTF8.self)
                if text.contains("\r\n\r\n") {
                    self.lock.lock()
                    self.requests.append(text)
                    self.lock.unlock()
                    connection.send(content: self.handler(text), completion: .contentProcessed { _ in
                        connection.send(
                            content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() }
                        )
                    })
                    return
                }
                if error != nil || isComplete { connection.cancel(); return }
                self.receive(connection, buffer: accumulated)
            }
        }
    }

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false
        func once(_ body: () -> Void) {
            lock.lock()
            if used { lock.unlock(); return }
            used = true
            lock.unlock()
            body()
        }
    }

    private static func httpResponse(body: String) -> Data {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        return Data((head + body).utf8)
    }

    // MARK: ① 本地回环代理

    /// 起在回环、能双向转发。
    ///
    /// 这条测的是**整条替代路径**：ATS 只放行本地地址，所以 uplink 的请求全部先到
    /// `127.0.0.1:<port>` 再由代理原样转给远端。这里用回环上的假网关当"远端"。
    @MainActor
    func testLocalProxyBindsLoopbackAndForwardsBothWays() async throws {
        let server = try FakeServer { _ in Self.httpResponse(body: #"{"ok":true,"hostId":"abc"}"#) }
        let port = try await server.start()
        defer { server.stop() }

        let proxy = UplinkLocalProxy()
        let base = try await proxy.start(target: .init(host: "127.0.0.1", port: port))
        defer { Task { await proxy.stop() } }

        XCTAssertEqual(base.scheme, "http")
        XCTAssertEqual(base.host, "127.0.0.1", "必须绑回环：ATS 只对这一类地址永远放行")
        XCTAssertNotNil(base.port)

        var request = URLRequest(url: base.appendingPathComponent("uplink/ping"))
        request.timeoutInterval = 3
        let (data, response) = try await URLSession.shared.data(for: request)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"ok":true,"hostId":"abc"}"#)
        // 请求确实被转出去了（不只是代理自己回了个 200）。
        XCTAssertTrue(server.received.contains { $0.contains("GET /uplink/ping") })
    }

    /// 换档时**端口不变**、目标变了（端口稳定，URLSession 的连接复用才不会失效）。
    @MainActor
    func testLocalProxyKeepsPortWhenTargetChanges() async throws {
        let first = try FakeServer { _ in Self.httpResponse(body: "one") }
        let second = try FakeServer { _ in Self.httpResponse(body: "two") }
        let firstPort = try await first.start()
        let secondPort = try await second.start()
        defer { first.stop(); second.stop() }

        let proxy = UplinkLocalProxy()
        let url1 = try await proxy.start(target: .init(host: "127.0.0.1", port: firstPort))
        let url2 = try await proxy.start(target: .init(host: "127.0.0.1", port: secondPort))
        defer { Task { await proxy.stop() } }

        XCTAssertEqual(url1.port, url2.port, "换目标不该换端口")

        var request = URLRequest(url: url2)
        request.timeoutInterval = 3
        let (data, _) = try await URLSession.shared.data(for: request)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "two")
    }

    /// `stop()` 幂等，且停掉之后不再接新连接。
    @MainActor
    func testLocalProxyStopIsIdempotent() async throws {
        let server = try FakeServer { _ in Self.httpResponse(body: "x") }
        let port = try await server.start()
        defer { server.stop() }

        let proxy = UplinkLocalProxy()
        _ = try await proxy.start(target: .init(host: "127.0.0.1", port: port))
        await proxy.stop()
        await proxy.stop()
        let url = await proxy.currentBaseURL()
        XCTAssertNil(url)
    }

    // MARK: ② 探测走 NWConnection

    /// 探通：回环上的假网关回 `{ok,hostId}` → `.reachable`。
    @MainActor
    func testTCPProbeReachesFakeGateway() async throws {
        let server = try FakeServer { _ in
            Self.httpResponse(body: #"{"ok":true,"hostId":"host-1","v":"0.3.0"}"#)
        }
        let port = try await server.start()
        defer { server.stop() }

        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))
        let tier = UplinkTier(kind: .lan, url: url)
        let result = await UplinkTCPProbe.ping(tier: tier, expectedHostId: "host-1", timeout: 2)

        XCTAssertNotNil(result.rtt, "应当探通，实际：\(result)")
        XCTAssertTrue(server.received.contains { $0.contains("GET /uplink/ping") },
                      "探测就是一个最小的 HTTP/1.1 请求")
        XCTAssertTrue(server.received.contains { $0.contains("Host: 127.0.0.1:\(port)") })
    }

    /// hostId 不符 = 连到了**另一台**电脑 → `.hostMismatch`，不能当成"通了"。
    @MainActor
    func testTCPProbeDetectsHostMismatch() async throws {
        let server = try FakeServer { _ in
            Self.httpResponse(body: #"{"ok":true,"hostId":"someone-else"}"#)
        }
        let port = try await server.start()
        defer { server.stop() }

        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))
        let tier = UplinkTier(kind: .lan, url: url)
        let result = await UplinkTCPProbe.ping(tier: tier, expectedHostId: "host-1", timeout: 2)

        XCTAssertEqual(result.failure?.category, .mismatch, "实际：\(result)")
    }

    /// 端口没人监听 → `.refused`（而不是笼统的"失败"）。
    @MainActor
    func testTCPProbeReportsRefused() async throws {
        // 先占一个端口再放掉，拿到一个"几乎肯定没人监听"的端口号。
        let server = try FakeServer { _ in Self.httpResponse(body: "x") }
        let port = try await server.start()
        server.stop()

        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))
        let tier = UplinkTier(kind: .lan, url: url)
        let result = await UplinkTCPProbe.ping(tier: tier, expectedHostId: "host-1", timeout: 2)
        XCTAssertEqual(result.failure?.category, .refused, "实际：\(result)")
    }

    /// HTTP 解析本身（不需要网络）。
    func testProbeResponseParsing() {
        let ok = Self.httpResponse(body: #"{"ok":true,"hostId":"host-1"}"#)
        let parsed = UplinkTCPProbe.parseIfComplete(ok, expectedHostId: "host-1") { 7 }
        XCTAssertEqual(parsed, .reachable(rttMilliseconds: 7))

        let mismatch = UplinkTCPProbe.parseIfComplete(ok, expectedHostId: "other") { 7 }
        XCTAssertEqual(mismatch?.failure?.category, .mismatch)

        let bad = Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n".utf8)
        if case .unreachable(.other(_, let reason))? = UplinkTCPProbe.parseIfComplete(bad, expectedHostId: "x", elapsed: { 3 }) {
            XCTAssertEqual(reason, "http-502")
        } else {
            XCTFail("502 应当归到 other(http-502)")
        }

        XCTAssertNil(UplinkTCPProbe.parseIfComplete(Data("HTTP/1.1 200 OK\r\n".utf8), expectedHostId: "x") { 1 },
                     "头都没收完就继续等")
    }

    // MARK: ATS（这条是**实测**，不是"理论上"）

    /// 证明"URLSession 直连非本地地址会被 ATS 拦"这件事真的会发生。
    ///
    /// 真机日志：`探测失败 tailscale http://100.64.16.30:18788：error(-1022)(2ms)`
    /// —— 2ms 说明它**没发出去**，是 ATS 在本地拒的。
    ///
    /// 这条测试的价值在于：如果哪天有人把探测改回 `URLSession`，或者给 Info.plist
    /// 加了 `NSAllowsArbitraryLoads`，这里会立刻响 —— 前者是本轮修的 bug，
    /// 后者是 ADR / TRANSPORT §6 明令禁止的。
    func testATSBlocksPlainHTTPToNonLocalAddress() async throws {
        let url = try XCTUnwrap(URL(string: "http://100.64.16.30:18788/uplink/ping"))
        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        do {
            _ = try await URLSession.shared.data(for: request)
            XCTFail("ATS 应当拦下发往 CGNAT 地址的明文 http（NSAllowsLocalNetworking 不放行 100.64/10）")
        } catch let error as URLError {
            XCTAssertEqual(error.code.rawValue, -1022,
                           "期望 ATS 的 -1022，实际 \\(error.code.rawValue)（\\(error.localizedDescription)）")
            XCTAssertEqual(UplinkProbeFailure(urlError: error, milliseconds: 2).category, .ats,
                           "-1022 要归到 .ats，日志里才看得出是 ATS 而不是网络不通")
        }
    }

    /// 反过来：**回环**永远是放行的（这就是本地代理能工作的前提）。
    func testATSAllowsLoopback() async throws {
        let server = try FakeServer { _ in Self.httpResponse(body: "loopback-ok") }
        let port = try await server.start()
        defer { server.stop() }

        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/uplink/ping"))
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "loopback-ok")
    }
}

/// 首行策略自愈（`close(1, "protocol")`）。
///
/// 这些用例不需要 iroh：决策本身是纯函数，而真机复现要两台设备。
final class TetherFirstMessageRecoveryTests: XCTestCase {
    private static func protocolError() -> TetherError {
        // 真机日志里的原文形状。
        .transport(#"ConnectionLost(ApplicationClosed(error_code: 1, reason: "protocol"))"#)
    }

    func testRecognisesProtocolClose() {
        XCTAssertTrue(TetherFirstMessageRecovery.isProtocolMismatch(Self.protocolError()))
        XCTAssertFalse(TetherFirstMessageRecovery.isProtocolMismatch(TetherError.transport("连接超时")))
        XCTAssertFalse(TetherFirstMessageRecovery.isProtocolMismatch(TetherError.notPaired))
    }

    /// 手机以为"没配对"（发 pair），电脑端其实认识我们 → 翻成 hello 重试。
    func testPairFlipsToHelloAndSucceeds() async throws {
        var attempts: [TetherFirstMessage] = []
        let result = try await TetherFirstMessageRecovery.run(first: .pair(code: "123456"), pairingCode: "123456") { message in
            attempts.append(message)
            if message == .pair(code: "123456") { throw Self.protocolError() }
            return "ok"
        }
        XCTAssertEqual(result.value, "ok")
        XCTAssertEqual(result.used, .hello)
        XCTAssertEqual(attempts.count, 2, "只重试一次")
    }

    /// 反过来：手机以为"已配对"（发 hello），电脑端不认识我们 → 有码就翻成 pair。
    func testHelloFlipsToPairWhenCodeAvailable() async throws {
        var attempts: [TetherFirstMessage] = []
        let result = try await TetherFirstMessageRecovery.run(first: .hello, pairingCode: "741231") { message in
            attempts.append(message)
            if message == .hello { throw Self.protocolError() }
            return "ok"
        }
        XCTAssertEqual(result.used, .pair(code: "741231"))
        XCTAssertEqual(attempts.count, 2)
    }

    /// 没有码可翻 → 报 `notPaired`，让上层去要码（而不是抛一句 iroh 的协议错误）。
    func testHelloWithoutCodeReportsNotPaired() async throws {
        var attempts = 0
        do {
            _ = try await TetherFirstMessageRecovery.run(first: .hello, pairingCode: nil) { _ in
                attempts += 1
                throw Self.protocolError()
            }
            XCTFail("没有码就不该能自愈")
        } catch let error as TetherError {
            XCTAssertEqual(error.policy, .stop)
            if case .notPaired = error {} else { XCTFail("应当是 notPaired，实际 \\(error)") }
        }
        XCTAssertEqual(attempts, 1, "没码时不要拿同一个首行再撞一次")
    }

    /// 取反之后还是协议错误 → 停手（只重试一次，不能来回翻）。
    func testRetriesExactlyOnce() async throws {
        var attempts: [TetherFirstMessage] = []
        do {
            _ = try await TetherFirstMessageRecovery.run(first: .pair(code: "1"), pairingCode: "1") { message in
                attempts.append(message)
                throw Self.protocolError()
            }
            XCTFail("两次都协议错误就该抛出来")
        } catch {
            XCTAssertTrue(TetherFirstMessageRecovery.isProtocolMismatch(error))
        }
        XCTAssertEqual(attempts.count, 2, "pair → hello，两次；不能再翻回 pair")
    }

    /// 网络类失败**不**触发自愈：换首行也连不上，别多花 15 秒。
    func testNetworkFailureIsNotRetried() async throws {
        var attempts = 0
        do {
            _ = try await TetherFirstMessageRecovery.run(first: .pair(code: "1"), pairingCode: "1") { _ in
                attempts += 1
                throw TetherError.transport("连接超时")
            }
            XCTFail("应当把原错误抛出来")
        } catch {
            XCTAssertEqual(attempts, 1)
        }
    }

    /// 日志里不能出现配对码。
    func testLabelsNeverLeakTheCode() {
        XCTAssertEqual(TetherFirstMessageRecovery.label(.pair(code: "123456")), "pair")
        XCTAssertEqual(TetherFirstMessageRecovery.label(.hello), "hello")
    }
}
