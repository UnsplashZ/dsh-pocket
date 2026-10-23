import Foundation
import Network

/// 用 `NWConnection` 探一档。
///
/// **为什么不能用 URLSession 探测**：ATS 对 `http://100.64.x`（Tailscale 的 CGNAT 段）
/// 与公网 IP 一律回 `-1022 ATS requires a secure connection`，于是这两档**永远探不通**，
/// 而它们恰恰是"在外面也能连"的主力。`Network` 框架不经过 ATS，所以探测走它。
///
/// 探测本身是一个最小的 HTTP/1.1 请求：
///
/// ```
/// GET /uplink/ping HTTP/1.1
/// Host: <host>:<port>
/// Connection: close
///
/// ```
///
/// 网关回 `{"ok":true,"hostId":"…","v":"…"}`（免票）。**必须核对 hostId** ——
/// 同一网段里可能有好几台跑 dsh 的电脑，连错人比连不上更糟。
public enum UplinkTCPProbe {
    /// 探一档，返回 RTT 或失败原因。
    public static func ping(
        tier: UplinkTier,
        expectedHostId: String,
        timeout: TimeInterval
    ) async -> UplinkProbeResult {
        guard let host = tier.url.host, !host.isEmpty else {
            return .unreachable(.other(milliseconds: 1, reason: "no-host"))
        }
        let portValue = UInt16(exactly: tier.url.port ?? 80) ?? 80
        guard let port = NWEndpoint.Port(rawValue: portValue) else {
            return .unreachable(.other(milliseconds: 1, reason: "bad-port"))
        }

        let started = Date()
        func elapsed() -> Int { max(1, Int(Date().timeIntervalSince(started) * 1000)) }

        let run = ProbeRun()
        return await withCheckedContinuation { continuation in
            run.attach(continuation: continuation)

            let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
            run.attach(connection: connection)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    sendRequest(connection, host: host, port: portValue, expectedHostId: expectedHostId, run: run, elapsed: elapsed)
                case .waiting(let error):
                    // 端口没人监听时 `NWConnection` 报的是 **`.waiting(ECONNREFUSED)`**
                    // 而不是 `.failed`（它以为"等一下也许就好了"）。可对被拒这件事，
                    // 等下去没有意义 —— 直接判"被拒"，别耗满超时。
                    if case .posix(.ECONNREFUSED) = error {
                        run.finish(.unreachable(.refused(milliseconds: elapsed())))
                    }
                case .failed(let error):
                    run.finish(.unreachable(UplinkProbeFailure(nwError: error, milliseconds: elapsed())))
                case .cancelled:
                    run.finish(.unreachable(.other(milliseconds: elapsed(), reason: "cancelled")))
                default:
                    break
                }
            }
            connection.start(queue: probeQueue)

