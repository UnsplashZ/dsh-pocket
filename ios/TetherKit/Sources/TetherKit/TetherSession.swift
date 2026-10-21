import Foundation

/// 已配对主机的持久列表。放在 Application Support 下，`0600`。
public struct TetherHostBook: Sendable, Codable {
    public private(set) var hosts: [TetherHostRecord]

    public init(hosts: [TetherHostRecord] = []) {
        self.hosts = hosts
    }

    public func host(id: String) -> TetherHostRecord? {
        hosts.first { $0.id == id }
    }

    public mutating func upsert(_ record: TetherHostRecord) {
        if let index = hosts.firstIndex(where: { $0.id == record.id }) {
            hosts[index] = record
        } else {
            hosts.append(record)
        }
        hosts.sort { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
    }

    public mutating func remove(id: String) {
        hosts.removeAll { $0.id == id }
    }

    // MARK: 持久化

    public static func load(from url: URL? = nil) -> TetherHostBook {
        let target = url ?? TetherStorage.file("hosts.json")
        guard let data = try? Data(contentsOf: target),
              let book = try? JSONDecoder.dsh.decode(TetherHostBook.self, from: data)
        else { return TetherHostBook() }
        return book
    }

    public func save(to url: URL? = nil) {
        let target = url ?? TetherStorage.file("hosts.json")
        do {
            let data = try JSONEncoder.dshCompact.encode(self)
            // 同 FileSecretStore：`.completeFileProtection*` 在 macOS 上会让文件读不回来。
            try data.write(to: target, options: TetherFileWrite.options)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        } catch {
            // 主机簿写不进去不该让 App 崩溃：退化为"本次会话内有效"。
        }
    }
}

extension JSONDecoder {
    /// 与 DSHKit 一致的日期解码策略（ISO-8601）。
    static let dsh: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension JSONEncoder {
    static let dshCompact: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

/// 传输层对外的**唯一**门面。
///
/// 帮上层把这几件事按正确顺序串起来（docs/TRANSPORT.md §5）：
/// 身份 → 连接（hello / pair）→ 起本地代理 → 拿到一个 `http://127.0.0.1:<派生端口>` 基址。
/// 上层（DSHKit 的用户）只需要这个基址，不需要知道 iroh 存在。
public actor TetherSession {
    public enum State: Sendable, Equatable {
        case idle
        case connecting(hostId: String)
        case connected(hostId: String, baseURL: String)
        /// 失败原因 + **该不该继续重试**。
        ///
        /// 分类必须由传输层给出：只有这里还看得到原始错误类型。上层拿到的是一句
        /// 文案，靠猜文案分不清「DNS 抖一下」和「电脑端不认这台手机了」——
        /// 2026-10-21 的真机日志里 App 就是因为分不清而永久放弃了重连。
        case failed(reason: String, policy: TetherFailurePolicy)

        public var isConnected: Bool { if case .connected = self { return true }; return false }
    }

    private let store: any TetherSecretStore
    private let deviceName: String
    private let logger: (any TetherLogSink)?

    private var identity: TetherIdentity?
    private var link: TetherLink?
    private var proxy: LocalProxyServer?
    private var state: State = .idle
    private var hostBook: TetherHostBook
    private var stateContinuations: [UUID: AsyncStream<State>.Continuation] = [:]
    /// 连接一旦建立就把 hostId 记下来，掉线后监督器要拿它重连。
    private var connectedHostId: String?
    private var isDisconnecting = false
    /// 取消代数。`cancelConnect()` 自增；`connect()` 在几个 await 边界比对它，
    /// 发现自己过时了就抛 `TetherError.cancelled`，而不是当成一次真失败。
    private var connectGeneration = 0
    private var watchdog: Task<Void, Never>?

    public init(
        store: any TetherSecretStore,
        deviceName: String,
        logger: (any TetherLogSink)? = nil
    ) {
        self.store = store
        self.deviceName = deviceName
        self.logger = logger
        self.hostBook = TetherHostBook.load()
    }

    /// 本机（这台手机）的端点 ID —— 配对串的前半段。
    public func localEndpointId() throws -> String {
        try ensureIdentity().endpointId
    }

    private func ensureIdentity() throws -> TetherIdentity {
        if let identity { return identity }
        let loaded = try TetherIdentity.loadOrCreate(store: store)
        identity = loaded
        logger?.log("设备身份 \(loaded.endpointId.prefix(12))…")
        return loaded
    }

    /// 重置设备身份（换新密钥）。换完必须重新配对。
    public func resetIdentity() throws {
        identity = try TetherIdentity.reset(store: store)
    }

    // MARK: 主机簿

    public func hosts() -> [TetherHostRecord] { hostBook.hosts }

    public func renameHost(id: String, label: String) {
        guard var record = hostBook.host(id: id) else { return }
        record.label = label
        hostBook.upsert(record)
        hostBook.save()
    }

    public func forgetHost(id: String) {
        hostBook.remove(id: id)
        hostBook.save()
    }

    // MARK: 状态

    public func currentState() -> State { state }

    /// 连接状态流（含掉线）。订阅时立刻收到当前状态。
    ///
    /// 上层靠它做两件事：拿到新的本地代理基址、以及**在掉线后触发重连**。
    public func states() -> AsyncStream<State> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(state)
            stateContinuations[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.dropStateContinuation(id) }
            }
        }
    }

