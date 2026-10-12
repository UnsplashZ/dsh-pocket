import Foundation
import IrohLib
import Network

/// TetherKit 自己的日志出口。
///
/// 刻意**不**依赖 DSHKit：传输层与协议层是两个可独立复用的包（见 DESIGN.md §3.1）。
/// App 里用一个适配器把两边接到同一个日志缓冲。
public protocol TetherLogSink: Sendable {
    func log(_ message: String)
}

/// 连接诊断信息：诊断页要显示的"当前走的是 direct 还是 relay"就在这里。
public struct TetherDiagnostics: Sendable, Equatable {
    public var endpointId: String
    public var hostId: String
    public var boundSockets: [String]
    public var isDirect: Bool
    public var remoteAddress: String?
    public var rttMilliseconds: UInt64?
    public var proxyPort: UInt16?
    public var proxyURL: String?
    public var establishedAt: Date?
    public var controlAlive: Bool
}

/// 连接建立后要发的**首行消息**。
///
/// 电脑端对它的校验是**二选一、且与"是否已配对"严格对应**的：
///
/// ```rust
/// let paired = store.devices.iter().any(|d| d.id == remote);
/// match (paired, hello) {
///     (true,  Wire::Hello { name }) => name,      // 已配对 → 只接受 hello
///     (false, Wire::Pair  { code, name }) => {…}  // 未配对 → 只接受 pair
///     _ => { conn.close(1, b"protocol"); bail!("未按协议发首行") }
/// }
/// ```
///
/// 所以**不能"有配对码就发 pair"** —— 对一台已经认识这台手机的电脑发 pair，
/// 会被判成协议错误并直接断开（真机上踩到过：配对成功之后再点一次配对，
/// 电脑端日志是 `the first line does not follow the protocol(paired=true)`）。
/// 官方 Rust 客户端也是靠自己的"已配对列表"决定发哪个，而不是先发 pair 试试。
public enum TetherFirstMessage: Sendable, Equatable {
    /// 已配对：只报个名字。
    case hello
    /// 未配对：拿配对码换白名单里的一个位置。
    case pair(code: String)
}

/// 一条 iroh 连接的生命周期。
///
/// 为什么需要把它暴露出来：控制流断掉之后**不会自己回来** —— 上层必须知道
/// "这条连接死了"，才能重建。之前没有这个信号，表现就是"连上一会儿就断，
/// 界面一直显示正在重连但永远连不上"。
public enum TetherLinkState: Sendable, Equatable {
    case idle
    case connecting(hostId: String)
    case ready(hostId: String)
    case closed(reason: String)

    public var isReady: Bool { if case .ready = self { return true }; return false }
}

