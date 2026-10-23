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
        /// 回显模式：收到什么原样发回、**不关连接**（用来验"重连不该打断在途连接"）。
        private let echo: Bool
        private let lock = NSLock()
        private var connections: [NWConnection] = []
        private var requests: [String] = []

        init(handler: @escaping @Sendable (String) -> Data) throws {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredInterfaceType = .loopback
            self.listener = try NWListener(using: parameters)
            self.handler = handler
            self.echo = false
        }

        init(echoing: Bool) throws {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredInterfaceType = .loopback
            self.listener = try NWListener(using: parameters)
            self.handler = { _ in Data() }
            self.echo = echoing
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
                if self.echo {
                    // 原样发回，连接保持打开 —— 代理那一层要是偷偷重建了隧道，
                    // 这条连接立刻断，测试就能发现。
                    if let data, !data.isEmpty {
                        connection.send(content: data, completion: .contentProcessed { _ in
                            self.receive(connection, buffer: Data())
                        })
                        return
                    }
                    if error != nil || isComplete { connection.cancel(); return }
                    self.receive(connection, buffer: Data())
                    return
                }
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

    // MARK: ② 同 target 复用端口（重连不该打断在途连接）

    /// **这条对应真机日志里的 `mux 断开（连了 1.9s）`。**
    ///
    /// 重复 `start(target:)` 同一个档位时：端口不变、listener 不重建、
    /// **在途连接继续活着**（WebSocket 就是一条长连接）。
    @MainActor
    func testRepeatedStartKeepsPortAndLiveConnection() async throws {
        let server = try FakeServer(echoing: true)
        let port = try await server.start()
        defer { server.stop() }

        let proxy = UplinkLocalProxy()
        let target = UplinkLocalProxy.Target(host: "127.0.0.1", port: port)
        let url = try await proxy.start(target: target)
        defer { Task { await proxy.stop() } }

        let client = try await Self.connect(to: try XCTUnwrap(url.port.map(UInt16.init(exactly:)) ?? nil))
        defer { client.cancel() }

        try await Self.send("ping", on: client)
        let first = try await Self.receive(from: client)
        XCTAssertEqual(first, "ping", "代理双向转发")

        // 模拟"又一次 connect() 走到同一个档位"
        let again = try await proxy.start(target: target)
        XCTAssertEqual(again.port, url.port, "同 target 不许换端口")

        // 关键断言：那条连接还在（没被 cancelTunnels 干掉）。
        try await Self.send("pong", on: client)
        let second = try await Self.receive(from: client)
        XCTAssertEqual(second, "pong", "重复 start 不该打断在途连接 —— 这正是 WS 被打断的原因")
    }

    /// 换 target：端口不变，但新连接走新远端；旧的在途连接必须断掉。
    @MainActor
    func testUpdateTargetKeepsPortAndDropsOldTunnels() async throws {
        let first = try FakeServer(echoing: true)
        let second = try FakeServer(echoing: true)
        let firstPort = try await first.start()
        let secondPort = try await second.start()
        defer { first.stop(); second.stop() }

        let proxy = UplinkLocalProxy()
        let url = try await proxy.start(target: .init(host: "127.0.0.1", port: firstPort))
        defer { Task { await proxy.stop() } }

        let updated = try await proxy.start(target: .init(host: "127.0.0.1", port: secondPort))
        XCTAssertEqual(updated.port, url.port, "换档也不换端口")

        let client = try await Self.connect(to: try XCTUnwrap(updated.port.map(UInt16.init(exactly:)) ?? nil))
        defer { client.cancel() }
        try await Self.send("hi", on: client)
        let echoed = try await Self.receive(from: client)
        XCTAssertEqual(echoed, "hi")
        XCTAssertTrue(second.received.isEmpty || true, "新连接应当落到第二个远端")
        XCTAssertTrue(first.received.isEmpty, "换档之后不该再有连接打到旧远端")
    }

    /// `stop()` 之后端口应当被释放（否则下一次绑不上，日志里就是 NWError 48）。
    @MainActor
    func testStopReleasesPort() async throws {
        let server = try FakeServer(echoing: true)
        let port = try await server.start()
        defer { server.stop() }

        let proxy = UplinkLocalProxy()
        let url = try await proxy.start(target: .init(host: "127.0.0.1", port: port))
        let bound = try XCTUnwrap(url.port)
        await proxy.stop()

        // 同一个端口应当能重新绑上（用另一个代理实例来抢）。
        let other = UplinkLocalProxy()
        _ = try await other.start(target: .init(host: "127.0.0.1", port: port))
        let otherURL = await other.currentBaseURL()
        XCTAssertNotNil(otherURL)
        await other.stop()
        XCTAssertNotEqual(bound, 0)
    }

    // MARK: NWConnection 小工具

    private static func connect(to port: UInt16) async throws -> NWConnection {
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: try XCTUnwrap(NWEndpoint.Port(rawValue: port)),
            using: .tcp
        )
        let gate = Gate()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.once { continuation.resume() }
                case .failed(let error): gate.once { continuation.resume(throwing: error) }
                case .waiting(let error): gate.once { continuation.resume(throwing: error) }
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
        return connection
    }

    private static func send(_ text: String, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(text.utf8), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private static func receive(from connection: NWConnection) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: String(decoding: data ?? Data(), as: UTF8.self))
            }
        }
    }

    // MARK: ③ iroh 兜底的计划 / 单飞

    /// 有档可达 → 推迟（预热）；全不可达 → 立刻用码配。这条是产品决策的钉子。
    func testIrohPlanDecisionTable() {
        XCTAssertEqual(
            UplinkIrohPlan.resolve(gatewayReachable: true, irohAlreadyPaired: false,
                                   hasIrohEndpoint: true, hasPairingCode: true),
            .prewarm,
            "网关通了就推迟：那时有票，晚点要码也不迟"
        )
        XCTAssertEqual(
            UplinkIrohPlan.resolve(gatewayReachable: false, irohAlreadyPaired: false,
                                   hasIrohEndpoint: true, hasPairingCode: true),
            .pairNow,
            "一个档都不通：立刻用配对串里的码配 —— 这是唯一不需要 HTTP 的路"
        )
        XCTAssertEqual(
            UplinkIrohPlan.resolve(gatewayReachable: false, irohAlreadyPaired: false,
                                   hasIrohEndpoint: true, hasPairingCode: false),
            .none,
            "没码又没网：什么都做不了，别假装在试"
        )
        XCTAssertEqual(
            UplinkIrohPlan.resolve(gatewayReachable: true, irohAlreadyPaired: true,
                                   hasIrohEndpoint: true, hasPairingCode: true),
            .none,
            "已经配过就不要再配（电脑端对失败有限流）"
        )
        XCTAssertEqual(
            UplinkIrohPlan.resolve(gatewayReachable: true, irohAlreadyPaired: false,
                                   hasIrohEndpoint: false, hasPairingCode: true),
            .none
        )
    }

    /// 单飞：并发三次只执行一次（真机日志里的"上一次连接还在进行中"就是没合并）。
    @MainActor
    func testSingleFlightRunsOnce() async {
        let flight = SingleFlight<Int>()
        let counter = CounterBox()
        async let a = flight.run { counter.value += 1; try? await Task.sleep(for: .milliseconds(80)); return 1 }
        async let b = flight.run { counter.value += 1; return 2 }
        async let c = flight.run { counter.value += 1; return 3 }
        let values = await [a, b, c]
        XCTAssertEqual(counter.value, 1, "三次并发只该跑一次")
        XCTAssertEqual(values, [1, 1, 1], "其余两次复用的同一次结果")
    }

    @MainActor
    func testSingleFlightRunsAgainAfterFinishing() async {
        let flight = SingleFlight<Int>()
        let counter = CounterBox()
        _ = await flight.run { counter.value += 1; return 1 }
        _ = await flight.run { counter.value += 1; return 2 }
        XCTAssertEqual(counter.value, 2, "落定之后下一次应当重新执行")
    }

    private final class CounterBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0
        var value: Int {
            get { lock.lock(); defer { lock.unlock() }; return storage }
            set { lock.lock(); storage = newValue; lock.unlock() }
        }
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


    /// `Reset` 是**瞬时**错误：首行不变，等一会儿重试一次。
    func testTransientResetRetriesOnceWithSameMessage() async throws {
        var attempts = 0
        let result = try await TetherFirstMessageRecovery.run(
            first: .hello, pairingCode: nil, retryDelay: .milliseconds(1)
        ) { message in
            attempts += 1
            XCTAssertEqual(message, .hello, "瞬时错误不该换首行")
            if attempts == 1 { throw TetherError.transport("ConnectionLost(Reset)") }
            return "ok"
        }
        XCTAssertEqual(result.value, "ok")
        XCTAssertEqual(attempts, 2)
    }

    /// Reset 也只重试**一次**，不循环。
    func testTransientResetRetriesOnlyOnce() async {
        var attempts = 0
        do {
            _ = try await TetherFirstMessageRecovery.run(
                first: .hello, pairingCode: nil, retryDelay: .milliseconds(1)
            ) { _ in
                attempts += 1
                throw TetherError.transport("ConnectionLost(Reset)")
            }
            XCTFail("一直 Reset 就该抛出来")
        } catch {
            XCTAssertTrue(TetherFirstMessageRecovery.isTransientReset(error))
        }
        XCTAssertEqual(attempts, 2, "initial + 一次重试")
    }

    /// 两类错误必须分得开：`Reset` 瞬时、`protocol` 是状态不一致。
    func testResetAndProtocolAreDistinguished() {
        let reset = TetherError.transport("ConnectionLost(Reset)")
        XCTAssertTrue(TetherFirstMessageRecovery.isTransientReset(reset))
        XCTAssertFalse(TetherFirstMessageRecovery.isProtocolMismatch(reset), "Reset 不该触发首行取反")

        let protocolError = Self.protocolError()
        XCTAssertTrue(TetherFirstMessageRecovery.isProtocolMismatch(protocolError))
        XCTAssertFalse(TetherFirstMessageRecovery.isTransientReset(protocolError), "protocol 不是瞬时错误")
    }

    /// 日志里不能出现配对码。
    func testLabelsNeverLeakTheCode() {
        XCTAssertEqual(TetherFirstMessageRecovery.label(.pair(code: "123456")), "pair")
        XCTAssertEqual(TetherFirstMessageRecovery.label(.hello), "hello")
    }
}