    private func dropStateContinuation(_ id: UUID) { stateContinuations[id] = nil }

    private func setState(_ next: State) {
        guard state != next else { return }
        state = next
        for continuation in stateContinuations.values { continuation.yield(next) }
    }

    private var proxyPort: UInt16?

    /// 诊断页要的东西：走的是 direct 还是 relay、RTT、本地代理端口、控制流是否还活着。
    public func diagnostics() async -> TetherDiagnostics? {
        let base = await proxy?.currentBaseURL()?.absoluteString
        return await link?.diagnostics(proxyPort: proxyPort, proxyURL: base)
    }

    // MARK: 连接

    /// 连上一台电脑并**同时把本地代理起好**。
    /// - Returns: 本地代理基址（`http://127.0.0.1:<port>`），把它交给 DSHKit 即可。
    /// 首行到底发什么。
    ///
    /// 电脑端是**严格二选一**的（`(paired, hello)` 的 match 只有两条合法分支，
    /// 其余一律 `close(1, b"protocol")`），所以这个决策不能猜、必须有单测：
    ///   · 我们这边记着这台电脑 → `hello`（就算用户又填了一次配对码也一样）；
    ///   · 没记着、但有配对码 → `pair`；
    ///   · 没记着、也没配对码 → 连不上（应该引导用户去配对，而不是发个 hello 撞墙）。
    static func firstMessage(alreadyPaired: Bool, pairingCode: String?) -> TetherFirstMessage? {
        if alreadyPaired { return .hello }
        guard let pairingCode, !pairingCode.isEmpty else { return nil }
        return .pair(code: pairingCode)
    }

    /// 我们是否已经把这台电脑记在主机簿里。
    ///
    /// 这个判断决定了首行发 `hello` 还是 `pair` —— 电脑端是**严格二选一**的，
    /// 对已配对的电脑发 pair 会被判成协议错误并断开。
    public func isPaired(hostId: String) -> Bool {
        hostBook.host(id: hostId) != nil
    }

    @discardableResult
    public func connect(hostId: String, pairingCode: String? = nil) async throws -> URL {
        if case .connected(let current, let base) = state, current == hostId, let url = URL(string: base) {
            return url
        }
        setState(.connecting(hostId: hostId))
        let generation = connectGeneration

        do {
            // 重连前先把上一代的本地代理收掉。
            // 不收的话新监听会撞上旧监听占着的那个派生端口 ——
            // 真机上就是这个报错：`NWError 48 - Address already in use`。
            await proxy?.stop()
            proxy = nil
            proxyPort = nil
            await link?.disconnect()
            link = nil

            let identity = try ensureIdentity()
            let link = TetherLink(identity: identity, name: deviceName, logger: logger)
            self.link = link

            // 首行发什么，由**我们的主机簿**决定，而不是"有没有填配对码"。
            // 已经配对过的电脑只接受 hello；对它发 pair 会被判成协议错误。
            let alreadyPaired = isPaired(hostId: hostId)
            guard let firstMessage = Self.firstMessage(alreadyPaired: alreadyPaired, pairingCode: pairingCode) else {
                throw TetherError.notPaired
            }
            if alreadyPaired, pairingCode != nil {
                logger?.log("这台电脑已经在主机簿里，改发 hello（对已配对的电脑发 pair 会被判成协议错误）")
            }

            try await link.connect(hostEndpointId: hostId, firstMessage: firstMessage)
            // 建连期间退到后台（或被新连接顶掉）：别继续起代理，直接收工。
            try ensureCurrent(generation)

            let preferred = TetherProxyPort.port(for: hostId)
            let proxy = LocalProxyServer(factory: link, preferredPort: preferred, logger: logger)
            let tProxy = Date()
            let base = try await proxy.start()
            try ensureCurrent(generation)
            let proxyMS = Int(Date().timeIntervalSince(tProxy) * 1000)
            self.proxy = proxy
            self.proxyPort = UInt16(base.port ?? 0)

            connectedHostId = hostId
            setState(.connected(hostId: hostId, baseURL: base.absoluteString))

            var record = hostBook.host(id: hostId) ?? TetherHostRecord(id: hostId, label: String(localized: "电脑 \(hostId.prefix(6))"))
            record.lastConnectedAt = Date()
            hostBook.upsert(record)
            hostBook.save()

            startLinkWatchdog(link)
            logger?.log("已连接并起好本地代理（本地代理启动 \(proxyMS)ms）：\(base.absoluteString)")
            return base
        } catch {
            let policy = (error as? TetherError)?.policy ?? .retry
            await teardown()
            if policy == .cancelled {
                // 我们自己取消的：不是故障，别让界面停在「失败」上。
                setState(.idle)
            } else {
                setState(.failed(
                    reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                    policy: policy
                ))
            }
            throw error
        }
    }

