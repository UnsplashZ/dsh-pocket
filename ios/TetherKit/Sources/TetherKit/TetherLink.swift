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
    /// 取消代数。每次 `cancelConnect()` 自增；`connect()` 在几个 await 边界上比对它，
    /// 发现自己已经过时就直接抛 `TetherError.cancelled`（而不是当成一次真失败）。
    private var connectEpoch = 0
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
            firstMessage: pairingCode.map { .pair(code: $0) } ?? .hello,
            pairingCode: pairingCode
        )
    }

    /// 连上电脑。首行选错（`close(1, "protocol")`）时**自动取反重试一次**，
    /// 见 `TetherFirstMessageRecovery`。
    ///
    /// 为什么必须在这里做：手机侧"是否已配对"的记录（`hosts.json`）与电脑端白名单
    /// 会不一致（重装 App 清掉了记录、Keychain 身份还在是最常见的形状），
    /// 而首行是**电脑端唯一能看出我们判错的地方**。放在这一层，两个方向都能自愈，
    /// 上层不用知道"到底是记录丢了还是电脑端清了数据"。
    func connect(
        hostEndpointId: String,
        firstMessage: TetherFirstMessage,
        pairingCode: String? = nil
    ) async throws {
        let result = try await TetherFirstMessageRecovery.run(
            first: firstMessage,
            pairingCode: pairingCode
        ) { message in
            try await self.attemptConnect(hostEndpointId: hostEndpointId, firstMessage: message)
        }
        if result.used != firstMessage {
            logger?.log("首行被判协议错误，已取反重试成功（\(TetherFirstMessageRecovery.label(firstMessage)) → \(TetherFirstMessageRecovery.label(result.used))）")
        }
    }

    /// 真正建一次连。**失败不自愈** —— 自愈在 `connect` 那一层做一次就够。
    private func attemptConnect(hostEndpointId: String, firstMessage: TetherFirstMessage) async throws {
        guard !connecting else { throw TetherError.transport(String(localized: "已有一次连接正在进行")) }
        guard let peerBytes = TetherProxyPort.bytes(fromHex: hostEndpointId), peerBytes.count == 32 else {
            throw TetherError.invalidEndpointId(hostEndpointId)
        }
        connecting = true
        let epoch = connectEpoch
        defer { connecting = false }

        isTearingDown = true
        await teardownConnection()
        isTearingDown = false
        setState(.connecting(hostId: hostEndpointId))

        do {
            let tBind = Date()
            let endpoint = try await bindEndpoint()
            // **提前登记**：取消时要能关掉它。iroh 的 `endpoint.connect` 是 FFI 调用、
            // 不响应 Swift 的取消标记，唯一能终止在途建连的手段就是关掉承载它的 endpoint
            //（和 `connectWithCeiling` 里超时那条路同一个道理）。
            self.endpoint = endpoint
            let bindMS = Int(Date().timeIntervalSince(tBind) * 1000)
            let peer = try EndpointId.fromString(s: hostEndpointId)
            logger?.log("连接电脑 \(hostEndpointId.prefix(12))…（preset N0，ALPN \(TetherWire.alpn)）")
            // 寻址信息**自己解析**（见 TetherDiscovery 的说明：iroh 在 iOS 上会退回
            // 硬编码的 8.8.8.8，国内经常查不通）。解析不到就用空地址回落给 iroh 内置发现。
            let address = await resolveAddress(hostEndpointId: hostEndpointId, peer: peer)
            try ensureNotCancelled(epoch: epoch)

            let tConnect = Date()
            // **建连必须有上限。**
            //
            // `endpoint.connect` 本身不设超时。锁屏/切网络之后 iroh 会卡在
            // "等一个永远不会来的打洞结果"里 —— 真机日志实测 **43388ms** 才报
            // `IrohError Connect timed out`。那 43 秒里界面就是「连接中」，
            // 用户只能杀 App。这里给它一个上限，超时后由上层按退避重试
            //（重试通常几百毫秒就成 —— 同一份日志里下一次建连只用 976ms）。
            // **没有寻址信息时快速失败，别耗满 15 秒。**
            //
            // 真机日志（2026-10-19）：`No addressing information available /
            // All address lookup services failed / Service 'dns' failed:
            // Failed to resolve TXT record ×7` —— 手机的 DNS 一时不可用，
            // 而这台电脑的地址完全靠 iroh 的 DNS 发现（`EndpointAddr` 里
            // `addresses: []`、`relayUrl: nil`）。这种情况下 `endpoint.connect`
            // 会一直空转到上限才失败。
            //
            // 遇到这个错误立刻抛出去，让上层按退避快速重试（下一次往往几百毫秒
            // 就连上了 —— DNS 恢复是秒级的）。判据用错误文案里的特征串：
            // iroh 的错误类型是 FFI 生成的，没有更细的可判别字段。
            let connection = try await Self.connectWithCeiling(
                endpoint: endpoint,
                address: address,
                alpn: TetherWire.alpn,
                ceiling: .seconds(15)
            )
            // 超时/取消之后才连上的那条连接没人要，不能留它占着主机侧那唯一一个连接位。
            if epoch != connectEpoch {
                try? connection.close(errorCode: 0, reason: Data())
                throw TetherError.cancelled
            }
            let connectMS = Int(Date().timeIntervalSince(tConnect) * 1000)
            self.endpoint = endpoint
            self.connection = connection

            let tBi = Date()
            let bi = try await connection.openBi()
            // **建连各段耗时留成常驻日志**：用户报过"退后台再回来重连特别慢"，
            // 而这条链路的慢点全在 iroh 那一侧（建 endpoint / 打洞或走中继），
            // 不留下数字的话下次只能再插一遍临时计时。一行、低频，不是噪音。
            logger?.log("建连耗时：iroh 端点 \(bindMS)ms、连接 \(connectMS)ms、控制流 \(Int(Date().timeIntervalSince(tBi) * 1000))ms")
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
                    throw TetherError.transport(String(localized: "配对时收到意外消息：\(other)"))
                case .none:
                    await teardownConnection()
                    throw TetherError.transport(String(localized: "配对应答无法解析：\(reply.prefix(80))"))
                }
            }

            hostId = hostEndpointId
            establishedAt = Date()
            startControlLoop(recv)
            setState(.ready(hostId: hostEndpointId))
            logger?.log("控制流就绪；远端 \(connection.remoteId().description.prefix(12))")
        } catch let error as TetherError {
            await teardownConnection()
            if epoch != connectEpoch { throw TetherError.cancelled }
            throw error
        } catch {
            await teardownConnection()
            if epoch != connectEpoch { throw TetherError.cancelled }
            throw TetherError.transport(error.localizedDescription)
        }
    }

    /// 取消正在进行的建连。退到后台、或被一次新的连接顶掉时调用。
    ///
    /// 只自增代数是不够的：`endpoint.connect` 卡在 FFI 里不会理会 Swift 的取消，
    /// 所以还得把 endpoint 关掉，让在途的建连立刻失败退出。
    func cancelConnect() async {
        connectEpoch &+= 1
        guard connecting else { return }
        logger?.log("取消进行中的建连")
        if let endpoint { try? await endpoint.close() }
        endpoint = nil
    }

    private func ensureNotCancelled(epoch: Int) throws {
        if epoch != connectEpoch { throw TetherError.cancelled }
    }

    /// 解析这台电脑的寻址信息，拼成 iroh 的 `EndpointAddr`。
    ///
    /// 成功时**信息是完整的**（relay + 直连地址），iroh 拿它就能直接拨号，
    /// 不需要走自己的发现流程；失败时退回空地址 —— 那就等于回到改动之前的行为，
    /// 由 iroh 内置发现去试（此时它大概率也会因为 8.8.8.8 不通而失败，但至少不会更差）。
    private func resolveAddress(hostEndpointId: String, peer: EndpointId) async -> EndpointAddr {
        let result = await TetherDiscovery.resolve(hostHexId: hostEndpointId)
        if result.succeeded {
            logger?.log("寻址信息：\(result.detail)")
            return EndpointAddr(
                id: peer,
                relayUrl: result.hint.relayURL,
                addresses: result.hint.addresses
            )
        }
        logger?.log("寻址信息解析失败（\(result.detail)），回退 iroh 内置发现")
        return EndpointAddr(id: peer, relayUrl: nil, addresses: [])
    }

    private func bindEndpoint() async throws -> any EndpointProtocol {
        do {
            return try await Endpoint.bind(options: EndpointOptions(
                preset: presetN0(),                                  // 与电脑端 presets::N0 一致
                secretKey: identity.secretKey.toBytes(),
                alpns: [Data(TetherWire.alpn.utf8)]                  // 与电脑端 ALPN 一致
            ))
        } catch {
            throw TetherError.transport(String(localized: "iroh 端点绑定失败：\(error.localizedDescription)"))
        }
    }

    /// 给 `endpoint.connect` 套一个上限。
    ///
    /// 用 `withThrowingTaskGroup` 而不是 `Task.sleep` 轮询：iroh 的连接一旦成功，
    /// 我们必须**立刻**拿到那个连接对象；超时就取消并抛错，让上层重试。
    ///
    /// 超时后**必须**把那条连接彻底收掉，否则它会泄漏成一条幽灵连接。
    ///
    /// 这里有个踩过的坑（2026-10-19 真机日志：`回到前台重连完成，用时 30073ms`
    /// + `连接超时（15 秒）`，正好是 **2×15 秒**）：`group.cancelAll()` 只是给
    /// Swift 任务打上取消标记，而 `endpoint.connect` 内部是 FFI 调用，
    /// **不会响应取消** —— 它在后台继续打洞、继续连，最后连上了一条没人要的连接。
    /// 主机端同一身份只接受一条连接，于是下一次重连被这条幽灵顶掉，
    /// 又要等一次 15 秒超时，串起来就是 30 秒起步、并且反复失败。
    ///
    /// 所以超时的时候关的不是"半成品连接"（那时它可能还不存在），
    /// 而是**整个 endpoint**：它连带终止其上所有在途的连接尝试。
    /// endpoint 本就是每次连接新建的（`bindEndpoint`），关掉不心疼。
    private static func connectWithCeiling(
        endpoint: any EndpointProtocol,
        address: EndpointAddr,
        alpn: String,
        ceiling: Duration
    ) async throws -> any ConnectionProtocol {
        let gate = TimeoutGate()
        return try await withThrowingTaskGroup(of: (any ConnectionProtocol)?.self) { group in
            group.addTask {
                let connection: any ConnectionProtocol
                do {
                    connection = try await endpoint.connect(addr: address, alpn: Data(alpn.utf8))
                } catch {
                    // 寻址信息缺失（DNS 挂了）是可恢复的、秒级的问题，
                    // 但它会让 connect 空转到上限。识别出来立刻抛，
                    // 让上层马上重试 —— 逐字匹配是唯一的判据，iroh 的错误
                    // 经 FFI 生成后没有可判别的类型字段。
                    let text = String(describing: error)
                    if text.contains("No addressing information") || text.contains("Failed to resolve TXT") {
                        throw TetherError.transport(
                            String(localized: "找不到这台电脑的地址（DNS 暂时不可用），正在重试")
                        )
                    }
                    throw error
                }
                // 超时已经判过负了：这条连接是"迟到的"，必须自己关掉，
                // 不能留着占主机侧那唯一一个连接位。
                if await gate.isExpired {
                    try? connection.close(errorCode: 0, reason: Data())
                    throw TetherError.transport(
                        String(localized: "连接超时（\(ceiling.components.seconds) 秒），正在重试")
                    )
                }
                return connection
            }
            group.addTask {
                try? await Task.sleep(for: ceiling)
                await gate.expire()
                return nil
            }
            defer { group.cancelAll() }
            for try await result in group {
                if let result { return result }
                // 超时分支赢了 → 关掉整个 endpoint，终止所有在途连接。
                try? await endpoint.close()
                throw TetherError.transport(
                    String(localized: "连接超时（\(ceiling.components.seconds) 秒），正在重试")
                )
            }
            throw TetherError.transport(String(localized: "连接未完成"))
        }
    }

    /// 一个只回答"超时了没有"的小闸门，避免"迟到的连接"被当成好连接返回。
    private actor TimeoutGate {
        private(set) var isExpired = false
        func expire() { isExpired = true }
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
                    await self?.controlFailed(String(localized: "电脑端关闭了控制流"))
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
        guard let recv = controlRecv else { throw TetherError.controlClosed(String(localized: "控制流未建立")) }
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
                throw TetherError.transport(String(localized: "等待电脑端应答超时"))
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
            throw TetherError.transport(String(localized: "开代理流失败：\(error.localizedDescription)"))
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
