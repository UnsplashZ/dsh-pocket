import Foundation
import Network

/// `127.0.0.1:<port>` → 选中的那一档（host:port），原样 TCP 转发。
///
/// ## 为什么必须有这一层（真机 + 模拟器都实测过）
///
/// **ATS 只放行"本地"地址。** `NSAllowsLocalNetworking` 覆盖 10/8、172.16/12、
/// 192.168/16 与 `.local`，但 **CGNAT（100.64/10，Tailscale）和公网 IP（frp）都会被
/// 拒掉**。模拟器实测：
///
/// ```
/// http://10.8.54.221:18788   → 通            （RFC1918，放行）
/// http://100.64.16.30:18788  → code=-1022    （ATS requires a secure connection）
/// http://192.168.1.1:18788   → -1001 超时    （放行，只是不通）
/// ```
///
/// 而**回环永远放行**。所以把远端藏在回环后面 —— 和 ADR-0004 的 iroh 本地代理
/// 完全同一个思路：上层（`URLSession` / `URLSessionWebSocketTask`）只认识 127.0.0.1。
///
/// 两条捷径都走不通，别试：
///   · `NSAllowsArbitraryLoads` —— ADR / docs/TRANSPORT.md §6 明令禁止；
///   · `NSExceptionDomains` 写 IP —— ATS **不支持 IP 作为 domain key**，
///     而且每个用户的 IP 都不一样，写不出来。
///
/// ## 端口策略
///
/// 首次绑 **系统分配**（`127.0.0.1:0`）。换档时**不重新绑**，只换目标 ——
/// 端口稳定，`URLSession` 的连接复用与已建立的 WebSocket 才不会莫名失效。
public actor UplinkLocalProxy {
    /// 转发目标。就是选中那一档的 host:port。
    public struct Target: Sendable, Equatable {
        public let host: String
        public let port: UInt16

        public init(host: String, port: UInt16) {
            self.host = host
            self.port = port
        }

        /// 从档位的 URL 取 host/port。没有端口时按 http 的 80 处理。
        public init?(url: URL) {
            guard let host = url.host, !host.isEmpty else { return nil }
            let port = url.port ?? 80
            guard let value = UInt16(exactly: port), value > 0 else { return nil }
            self.init(host: host, port: value)
        }

        var endpointHost: NWEndpoint.Host { NWEndpoint.Host(host) }
        var endpointPort: NWEndpoint.Port? { NWEndpoint.Port(rawValue: port) }
    }

    private var listener: NWListener?
    private var boundPort: UInt16?
    private var target: Target?
    private var tunnels: [ObjectIdentifier: Tunnel] = [:]

    public init() {}

    /// 起监听（幂等）并把目标指向 `target`。
    ///
    /// **同一档：什么都不做。** 端口不变、listener 不重建、**在途连接不动** ——
    /// 真机日志里 `mux 断开（连了 1.9s）` 就是因为这里每次都被重新绑了一遍，
    /// 正在跑的 WebSocket 被自己人打断。
    ///
    /// 换档：原地换远端（端口保持不变），只断在途连接（它们还连着上一档）。
    @discardableResult
    public func start(target: Target) async throws -> URL {
        if let boundPort, listener != nil, let url = URL(string: "http://127.0.0.1:\(boundPort)") {
            updateTarget(target)
            return url
        }
        self.target = target
        let port = try await bind()
        boundPort = port
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    /// 原地换远端：**端口不变**，只断掉指向旧远端的在途连接。
    ///
    /// 同一个 target 时是纯空操作 —— 这条是"重连不该打断 WS"的落点。
    public func updateTarget(_ target: Target) {
        guard self.target != target else { return }
        self.target = target
        cancelTunnels()
    }

    public func stop() {
        listener?.newConnectionHandler = nil
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        cancelTunnels()
        boundPort = nil
        target = nil
    }

    public func currentBaseURL() -> URL? {
        guard let boundPort else { return nil }
        return URL(string: "http://127.0.0.1:\(boundPort)")
    }

    public func currentTarget() -> Target? { target }

    // MARK: 内部

    private func bind() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredInterfaceType = .loopback

        let listener: NWListener
        do {
            // 端口传 nil = 系统分配。**不要**用固定端口：同一个手机上可能同时
            // 有 iroh 的本地代理，撞上就整条路起不来。
            listener = try NWListener(using: parameters)
        } catch {
            throw UplinkError.badResponse(String(localized: "本地代理起不来：\(error.localizedDescription)"))
        }

        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }

        let gate = PortGate()
        do {
            let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        gate.resumeOnce { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                    case .failed(let error):
                        gate.resumeOnce { continuation.resume(throwing: error) }
                    case .cancelled:
                        gate.resumeOnce {
                            continuation.resume(
                                throwing: UplinkError.badResponse(String(localized: "本地代理的监听被取消"))
                            )
                        }
                    default:
                        break
                    }
                }
                listener.start(queue: .global(qos: .userInitiated))
            }
            self.listener = listener
            return port
        } catch {
            // 失败也要收掉，否则这个端口会被一直占着（NWListener 的经典坑）。
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            listener.cancel()
            throw UplinkError.badResponse(String(localized: "本地代理起不来：\(error.localizedDescription)"))
        }
    }

    private func accept(_ connection: NWConnection) {
        guard let target else {
            connection.cancel()
            return
        }
        let tunnel = Tunnel(downstream: connection, target: target) { [weak self] identifier in
            Task { await self?.retire(identifier) }
        }
        tunnels[ObjectIdentifier(connection)] = tunnel
        tunnel.start()
    }

    private func retire(_ identifier: ObjectIdentifier) {
        tunnels[identifier] = nil
    }

    private func cancelTunnels() {
        for tunnel in tunnels.values { tunnel.cancel() }
        tunnels.removeAll()
    }
}