    /// 取消正在进行的建连（退到后台、或被一次新的连接顶掉时调用）。
    ///
    /// 只标记不终止是不够的：`link.connect` 里的 iroh 调用不响应 Swift 取消，
    /// 会一直挂着并占着 `connecting` 标志，等它自己超时可能要好几分钟（App 被
    /// 挂起时计时器还停着）。所以这里让 TetherLink 把 endpoint 关掉，立刻打断它。
    public func cancelConnect() async {
        connectGeneration &+= 1
        await link?.cancelConnect()
    }

    private func ensureCurrent(_ generation: Int) throws {
        if generation != connectGeneration { throw TetherError.cancelled }
    }

    public func disconnect() async {
        isDisconnecting = true
        await teardown()
        isDisconnecting = false
        connectedHostId = nil
        setState(.idle)
    }

    /// 控制流断开时由监督器调用：把本地代理收掉并广播"失败"，让上层重连。
    func noteLinkClosed(reason: String) async {
        guard !isDisconnecting, connectedHostId != nil else { return }
        logger?.log("传输断开，准备重连：\(reason)")
        await proxy?.stop()
        proxy = nil
        proxyPort = nil
        await link?.disconnect()
        link = nil
        // 掉线几乎总是网络侧的事（切网络、锁屏、中继被掐），按可重试处理。
        setState(.failed(reason: String(localized: "与电脑的连接断了：\(reason)"), policy: .retry))
    }

    /// 监督器要用的：当前连的是哪台。
    func currentHostId() -> String? { connectedHostId }

    /// 传输是不是真的还活着（控制流 + 本地代理都在）。
    /// 上层用它决定"回到前台要不要重连" —— 无条件重连会把电脑端的连接顶掉。
    public func isTransportHealthy() async -> Bool {
        guard state.isConnected, let link, let proxy else { return false }
        guard await link.isConnected() else { return false }
        return await proxy.currentBaseURL() != nil
    }

    /// 盯着控制流：它一死就广播"失败"，由上层决定何时重连。
    ///
    /// 为什么监督器放在传输层而不是上层：只有这里能直接看到 iroh 连接的死活。
    /// 上层如果靠"请求失败了"来推断，会慢好几拍，而且分不清是网络问题还是电脑没响应。
    private func startLinkWatchdog(_ link: TetherLink) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            for await linkState in await link.states() {
                if Task.isCancelled { return }
                switch linkState {
                case .closed(let reason):
                    await self?.noteLinkClosed(reason: reason)
                    return
                case .idle where !(await link.isConnected()):
                    await self?.noteLinkClosed(reason: String(localized: "连接已关闭"))
                    return
                default:
                    break
                }
            }
        }
    }

    private func teardown() async {
        watchdog?.cancel()
        watchdog = nil
        await proxy?.stop()
        proxy = nil
        proxyPort = nil
        await link?.disconnect()
        link = nil
    }

    /// 电脑端主动发来的消息（审批提醒）。UI 用它触发本地通知。
    public func hostMessages() async -> AsyncStream<TetherHostMessage> {
        guard let link else { return AsyncStream { $0.finish() } }
        return await link.messages()
    }

    /// 告知电脑端我们对某条审批的决定（tether 自己的 `decision` 通道）。
    ///
    /// **注意**（ADR-0007）：真正让 agent 继续跑的是 DSH 原生的 `$events/result`；
    /// 这条消息只是让电脑端插件的状态也同步一下。发不出去不影响功能。
    public func sendDecision(id: String, outcome: String) async {
        guard let link else { return }
        do {
            try await link.sendControl(TetherWire.decision(id: id, outcome: outcome))
        } catch {
            logger?.log("decision 发送失败（不影响原生通道）：\(error.localizedDescription)")
        }
    }
}