            // 超时兜底：`NWConnection` 的 `.waiting` 可能挂很久（没有路由时会一直等），
            // 而探测必须有一个硬上限 —— 否则一档不通就拖住整个并行探测。
            probeQueue.asyncAfter(deadline: .now() + timeout) {
                run.finish(.unreachable(.timedOut(milliseconds: elapsed())))
            }
        }
    }

    static let probeQueue = DispatchQueue(label: "cc.unsplashz.dshpocket.uplink.probe")

    // MARK: 请求

    private static func sendRequest(
        _ connection: NWConnection,
        host: String,
        port: UInt16,
        expectedHostId: String,
        run: ProbeRun,
        elapsed: @escaping () -> Int
    ) {
        let request = """
        GET /uplink/ping HTTP/1.1\r
        Host: \(host):\(port)\r
        Accept: application/json\r
        User-Agent: DSHPocket-uplink\r
        Connection: close\r
        \r

        """
        connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
            if let error {
                run.finish(.unreachable(UplinkProbeFailure(nwError: error, milliseconds: elapsed())))
                return
            }
            receiveLoop(connection, buffer: Data(), expectedHostId: expectedHostId, run: run, elapsed: elapsed)
        })
    }

    private static func receiveLoop(
        _ connection: NWConnection,
        buffer: Data,
        expectedHostId: String,
        run: ProbeRun,
        elapsed: @escaping () -> Int
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            data, _, isComplete, error in
            var accumulated = buffer
            if let data, !data.isEmpty { accumulated.append(data) }

            if let error {
                run.finish(.unreachable(UplinkProbeFailure(nwError: error, milliseconds: elapsed())))
                return
            }
            // 响应很小（几十字节）。真收到这么多还没结束，多半是打到了别的服务上。
            if accumulated.count > 64 * 1024 {
                run.finish(.unreachable(.other(milliseconds: elapsed(), reason: "response-too-large")))
                return
            }
            if let result = parseIfComplete(accumulated, expectedHostId: expectedHostId, elapsed: elapsed) {
                run.finish(result)
                return
            }
            if isComplete {
                // 连接关了但响应不完整（对端只发了头、或者根本不是 HTTP）。
                run.finish(.unreachable(.other(milliseconds: elapsed(), reason: "incomplete-response")))
                return
            }
            receiveLoop(connection, buffer: accumulated, expectedHostId: expectedHostId, run: run, elapsed: elapsed)
        }
    }

    // MARK: 解析（单测直接打这个）

    /// 解析 `/uplink/ping` 的 JSON 体。
    static func parsePingBody(
        _ body: Data,
        expectedHostId: String,
        elapsed: () -> Int
    ) -> UplinkProbeResult {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return .unreachable(.other(milliseconds: elapsed(), reason: "bad-body"))
        }
        guard object["ok"] as? Bool == true else {
            return .unreachable(.other(milliseconds: elapsed(), reason: "not-ok"))
        }
        if let got = object["hostId"] as? String, got != expectedHostId {
            // 这个地址上是**另一台**电脑。不是"连不上"，是"连错人" —— 必须分开。
            return .unreachable(.hostMismatch(milliseconds: elapsed()))
        }
        return .reachable(rttMilliseconds: elapsed())
    }

    /// 便捷重载：`parseIfComplete` 不知道期望的 hostId，解析体时再核对。
    static func parseIfComplete(
        _ data: Data,
        expectedHostId: String,
        elapsed: () -> Int
    ) -> UplinkProbeResult? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return nil }
        let statusParts = statusLine.split(separator: " ")
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else {
            return .unreachable(.other(milliseconds: elapsed(), reason: "bad-status-line"))
        }
        guard status == 200 else {
            return .unreachable(.other(milliseconds: elapsed(), reason: "http-\(status)"))
        }
        var expected = 0
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "content-length" else { continue }
            expected = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }
        let body = data[headerEnd.upperBound...]
        if expected > 0, body.count < expected { return nil }
        return parsePingBody(Data(body), expectedHostId: expectedHostId, elapsed: elapsed)
    }
}

extension UplinkProbeFailure {
    /// `NWError` → 我们那几类。`Network` 框架不走 ATS，所以这里**不会**出现 -1022。
    public init(nwError: NWError, milliseconds: Int) {
        switch nwError {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED:
                self = .refused(milliseconds: milliseconds)
            case .ETIMEDOUT:
                self = .timedOut(milliseconds: milliseconds)
            case .ENETDOWN, .ENETUNREACH, .EHOSTUNREACH, .EHOSTDOWN:
                // 没有到那个地址的路由：要么网络类型不对（蜂窝 + 私有地址），
                // 要么对端不在线。归到 offline，文案会说"网络不可达"。
                self = .offline(milliseconds: milliseconds)
            default:
                self = .other(milliseconds: milliseconds, reason: "posix-\(code.rawValue)")
            }
        case .dns:
            self = .unknownHost(milliseconds: milliseconds)
        case .tls:
            self = .other(milliseconds: milliseconds, reason: "tls")
        @unknown default:
            self = .other(milliseconds: milliseconds, reason: "nw")
        }
    }
}

/// 一次探测的收尾盒子：保证 continuation **只 resume 一次**、连接一定被取消。
///
/// `NWConnection` 的状态回调与超时定时器会赛跑（.ready 之后紧跟着 .failed 很常见），
/// 而 `CheckedContinuation` 二次 resume 会直接崩。
private final class ProbeRun: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var continuation: CheckedContinuation<UplinkProbeResult, Never>?
    private var connection: NWConnection?

    func attach(continuation: CheckedContinuation<UplinkProbeResult, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func attach(connection: NWConnection) {
        lock.lock()
        if done {
            lock.unlock()
            connection.cancel()
            return
        }
        self.connection = connection
        lock.unlock()
    }

    func finish(_ result: UplinkProbeResult) {
        lock.lock()
        if done {
            lock.unlock()
            return
        }
        done = true
        let pending = continuation
        continuation = nil
        let active = connection
        connection = nil
        lock.unlock()

        active?.stateUpdateHandler = nil
        active?.cancel()
        pending?.resume(returning: result)
    }
}