/// 保证 continuation **只被 resume 一次**（`NWListener` 的状态回调可能先 ready 再 failed）。
private final class PortGate: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func resumeOnce(_ body: () -> Void) {
        lock.lock()
        if used {
            lock.unlock()
            return
        }
        used = true
        lock.unlock()
        body()
    }
}

/// 一条「本地连接 ↔ 远端 TCP 连接」的双向泵。
///
/// 两个方向各一个循环，64KB 一块，`send` 等 `contentProcessed` 再读下一块 ——
/// 这就是回压：远端慢的时候本地读取自然变慢，不会把整个响应堆在内存里。
/// 任一侧结束时给对面发 `.finalMessage`（half-close），两边都结束才拆连接。
private final class Tunnel: @unchecked Sendable {
    private static let chunkSize = 64 * 1024

    private let downstream: NWConnection
    private let upstream: NWConnection
    private let onFinish: @Sendable (ObjectIdentifier) -> Void

    private var task: Task<Void, Never>?
    private let lock = NSLock()
    private var finished = false
    private var readyGate = false
    private var readyContinuation: CheckedContinuation<Bool, Never>?

    init(
        downstream: NWConnection,
        target: UplinkLocalProxy.Target,
        onFinish: @escaping @Sendable (ObjectIdentifier) -> Void
    ) {
        self.downstream = downstream
        self.onFinish = onFinish
        if let port = target.endpointPort {
            self.upstream = NWConnection(host: target.endpointHost, port: port, using: .tcp)
        } else {
            self.upstream = NWConnection(host: target.endpointHost, port: 80, using: .tcp)
        }
    }

    func start() {
        downstream.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        downstream.start(queue: .global(qos: .userInitiated))

        upstream.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.resumeReady(true)
            case .failed, .cancelled:
                self?.resumeReady(false)
                self?.finish()
            default: break
            }
        }
        upstream.start(queue: .global(qos: .userInitiated))

        task = Task { [weak self] in
            guard let self else { return }
            guard await self.waitReady() else { return }
            await self.pumpBothWays()
            self.finish()
        }
    }

    func cancel() {
        finish()
    }

    // MARK: 内部

    private func waitReady() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if readyGate {
                lock.unlock()
                continuation.resume(returning: true)
                return
            }
            if finished {
                lock.unlock()
                continuation.resume(returning: false)
                return
            }
            readyContinuation = continuation
            lock.unlock()
        }
    }

    private func resumeReady(_ ok: Bool) {
        lock.lock()
        let continuation = readyContinuation
        readyContinuation = nil
        if ok { readyGate = true }
        lock.unlock()
        continuation?.resume(returning: ok)
    }

    private func pumpBothWays() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self else { return }
                await self.pump(from: self.downstream, to: self.upstream)
            }
            group.addTask { [weak self] in
                guard let self else { return }
                await self.pump(from: self.upstream, to: self.downstream)
            }
            await group.waitForAll()
        }
    }

    private func pump(from source: NWConnection, to sink: NWConnection) async {
        while !Task.isCancelled {
            let chunk: Data? = await withCheckedContinuation { continuation in
                source.receive(minimumIncompleteLength: 1, maximumLength: Self.chunkSize) {
                    data, _, isComplete, error in
                    if error != nil {
                        continuation.resume(returning: nil)
                        return
                    }
                    if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                        return
                    }
                    // 没有数据：只有"对端说完了"才是结束，否则继续读。
                    continuation.resume(returning: isComplete ? nil : Data())
                }
            }
            guard let chunk else {
                // half-close：告诉对面"我这个方向发完了"，另一方向继续。
                sink.send(
                    content: nil,
                    contentContext: .finalMessage,
                    isComplete: true,
                    completion: .contentProcessed { _ in }
                )
                return
            }
            if chunk.isEmpty { continue }
            let sent: Bool = await withCheckedContinuation { continuation in
                sink.send(content: chunk, completion: .contentProcessed { error in
                    continuation.resume(returning: error == nil)
                })
            }
            if !sent { return }
        }
    }

    private func finish() {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let pending = readyContinuation
        readyContinuation = nil
        lock.unlock()

        pending?.resume(returning: false)
        task?.cancel()
        downstream.stateUpdateHandler = nil
        upstream.stateUpdateHandler = nil
        downstream.cancel()
        upstream.cancel()
        onFinish(ObjectIdentifier(downstream))
    }
}
