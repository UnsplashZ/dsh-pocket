import Foundation
import IrohLib
import Network

/// 一条已建立的代理流的两端。**刻意不公开**：它握着 IrohLib 的流类型，
/// 而 App 只该看到 `TetherSession` 这一层，不该被迫 `import IrohLib`。
struct TetherProxyStream: Sendable {
    let send: any SendStreamProtocol
    let recv: any RecvStreamProtocol
}

/// 本地代理"要一条新代理流"时找谁。
protocol TetherStreamFactory: Sendable {
    func openProxyStream() async throws -> TetherProxyStream
}

/// `127.0.0.1:<派生端口>` → iroh 代理流 → 电脑端的 DSH。
///
/// 为什么保留这一层（ADR-0004）：上层可以直接用 `URLSession` 与
/// `URLSessionWebSocketTask`，原生网络栈的连接复用、超时、取消语义都是系统给的；
/// ATS 例外只需要覆盖回环；调试时还能用 curl 直接打这个端口。
///
/// **已知边界**（docs/TRANSPORT.md §8.5）：它只监听回环，但手机上其它 App 可以连它，
/// 且端口可由主机 ID 推算。一期如实告知用户，后续可加进程内握手令牌（需要电脑端配合）。
actor LocalProxyServer {
    private let factory: any TetherStreamFactory
    private let preferredPort: UInt16
    private let logger: (any TetherLogSink)?

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: ProxyPump] = [:]

    /// 实际监听端口。端口被占用时会回退到系统分配 —— 因此**上层不要缓存 authority**。
    private var boundPort: UInt16?

    init(factory: any TetherStreamFactory, preferredPort: UInt16, logger: (any TetherLogSink)? = nil) {
        self.factory = factory
        self.preferredPort = preferredPort
        self.logger = logger
    }

    /// 启动监听，返回真实的 `http://127.0.0.1:<port>` 基址。
    ///
    /// 两道保险：
    ///   1. 先试**派生端口**（同一主机的代理 origin 稳定，URLSession 的连接复用才一致）；
    ///   2. 失败就回退**系统分配**。回退之后 authority 会变，所以上层**不要缓存**它。
    ///
    /// ⚠️ `NWListener(using:on:)` **不会**在端口被占用时同步抛错 —— 绑定失败是异步地
    /// 通过 `stateUpdateHandler` 的 `.failed` 送来的。之前只 catch 了同步抛错，
    /// 于是端口冲突直接变成"本地代理启动失败"，而监听对象还留着继续占端口，
    /// 下一次重连必然再撞一次（真机上表现为 `NWError 48 - Address already in use`）。
    @discardableResult
    func start() async throws -> URL {
        if let boundPort, listener != nil {
            return URL(string: "http://127.0.0.1:\(boundPort)")!
        }

        do {
            return try await bind(preferredPort: preferredPort)
        } catch {
            logger?.log("首选端口 \(preferredPort) 不可用（\(error.localizedDescription)），回退系统分配")
            return try await bind(preferredPort: nil)
        }
    }

    /// 真正绑一次。失败时**一定**把监听收掉，绝不把端口留在占用状态。
    private func bind(preferredPort: UInt16?) async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredInterfaceType = .loopback

        let listener: NWListener
        do {
            if let preferredPort {
                guard let candidate = NWEndpoint.Port(rawValue: preferredPort) else {
                    throw TetherError.proxyUnavailable(String(localized: "端口 \(preferredPort) 不在合法范围"))
                }
                listener = try NWListener(using: parameters, on: candidate)
            } else {
                listener = try NWListener(using: parameters)
            }
        } catch {
            throw TetherError.proxyUnavailable(error.localizedDescription)
        }

        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }

        let gate = ContinuationGate()
        do {
            let port = try await withCheckedThrowingContinuation { continuation in
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        gate.resumeOnce { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                    case .failed(let error):
                        gate.resumeOnce { continuation.resume(throwing: error) }
                    case .cancelled:
                        gate.resumeOnce {
                            continuation.resume(throwing: TetherError.proxyUnavailable(String(localized: "监听被取消")))
                        }
                    default:
                        break
                    }
                }
                listener.start(queue: .global(qos: .userInitiated))
            }

            self.listener = listener
            markReady(port: port)
            return URL(string: "http://127.0.0.1:\(port)")!
        } catch {
            // 关键：失败也要收掉，否则这个端口会被一直占着。
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            listener.cancel()
            throw TetherError.proxyUnavailable(error.localizedDescription)
        }
    }

    private func markReady(port: UInt16) {
        boundPort = port
        logger?.log("本地代理已就绪 127.0.0.1:\(port)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for pump in connections.values { pump.cancel() }
        connections.removeAll()
        boundPort = nil
    }

    func currentBaseURL() -> URL? {
        guard let boundPort else { return nil }
        return URL(string: "http://127.0.0.1:\(boundPort)")
    }

    private func accept(_ connection: NWConnection) {
        let pump = ProxyPump(connection: connection, factory: factory, logger: logger) { [weak self] identifier in
            Task { await self?.retire(identifier) }
        }
        connections[ObjectIdentifier(connection)] = pump
        pump.start()
    }

    private func retire(_ identifier: ObjectIdentifier) {
        connections[identifier] = nil
    }
}

