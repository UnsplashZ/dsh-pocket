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
            try data.write(to: target, options: [.atomic, .completeFileProtectionUnlessOpen])
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
        case failed(String)

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

    private var proxyPort: UInt16?

    /// 诊断页要的东西：走的是 direct 还是 relay、RTT、本地代理端口、控制流是否还活着。
    public func diagnostics() async -> TetherDiagnostics? {
        let base = await proxy?.currentBaseURL()?.absoluteString
        return await link?.diagnostics(proxyPort: proxyPort, proxyURL: base)
    }

    // MARK: 连接

    /// 连上一台电脑并**同时把本地代理起好**。
    /// - Returns: 本地代理基址（`http://127.0.0.1:<port>`），把它交给 DSHKit 即可。
    @discardableResult
    public func connect(hostId: String, pairingCode: String? = nil) async throws -> URL {
        if case .connected(let current, let base) = state, current == hostId, let url = URL(string: base) {
            return url
        }
        state = .connecting(hostId: hostId)

        do {
            let identity = try ensureIdentity()
            let link = TetherLink(identity: identity, name: deviceName, logger: logger)
            self.link = link

            try await link.connect(hostEndpointId: hostId, pairingCode: pairingCode)

            let preferred = TetherProxyPort.port(for: hostId)
            let proxy = LocalProxyServer(factory: link, preferredPort: preferred, logger: logger)
            let base = try await proxy.start()
            self.proxy = proxy
            self.proxyPort = UInt16(base.port ?? 0)

            state = .connected(hostId: hostId, baseURL: base.absoluteString)

            var record = hostBook.host(id: hostId) ?? TetherHostRecord(id: hostId, label: "电脑 \(hostId.prefix(6))")
            record.lastConnectedAt = Date()
            hostBook.upsert(record)
            hostBook.save()

            logger?.log("已连接并起好本地代理：\(base.absoluteString)")
            return base
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            await teardown()
            throw error
        }
    }

    public func disconnect() async {
        await teardown()
        state = .idle
    }

    private func teardown() async {
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