/// 与一台电脑的 iroh 连接：控制流 + 代理流工厂。
///
/// 生命周期（docs/TRANSPORT.md §5）：
/// ```
/// 未配对 ──pair──► 已配对 ──hello──► 控制流就绪 ──► 起本地代理 ──► 协议层连 /api 与 WS
/// ```
///
/// **同一身份只允许一条连接**：电脑端会把前一条顶掉（日志里是 `4001 superseded`）。
/// 所以 App 内不要并发建立两条 —— 这个 actor 用 `connecting` 标志挡住。
actor TetherLink: TetherStreamFactory {
    private let identity: TetherIdentity
    private let logger: (any TetherLogSink)?
    private let name: String

    private var endpoint: (any EndpointProtocol)?
    private var connection: (any ConnectionProtocol)?
    private var controlSend: (any SendStreamProtocol)?
    private var controlRecv: (any RecvStreamProtocol)?
    private var controlLoop: Task<Void, Never>?
    private var connecting = false
    private var hostId: String?
    private var establishedAt: Date?

    private var messageContinuations: [UUID: AsyncStream<TetherHostMessage>.Continuation] = [:]
    private var stateContinuations: [UUID: AsyncStream<TetherLinkState>.Continuation] = [:]
    private var linkState: TetherLinkState = .idle
    /// 是不是我们自己主动断的（主动断不该触发上层重连）。
    private var isTearingDown = false

    init(identity: TetherIdentity, name: String, logger: (any TetherLogSink)? = nil) {
        self.identity = identity
        self.name = name
        self.logger = logger
    }

    nonisolated var localEndpointId: String { identity.endpointId }

    // MARK: - 状态

    public func currentState() -> TetherLinkState { linkState }

    /// 连接状态流。订阅时会立刻收到当前状态。
    public func states() -> AsyncStream<TetherLinkState> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(linkState)
            stateContinuations[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.dropStateContinuation(id) }
            }
        }
    }

    private func dropStateContinuation(_ id: UUID) { stateContinuations[id] = nil }

    private func setState(_ next: TetherLinkState) {
        guard linkState != next else { return }
        linkState = next
        for continuation in stateContinuations.values { continuation.yield(next) }
    }

    // MARK: - 连接

    /// 连上电脑并完成 Hello / Pair。
    /// - Parameters:
    ///   - hostEndpointId: 电脑端的 64 位十六进制端点 ID。
    ///   - pairingCode: 首次配对时的 6 位码；已配对则传 `nil`（走 hello）。
    func connect(hostEndpointId: String, pairingCode: String?) async throws {
        try await connect(
            hostEndpointId: hostEndpointId,
            firstMessage: pairingCode.map { .pair(code: $0) } ?? .hello
        )
    }

    func connect(hostEndpointId: String, firstMessage: TetherFirstMessage) async throws {
        guard !connecting else { throw TetherError.transport("已有一次连接正在进行") }
        guard let peerBytes = TetherProxyPort.bytes(fromHex: hostEndpointId), peerBytes.count == 32 else {
            throw TetherError.invalidEndpointId(hostEndpointId)
        }
        connecting = true
        defer { connecting = false }

        isTearingDown = true
        await teardownConnection()
        isTearingDown = false
        setState(.connecting(hostId: hostEndpointId))

        do {
            let endpoint = try await bindEndpoint()
            let peer = try EndpointId.fromString(s: hostEndpointId)
            let address = EndpointAddr(id: peer, relayUrl: nil, addresses: [])
            logger?.log("连接电脑 \(hostEndpointId.prefix(12))…（preset N0，ALPN \(TetherWire.alpn)）")

            let connection = try await endpoint.connect(addr: address, alpn: Data(TetherWire.alpn.utf8))
            self.endpoint = endpoint
            self.connection = connection

            let bi = try await connection.openBi()
            let send = bi.send()
            let recv = bi.recv()
            self.controlSend = send
            self.controlRecv = recv

            let first: Data
            let isPairing: Bool
            switch firstMessage {
            case .hello:
                first = TetherWire.hello(name: name)
                isPairing = false
            case .pair(let code):
                first = TetherWire.pair(code: code, name: name)
                isPairing = true
            }
            try await send.writeAll(buf: first)

            if isPairing {
                let reply = try await readControlLine(timeout: .seconds(20))
                switch TetherHostMessage.decode(line: reply) {
                case .pairOk:
                    logger?.log("配对成功")
                case .pairFail(let reason):
                    await teardownConnection()
                    throw TetherError.pairingFailed(TetherPairFailure(reason: reason))
                case .some(let other):
                    await teardownConnection()
                    throw TetherError.transport("配对时收到意外消息：\(other)")
                case .none:
                    await teardownConnection()
                    throw TetherError.transport("配对应答无法解析：\(reply.prefix(80))")
                }
            }

            hostId = hostEndpointId
            establishedAt = Date()
            startControlLoop(recv)
            setState(.ready(hostId: hostEndpointId))
            logger?.log("控制流就绪；远端 \(connection.remoteId().description.prefix(12))")
        } catch let error as TetherError {
            await teardownConnection()
            throw error
        } catch {
            await teardownConnection()
            throw TetherError.transport(error.localizedDescription)
        }
    }

    private func bindEndpoint() async throws -> any EndpointProtocol {
        do {
            return try await Endpoint.bind(options: EndpointOptions(
                preset: presetN0(),                                  // 与电脑端 presets::N0 一致
                secretKey: identity.secretKey.toBytes(),
                alpns: [Data(TetherWire.alpn.utf8)]                  // 与电脑端 ALPN 一致
            ))
        } catch {
            throw TetherError.transport("iroh 端点绑定失败：\(error.localizedDescription)")
        }
    }

    /// 断开并释放全部资源。
    func disconnect() async {
        await teardownConnection()
    }

    private func teardownConnection() async {
        let wasReady = linkState.isReady
        isTearingDown = true
        defer { isTearingDown = false }
        controlLoop?.cancel()
        controlLoop = nil
        try? await controlSend?.finish()
        controlSend = nil
        controlRecv = nil
        if let connection {
            try? connection.close(errorCode: 0, reason: Data())
        }
        connection = nil
        if let endpoint {
            try? await endpoint.close()
        }
        endpoint = nil
        hostId = nil
        establishedAt = nil
        for continuation in messageContinuations.values { continuation.finish() }
        messageContinuations.removeAll()
        if wasReady { setState(.idle) }
    }

    // MARK: - 控制流

    /// 电脑端主动发来的消息（审批提醒、审批撤销…）。
    func messages() -> AsyncStream<TetherHostMessage> {
        let id = UUID()
        return AsyncStream { continuation in
            messageContinuations[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.dropContinuation(id) }
            }
        }
    }

    private func dropContinuation(_ id: UUID) {
        messageContinuations[id] = nil
    }

    private func startControlLoop(_ recv: any RecvStreamProtocol) {
        controlLoop?.cancel()
        controlLoop = Task { [weak self] in
            var buffer = JsonLineBuffer()
            while !Task.isCancelled {
                let chunk: Data
                do {
                    chunk = try await recv.read(sizeLimit: UInt32(TetherWire.maxLine))
                } catch {
                    await self?.controlFailed(error.localizedDescription)
                    return
                }
                if chunk.isEmpty {
                    await self?.controlFailed("电脑端关闭了控制流")
                    return
                }
                for line in buffer.append(chunk) {
                    guard let message = TetherHostMessage.decode(line: line) else { continue }
                    await self?.deliver(message)
                }
            }
        }
    }

    private func deliver(_ message: TetherHostMessage) {
        for continuation in messageContinuations.values { continuation.yield(message) }
    }

    private func controlFailed(_ reason: String) {
        logger?.log("控制流断开：\(reason)")
        controlSend = nil
        controlRecv = nil
        for continuation in messageContinuations.values { continuation.finish() }
        messageContinuations.removeAll()
        // 主动断开时不要报 closed —— 否则上层会立刻重连，形成"断-连"风暴。
        guard !isTearingDown else { return }
        setState(.closed(reason: reason))
    }

    /// 读一行控制消息（带超时）。只用于配对握手这种一次性的同步读。
    private func readControlLine(timeout: Duration) async throws -> String {
        guard let recv = controlRecv else { throw TetherError.controlClosed("控制流未建立") }
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                var buffer = JsonLineBuffer()
                while true {
                    let chunk = try await recv.read(sizeLimit: UInt32(TetherWire.maxLine))
                    if chunk.isEmpty { throw TetherError.controlClosed("电脑端关闭了控制流") }
                    let lines = buffer.append(chunk)
                    if let first = lines.first { return first }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TetherError.transport("等待电脑端应答超时")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// 往控制流写一行（`decision` 这类）。
    func sendControl(_ data: Data) async throws {
        guard let controlSend else { throw TetherError.controlClosed("控制流未建立") }
        do {
            try await controlSend.writeAll(buf: data)
        } catch {
            throw TetherError.controlClosed(error.localizedDescription)
        }
    }

    // MARK: - 代理流

    /// 开一条代理流（`TetherStreamFactory`）。上层每次开一条，首行写 `{"type":"proxy"}`。
    func openProxyStream() async throws -> TetherProxyStream {
        guard let connection else { throw TetherError.notPaired }
        do {
            let bi = try await connection.openBi()
            let send = bi.send()
            let recv = bi.recv()
            try await send.writeAll(buf: TetherWire.proxy)
            return TetherProxyStream(send: send, recv: recv)
        } catch {
            throw TetherError.transport("开代理流失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 状态与诊断

    func isConnected() -> Bool { connection != nil && controlSend != nil && linkState.isReady }

    func diagnostics(proxyPort: UInt16? = nil, proxyURL: String? = nil) -> TetherDiagnostics? {
        guard let connection, let hostId else { return nil }
        let paths = connection.paths()
        let selected = paths.first { $0.isSelected } ?? paths.first
        return TetherDiagnostics(
            endpointId: identity.endpointId,
            hostId: hostId,
            boundSockets: endpoint?.boundSockets() ?? [],
            isDirect: !(selected?.isRelay ?? true),
            remoteAddress: selected?.remoteAddr,
            rttMilliseconds: connection.rtt() ?? selected?.rttMs,
            proxyPort: proxyPort,
            proxyURL: proxyURL,
            establishedAt: establishedAt,
            controlAlive: controlSend != nil
        )
    }
}