/// 保证 continuation **只被 resume 一次**。
///
/// `NWListener` 的状态回调可能先 `.ready` 再 `.failed`（或者反过来），
/// 而 `CheckedContinuation` 二次 resume 会直接崩。用一把锁把它钉住。
private final class ContinuationGate: @unchecked Sendable {
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

/// 一条 TCP 连接 ↔ 一条 iroh 代理流的双向泵。
private final class ProxyPump: @unchecked Sendable {
    private let connection: NWConnection
    private let factory: any TetherStreamFactory
    private let logger: (any TetherLogSink)?
    private let onFinish: (ObjectIdentifier) -> Void

    private var task: Task<Void, Never>?
    private let lock = NSLock()
    private var finished = false

    init(
        connection: NWConnection,
        factory: any TetherStreamFactory,
        logger: (any TetherLogSink)?,
        onFinish: @escaping (ObjectIdentifier) -> Void
    ) {
        self.connection = connection
        self.factory = factory
        self.logger = logger
        self.onFinish = onFinish
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.finish()
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await self.factory.openProxyStream()
                await self.pump(stream)
            } catch {
                self.logger?.log("代理流打开失败：\(error.localizedDescription)")
                self.finish()
            }
        }
    }

    func cancel() {
        finish()
    }

    private func pump(_ stream: TetherProxyStream) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self else { return }
                await self.pumpUpstream(to: stream)
            }
            group.addTask { [weak self] in
                guard let self else { return }
                await self.pumpDownstream(from: stream)
            }
            await group.waitForAll()
        }
        try? await stream.send.finish()
        finish()
    }

    /// TCP → iroh。读多少次写多少次，不做缓冲合并（HTTP 头尾分开到达是常态）。
    private func pumpUpstream(to stream: TetherProxyStream) async {
        while !Task.isCancelled {
            let chunk: Data? = await withCheckedContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if error != nil || (isComplete && (data?.isEmpty ?? true)) {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: data ?? Data())
                }
            }
            guard let chunk, !chunk.isEmpty else { return }
            do {
                try await stream.send.writeAll(buf: chunk)
            } catch {
                return
            }
        }
    }

    /// iroh → TCP。
    private func pumpDownstream(from stream: TetherProxyStream) async {
        while !Task.isCancelled {
            let chunk: Data
            do {
                chunk = try await stream.recv.read(sizeLimit: 64 * 1024)
            } catch {
                break
            }
            if chunk.isEmpty { break }
            let ok = await withCheckedContinuation { continuation in
                connection.send(content: chunk, completion: .contentProcessed { error in
                    continuation.resume(returning: error == nil)
                })
            }
            if !ok { break }
        }
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func finish() {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()

        task?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
        onFinish(ObjectIdentifier(connection))
    }
}
