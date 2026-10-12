import DSHKit
import Foundation
import Observation
import SwiftUI
import TetherKit
import UserNotifications

/// App 的根状态。
///
/// 单向数据流（docs/IOS-DESIGN.md §2）：Store 持状态 → View 只读渲染 → 事件回到 Store。
/// 协议层（DSHKit）与传输层（TetherKit）都不认识 SwiftUI。
@MainActor
@Observable
public final class AppModel {
    // MARK: 依赖

    let settings: AppSettings
    let logs: MemoryLogSink

    private let tether: TetherSession
    /// 会话内容的磁盘缓存。切换会话时先用它铺内容，再跟 `session/follow` 对齐。
    let sessionCache: SessionCache
    private let coordinator: HostCoordinator
    private(set) var client: DSHClient

    // MARK: 连接状态

    enum Connection: Equatable {
        case idle
        case connecting(hostId: String)
        case connected(mode: String)
        case failed(String)

        var isConnected: Bool { if case .connected = self { return true }; return false }

        var label: String {
            switch self {
            case .idle: return String(localized: "未连接")
            case .connecting: return String(localized: "连接中…")
            case .connected(let mode): return mode
            case .failed: return String(localized: "连接失败")
            }
        }
    }

    private(set) var connection: Connection = .idle
    private(set) var diagnostics: TetherDiagnostics?
    private(set) var muxState: MuxClient.MuxState = .idle

    /// 用户打开通知开关时才请求系统授权（HIG：不在启动时弹）。
    func requestNotificationAuthorization() async -> Bool {
        await notifier.requestAuthorization()
    }

    // MARK: 会话列表

    /// 全部会话（含已归档）。列表页只显示未归档的那些。
    private(set) var sessions: [SessionSummary] = []
    /// 已归档的会话 ID。**只有 `workspace/follow` 会告诉你这个** —— `session/list` 里没有。
    private(set) var archivedSessionIds: Set<String> = []
    private(set) var pinnedSessionIds: Set<String> = []
    /// 全部工作区，来自 `workspace/follow` 的 baseline。
    ///
    /// **不能从会话反推** —— 那样会漏掉"已添加但还没有会话"的工作区
    /// （用户实测：`chat-bot` 只有频道会话，就在新建会话的列表里消失了）。
    private(set) var workspaces: [WorkspaceSummary] = []
    private(set) var isLoadingSessions = false
    private(set) var sessionListError: String?
    private(set) var lastRefreshedAt: Date?

    // MARK: 主机

    private(set) var hosts: [TetherHostRecord] = []
    private(set) var localEndpointId: String = ""

    // MARK: 待处理的 waterfall

    /// 等用户决定的审批/提问。**App 永不自动决策**（IOS-DESIGN §4 S4）。
    private(set) var pendingApprovals: [WaterfallRequest] = []
    private(set) var pendingQuestions: [WaterfallRequest] = []
    /// 某条 waterfall 属于哪个会话（用于"来自「某某」"）。
    ///
    /// 待处理横幅是**全局**的 —— 你在首页时它也会亮。所以每一条都必须说清
    /// 自己属于哪个会话，否则用户知道"有人在等"，但不知道该去哪儿。
    func sessionTitle(for sessionId: String) -> String? {
        guard !sessionId.isEmpty else { return nil }
        return sessions.first { $0.sessionId == sessionId }?.title
    }

    /// 连接换代导致待处理作废时给用户的一句说明。
    var waterfallAbandonedMessage: String?

    /// 一条审批/提问的**身份**：哪个会话的哪件事。
    ///
    /// 用它而不是 `eventId` 去重 —— 宿主重放未决 waterfall 时会换新的 `eventId`。
    private struct ApprovalKey: Hashable {
        var sessionId: String
        var callId: String
    }

    /// 已经摆到界面上（或已经处理过）的审批/提问。清空的时机见 `activateClient`。
    private var handledApprovalKeys: Set<ApprovalKey> = []
    private var handledQuestionKeys: Set<ApprovalKey> = []

    /// 最近一次送达前台的审批（用于从通知跳回来时高亮）。
    var focusedApprovalId: String?

    // MARK: 内部

    private var eventCoordinator: EventStreamCoordinator?
    private var tetherMessagesTask: Task<Void, Never>?
    private var workspaceTask: Task<Void, Never>?
    private var transportSupervisor: Task<Void, Never>?
    private var listRefreshLoop: Task<Void, Never>?
    /// 传输世代：每次重建 client 自增。打开着的会话页据此**立刻**重订阅，
    /// 而不是等自己那套退避重试慢慢转过来。
    private(set) var transportGeneration = 0
    private var generationContinuations: [UUID: AsyncStream<Int>.Continuation] = [:]
    private var reconnectAttempt = 0
    private var isBackgrounded = false
    /// 连续几次传输失败。用来把"电脑端已经不认这台手机了"这种需要人工介入的
    /// 情况和普通网络抖动区分开 —— 后者重试就好，前者要用户去删掉主机记录重新配对。
    private var consecutiveTransportFailures = 0
    private let notifier = NotificationCenterAdapter()

    // MARK: 初始化

    convenience init() {
        self.init(settings: AppSettings())
    }

    init(settings: AppSettings) {
        self.settings = settings
        self.logs = MemoryLogSink(capacity: 2_000, minimumLevel: .debug)
        self.sessionCache = SessionCache()

        let tether = TetherSession(
            store: Self.makeSecretStore(),
            deviceName: settings.sanitizedDisplayName,
            logger: TetherLogAdapter(sink: logs)
        )
        self.tether = tether
        self.coordinator = HostCoordinator(settings: settings, session: tether)
        self.client = DSHClient(provider: coordinator, logger: logs)
    }

    /// 真机用 Keychain；模拟器/命令行没有签名上下文时退回文件。
    private static func makeSecretStore() -> any TetherSecretStore {
        #if targetEnvironment(simulator)
        return FileSecretStore()
        #else
        return KeychainSecretStore()
        #endif
    }

    // MARK: 生命周期

    func start() async {
        logs.log(.info, "DSH Pocket 启动")
        localEndpointId = (try? await tether.localEndpointId()) ?? ""
        hosts = await tether.hosts()
        await notifier.configure()
        // 冷启动第一屏：先用缓存里的列表，再等 `session/list` 校准。
        if sessions.isEmpty, let cached = await sessionCache.sessionList() {
            sessions = DSHClient.decodeSessionList(cached)
            if !sessions.isEmpty { logs.log(.info, "会话列表来自缓存（\(sessions.count) 条）") }
        }
        startTransportSupervisor()

        if settings.transportMode != .remote {
            // 直连网关：不需要 iroh，直接就能用。
            await activateClient(modeLabel: coordinator.mode.label)
        } else if let hostId = settings.activeHostId, !hostId.isEmpty {
            await connect(hostId: hostId, pairingCode: nil, silent: true)
        }
    }

    /// 退到前台：iOS 不允许常驻后台连接，所以这里**立即重连**（DESIGN §9）。
    func handleForeground() async {
        isBackgrounded = false
        guard settings.transportMode == .remote else {
            // 直连网关没有 iroh 连接要恢复，只要 client 还在就继续用。
            if !connection.isConnected { await activateClient(modeLabel: coordinator.mode.label) }
            return
        }
        guard let hostId = settings.activeHostId, !hostId.isEmpty else { return }
        // 只有"确实没连着"才重连：之前每次回到前台都无条件重建一条 iroh 连接，
        // 电脑端会把前一条顶掉（日志里是 closed by peer: 0），看起来就是"连一会就断"。
        if await tether.isTransportHealthy() { return }
        logs.log(.info, "回到前台，传输不健康，重连")
        await connect(hostId: hostId, pairingCode: nil, silent: true)
    }

    /// 退到后台：断开传输，只保留通知（iOS 上这是正解，别试图保活）。
    func handleBackground() async {
        isBackgrounded = true
        logs.log(.info, "退到后台，断开传输")
        listRefreshLoop?.cancel()
        listRefreshLoop = nil
        await eventCoordinator?.stop()
        eventCoordinator = nil
        workspaceTask?.cancel()
        workspaceTask = nil
        tetherMessagesTask?.cancel()
        tetherMessagesTask = nil
        await client.closeTransport()
        await tether.disconnect()
        coordinator.setRemoteBaseURL(nil)
        // 后台不保留"已连接"的外观：宁可显示未连接，也不做"假在线"。
        if settings.transportMode == .remote { connection = .idle }
    }

    // MARK: 连接

    /// 连上电脑。**返回错误文案**（`nil` 表示成功）。
    ///
    /// 返回结果而不是让调用方去读 `connection`：状态流是异步更新的，
    /// 调用方立刻读会读到还没更新的旧值。配对页之前就是这么错的 ——
    /// 明明连上了却显示"连接没有完成，请再试一次"，用户再点一次就发了第二个
    /// `pair`，被电脑端判成协议错误。
    @discardableResult
    func connect(hostId: String, pairingCode: String?, silent: Bool = false) async -> String? {
        // 重入保护：一次只允许一条连接在建立。电脑端同一身份只接受一条连接，
        // 并发建连会把彼此顶掉。
        guard !isConnecting else { return String(localized: "上一次连接还在进行中") }
        isConnecting = true
        defer { isConnecting = false }

        connection = .connecting(hostId: hostId)
        if !silent {
            pendingApprovals.removeAll()
            pendingQuestions.removeAll()
            // 去重集合也要一起清 —— 连接重建之后宿主会重放未决的那些，
            // 不清的话重放会被当成"已处理"而丢掉，用户就再也答不上了。
            handledApprovalKeys.removeAll()
            handledQuestionKeys.removeAll()
        }
        do {
            _ = try await tether.connect(hostId: hostId, pairingCode: pairingCode)
            // 真正把 client 接上去的是状态流里的 .connected 分支 ——
            // 这样"首次连接"和"掉线重连"走的是同一条路。
            settings.activeHostId = hostId
            hosts = await tether.hosts()
            consecutiveTransportFailures = 0
            return nil
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            connection = .failed(message)
            logs.log(.error, "连接失败：\(message)")
            return message
        }
    }

    private var isConnecting = false

    /// 传输世代变化流。会话页订阅它，重连后立刻重订阅会话流。
    func generationUpdates() -> AsyncStream<Int> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(transportGeneration)
            generationContinuations[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.dropGenerationContinuation(id) }
            }
        }
    }

    private func dropGenerationContinuation(_ id: UUID) { generationContinuations[id] = nil }

    /// 前台期间**轻量定时刷新**会话列表。
    ///
    /// 为什么不只靠 `$events`：实测 `$events` 在 30 秒里只发了 `ready`，
    /// 一条 `api-session/*` 都没有 —— 会话在电脑上被更新时列表并不会因此刷新。
    /// `session/list` 只读投影、很便宜，20 秒一次足够"半实时"，
    /// 又不会像开流那样耗电。
    private func startListRefreshLoop() {
        listRefreshLoop?.cancel()
        listRefreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, let self else { return }
                let shouldRefresh = await MainActor.run {
                    !self.isBackgrounded && self.connection.isConnected
                }
                guard shouldRefresh else { continue }
                await self.refreshSessions()
            }
        }
    }

    /// 用户在设置里改了连接方式/地址之后，按当前配置重建一次。
    func activateConfiguredTransport() async {
        if settings.transportMode == .remote {
            guard let hostId = settings.activeHostId, !hostId.isEmpty else { return }
            await connect(hostId: hostId, pairingCode: nil, silent: true)
        } else {
            coordinator.setRemoteBaseURL(nil)
            await activateClient(modeLabel: coordinator.mode.label)
        }
    }

    // MARK: 传输监督

    /// 订阅传输层状态：拿到（可能是新的）本地代理基址就重建 client，
    /// 掉线就按退避重连。
    ///
    /// 这是"连上一会儿就断、然后永远连不回来"的正解：控制流死掉之后 iroh 不会自己回来，
    /// 必须有人在传输层之外把它重新拉起来。
    private func startTransportSupervisor() {
        transportSupervisor?.cancel()
        transportSupervisor = Task { [weak self] in
            guard let self else { return }
            for await state in await self.tether.states() {
                if Task.isCancelled { return }
                await self.handle(transportState: state)
            }
        }
    }

    private func handle(transportState state: TetherSession.State) async {
        switch state {
        case .connected(let hostId, let baseURL):
            reconnectAttempt = 0
            guard let url = URL(string: baseURL) else { return }
            coordinator.setRemoteBaseURL(url)
            settings.activeHostId = hostId
            await activateClient(modeLabel: String(localized: "远端连接"))
            logs.log(.info, "传输就绪 \(hostId.prefix(12))… → \(baseURL)")

        case .failed(let reason):
            consecutiveTransportFailures += 1
            connection = .failed(transportFailureMessage(base: reason))
            logs.log(.warning, "传输断开（第 \(consecutiveTransportFailures) 次）：\(reason)")
            await scheduleTransportReconnect()

        case .idle:
            if settings.transportMode == .remote { connection = .idle }

        case .connecting:
            connection = .connecting(hostId: settings.activeHostId ?? "")
        }
    }

    /// 反复失败到一定次数就换一句**可执行**的话。
    ///
    /// 这个场景真的会发生：电脑端的配对白名单被清过（重装插件、换 data-dir），
    /// 而这台手机还记着旧记录。此时 App 会一直发 hello，电脑端一直以
    /// `protocol` 关掉 —— 光看"连接失败"用户无从下手。
    private func transportFailureMessage(base: String) -> String {
        guard consecutiveTransportFailures >= 3 else { return base }
        return String(
            format: String(localized: "%@\n连续失败 %lld 次。如果电脑端重装过插件或清过配对数据，请在「设置 → 主机」里删掉这台电脑，然后重新配对。"),
            base,
            consecutiveTransportFailures
        )
    }

    private func scheduleTransportReconnect() async {
        guard !isBackgrounded, settings.transportMode == .remote else { return }
        // 连续失败太多就别再无脑重试了：这多半需要用户动手（重新配对），
        // 一直重试只会刷日志、耗电。
        guard consecutiveTransportFailures <= 6 else {
            logs.log(.warning, "连续失败已达 \(consecutiveTransportFailures) 次，暂停自动重连")
            return
        }
        guard let hostId = settings.activeHostId, !hostId.isEmpty else { return }
        reconnectAttempt += 1
        let wait = RetryPolicy.default.delay(afterAttempt: reconnectAttempt)
        logs.log(.info, "\(wait.formatted) 后重连电脑（第 \(reconnectAttempt) 次）")
        try? await Task.sleep(for: wait)
        guard !Task.isCancelled, !isBackgrounded else { return }
        await connect(hostId: hostId, pairingCode: nil, silent: true)
    }

    func disconnect() async {
        transportSupervisor?.cancel()
        transportSupervisor = nil
        listRefreshLoop?.cancel()
        listRefreshLoop = nil
        reconnectAttempt = 0
        await eventCoordinator?.stop()
        eventCoordinator = nil
        workspaceTask?.cancel()
        workspaceTask = nil
        tetherMessagesTask?.cancel()
        tetherMessagesTask = nil
        await client.closeTransport()
        await tether.disconnect()
        coordinator.setRemoteBaseURL(nil)
        connection = .idle
        diagnostics = nil
        sessions = []
        archivedSessionIds = []
        pinnedSessionIds = []
        pendingApprovals.removeAll()
        pendingQuestions.removeAll()
    }

    /// 换一个 DSHClient（因为 provider 在模式切换时不换，但连接状态换了）。
    private func activateClient(modeLabel: String) async {
        // 先把上一代彻底拆掉：旧 client 的 WS、旧的事件世代、旧的工作区流
        // 都要收干净，否则重连后会同时存在两条流。
        await eventCoordinator?.stop()
        eventCoordinator = nil
        workspaceTask?.cancel()
        workspaceTask = nil
        await client.closeTransport()
        client = DSHClient(provider: coordinator, logger: logs)
        connection = .connected(mode: modeLabel)

        let coordinator = EventStreamCoordinator(client: client, logger: logs)
        await coordinator.setAnswerer { [weak self] request in
            // `self` 没了就没人在意这条 —— 交回宿主自己的默认实现。
            await self?.route(request) ?? .next
        }
        await coordinator.setAbandonmentHandler { [weak self] requests in
            await self?.handleAbandonedWaterfalls(requests)
        }
        await coordinator.setHandler { [weak self] event in
            await self?.observe(event)
        }
        await coordinator.start()
        eventCoordinator = coordinator

        transportGeneration &+= 1
        for continuation in generationContinuations.values { continuation.yield(transportGeneration) }

        await observeMuxState()
        await observeTetherMessages()
        await observeWorkspace()
        await refreshSessions()
        startListRefreshLoop()
    }

    /// 订阅工作区流：归档/置顶集合只有这一条路能拿到。
    /// 它掉线不影响聊天（列表页仍然能用），所以失败只记日志、自己重订阅。
    private func observeWorkspace() async {
        workspaceTask?.cancel()
        workspaceTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    for try await frame in self.client.workspaceFollow() {
                        if Task.isCancelled { return }
                        await self.apply(workspaceFrame: frame)
                        attempt = 0
                    }
                } catch {
                    if Task.isCancelled { return }
                    await self.noteWorkspaceStreamFailure(error)
                }
                if Task.isCancelled { return }
                attempt += 1
                try? await Task.sleep(for: RetryPolicy.default.delay(afterAttempt: attempt))
            }
        }
    }

    private func apply(workspaceFrame frame: WorkspaceFrame) async {
        switch frame {
        case .baseline(let archived, let pinned, let workspaces):
            archivedSessionIds = Set(archived)
            pinnedSessionIds = Set(pinned)
            self.workspaces = workspaces.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            logs.log(.info, "工作区基线：\(self.workspaces.count) 个工作区、\(archived.count) 个已归档")
        case .archived(let ids):
            archivedSessionIds = Set(ids)
        case .pinned(let ids):
            pinnedSessionIds = Set(ids)
        case .workspaces(let upserted):
            for workspace in upserted {
                if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
                    workspaces[index] = workspace
                } else {
                    workspaces.append(workspace)
                }
            }
            workspaces.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .order(let ids):
            workspaces.sort { lhs, rhs in
                (ids.firstIndex(of: lhs.id) ?? .max) < (ids.firstIndex(of: rhs.id) ?? .max)
            }
        case .other:
            break
        }
    }

    private func noteWorkspaceStreamFailure(_ error: any Error) async {
        logs.log(.warning, "工作区流断开：\(error.localizedDescription)")
    }

    private func observeMuxState() async {
        let stream = await client.muxStates()
        Task { [weak self] in
            for await state in stream {
                await MainActor.run { self?.muxState = state }
            }
        }
    }

    /// tether 自己的 `approval` 消息：**只用来触发本地通知**，决策仍走原生通道（ADR-0007）。
    private func observeTetherMessages() async {
        tetherMessagesTask?.cancel()
        let messages = await tether.hostMessages()
        tetherMessagesTask = Task { [weak self] in
            for await message in messages {
                guard let self else { return }
                if case .approval(_, let toolName, let reason) = message {
                    await self.notifyApprovalHint(toolName: toolName, reason: reason)
                }
            }
        }
    }

    // MARK: 会话列表

    func refreshSessions() async {
        guard connection.isConnected else { return }
        isLoadingSessions = true
        defer { isLoadingSessions = false }
        do {
            let value = try await client.listSessionsValue()
            sessions = DSHClient.decodeSessionList(value)
            await sessionCache.store(sessionList: value)
            sessionListError = nil
            lastRefreshedAt = Date()
        } catch {
            let message = (error as? DSHClientError)?.displayMessage ?? error.localizedDescription
            sessionListError = message
            logs.log(.warning, "拉会话列表失败：\(message)")
        }
    }

    /// 未归档的会话 —— 列表页只显示这些。
    var activeSessions: [SessionSummary] {
        SessionPartition.active(sessions, archived: archivedSessionIds)
    }

    /// 指定范围内、未归档的会话。列表页用它。
    func scopedSessions(_ scope: SessionScope, workspace: String? = nil) -> [SessionSummary] {
        SessionPartition.inScope(activeSessions, scope: scope, workspace: workspace)
    }

    /// 当前存在的所有工作区名（用于筛选）。
    var workspaceNames: [String] {
        let names = Set(activeSessions.filter { !$0.category.isChannel }.map(\.workspaceName))
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// 一个可新建会话的工作区目标。
    struct WorkspaceTarget: Identifiable, Hashable, Sendable {
        /// 工作区的稳定 id。`session/create` 要的就是它。
        public var id: String { workspaceId }
        public var name: String
        public var cwd: String
        public var workspaceId: String
        public var sessionCount: Int
    }

    /// 新建会话的可选工作区。
    ///
    /// `session/create` 的 `cwd` **必须是绝对路径** —— 传显示用的 basename 会被拒：
    /// `session header cwd must be an absolute path, got "dsh-pocket"`。
    /// 之前这里就是传 basename，所以"选完工作区没反应"。
    var workspaceTargets: [WorkspaceTarget] {
        workspaces.map { workspace in
            WorkspaceTarget(
                name: workspace.title,
                cwd: workspace.path,
                workspaceId: workspace.id,
                sessionCount: workspace.sessionIds.count
            )
        }
    }

    /// 已归档的会话 —— 统一在设置里管理，不混进对话列表。
    var archivedSessions: [SessionSummary] {
        SessionPartition.archived(sessions, archived: archivedSessionIds)
    }

    /// 归档一个会话。
    ///
    /// `stopActivity` 对应宿主的一个硬规则：**有活跃 turn 或 job 的会话会被拒绝归档**
    /// （错误码 `workspace/session-active`，本机实测）。所以 UI 在会话正在跑时要先问一句，
    /// 用户同意才带 `stopActivity: true` —— 而不是悄悄把他的任务停掉。
    func archive(_ sessionId: String, stopActivity: Bool = false) async {
        do {
            // 宿主返回**完整**的已归档集合，直接采纳，不要自己维护增量。
            archivedSessionIds = Set(try await client.archiveSession(sessionId: sessionId, stopActivity: stopActivity))
            sessions.removeAll { $0.sessionId == sessionId }
        } catch let error as DSHClientError {
            sessionListError = archiveFailureMessage(error)
        } catch {
            sessionListError = error.localizedDescription
        }
    }

    /// 归档失败的文案：`workspace/session-active` 是唯一需要特殊处理的一种 ——
    /// 它是"可执行的失败"，要告诉用户下一步做什么。
    private func archiveFailureMessage(_ error: DSHClientError) -> String {
        if case .remote(let remote) = error, remote.code == "workspace/session-active" {
            return String(localized: "这个会话正在跑，DSH 不允许直接归档。先停下它再归档。")
        }
        return error.displayMessage
    }

    func unarchive(_ sessionId: String) async {
        do {
            archivedSessionIds = Set(try await client.unarchiveSession(sessionId: sessionId))
            await refreshSessions()
        } catch {
            sessionListError = (error as? DSHClientError)?.displayMessage ?? error.localizedDescription
        }
    }

    func rename(_ sessionId: String, title: String) async {
        do {
            try await client.rename(sessionId: sessionId, title: title)
            await refreshSessions()
        } catch {
            sessionListError = (error as? DSHClientError)?.displayMessage ?? error.localizedDescription
        }
    }

    /// 在指定工作区里建会话。
    ///
    /// 传 `workspaceId`（不是 cwd）—— 只传 cwd 建出来的会话在电脑端会落进「未分组」。
    func createSession(workspaceId: String?, cwd: String?) async -> String? {
        do {
            let id = try await client.createSession(workspaceId: workspaceId, cwd: workspaceId == nil ? cwd : nil)
            await refreshSessions()
            // 新会话在 `session/list` 里可能晚一拍才出现。等一小会儿再找，
            // 找不到就直接把 id 交给调用方（它能自己合成一个占位会话去打开）。
            for _ in 0..<6 {
                if sessions.contains(where: { $0.sessionId == id }) { return id }
                try? await Task.sleep(for: .milliseconds(250))
                await refreshSessions()
            }
            logs.log(.info, "新会话 \(id.prefix(12))… 还没出现在列表里，直接用 id 打开")
            return id
        } catch {
            sessionListError = (error as? DSHClientError)?.displayMessage ?? error.localizedDescription
            return nil
        }
    }

    /// 按 id 找一个会话；列表里还没有就合成一个最小可用的，保证"新建后立刻能进去"。
    func sessionSummary(for id: String, cwd: String?) -> SessionSummary? {
        if let existing = sessions.first(where: { $0.sessionId == id }) { return existing }
        return SessionSummary.placeholder(sessionId: id, cwd: cwd)
    }

    /// 缓存现状（诊断页显示）。
    func cacheStatistics() async -> (sessions: Int, bytes: Int) {
        await sessionCache.statistics()
    }

    func clearSessionCache() async {
        await sessionCache.clear()
        logs.log(.info, "已清空会话缓存")
    }

    // MARK: 主机管理

    func forgetHost(_ id: String) async {
        await tether.forgetHost(id: id)
        consecutiveTransportFailures = 0
        hosts = await tether.hosts()
        if settings.activeHostId == id {
            settings.activeHostId = nil
            await disconnect()
        }
    }

    func renameHost(_ id: String, label: String) async {
        await tether.renameHost(id: id, label: label)
        hosts = await tether.hosts()
    }

    func refreshDiagnostics() async {
        diagnostics = await tether.diagnostics()
    }

    // MARK: waterfall 路由

    /// 到期未被处理的审批/提问统一收在这里。
    ///
    /// 这两种都是"用户还没决定" → **必须返回 `.deferred`**，让协调器把 waterfall 挂着。
    /// 返回 `.next`（或以前那个表示"我不答"的 `nil`）会让宿主立刻收到 `next` 并结案，
    /// 用户在界面上点提交就成了摆设 —— 这正是"提问支持得不好"的根因。
    private func route(_ request: WaterfallRequest) async -> WaterfallDecision {
        // 去重按"**哪条**待处理"，不是按 `eventId`。
        //
        // 宿主会把未决的 waterfall **重放**给新客户端（比如 $events 重连之后），
        // 重放带的是**新的 eventId** —— 按 eventId 去重的话，同一个问题会在界面上
        // 变成两张卡片，而且用户很可能点中那张早就作废的。
        if request.isApproval {
            let key = ApprovalKey(sessionId: request.agentId, callId: request.approvalCallId ?? request.eventId)
            guard !handledApprovalKeys.contains(key) else { return .deferred }
            handledApprovalKeys.insert(key)
            pendingApprovals.append(request)
            await notifier.postApproval(toolName: request.approvalToolName, reason: request.approvalReason, eventId: request.eventId)
            return .deferred
        }
        if request.isUserQuestion {
            let key = ApprovalKey(
                sessionId: request.agentId,
                callId: request.questions.map(\.id).sorted().joined(separator: ",")
            )
            guard !handledQuestionKeys.contains(key) else { return .deferred }
            handledQuestionKeys.insert(key)
            pendingQuestions.append(request)
            await notifier.postQuestion(count: request.questions.count, eventId: request.eventId)
            return .deferred
        }
        return .next
    }

    /// 连接换代时，那些再也答不了的卡片要撤掉并如实告知 ——
    /// 否则用户会对着一个"点了没反应"的卡片反复点。
    private func handleAbandonedWaterfalls(_ requests: [WaterfallRequest]) async {
        let approvals = requests.filter(\.isApproval).map(\.eventId)
        let questions = requests.filter(\.isUserQuestion).map(\.eventId)
        pendingApprovals.removeAll { approvals.contains($0.eventId) }
        pendingQuestions.removeAll { questions.contains($0.eventId) }
        // 作废的那些不该再挡住重放
        handledApprovalKeys = handledApprovalKeys.filter { key in
            !requests.contains { $0.isApproval && $0.agentId == key.sessionId }
        }
        handledQuestionKeys = handledQuestionKeys.filter { key in
            !requests.contains { $0.isUserQuestion && $0.agentId == key.sessionId }
        }
        guard !requests.isEmpty else { return }
        waterfallAbandonedMessage = String(localized: "连接中断过，\(requests.count) 条待处理已经作废 —— 电脑端会按默认方式继续。")
        logs.log(.warning, "连接换代，\(requests.count) 条 waterfall 作废")
    }

    /// 用户对审批作出了决定。**这是唯一的应答入口**，保证恰好一次。
    func decide(approval request: WaterfallRequest, decision: WaterfallRequest.ApprovalDecision) async {
        pendingApprovals.removeAll { $0.eventId == request.eventId }
        guard let coordinator = eventCoordinator else { return }
        await coordinator.respond(request, outcome: WaterfallRequest.approvalOutcome(decision))
        logs.log(.info, "审批 \(request.eventId) → \(decision.rawValue)")
    }

    /// 用户回答了提问。批里必须**恰好一次**地命名每个问题。
    func answer(
        question request: WaterfallRequest,
        answers: [(id: String, selected: [String], custom: String?)]
    ) async {
        pendingQuestions.removeAll { $0.eventId == request.eventId }
        guard let coordinator = eventCoordinator else { return }
        // 交给协调器发：只有它知道这条 waterfall 是不是还挂着。
        await coordinator.respond(request, outcome: WaterfallRequest.answersOutcome(answers))
        logs.log(.info, "提问 \(request.eventId) 已作答")
    }

    /// 用户明确不回答这个问题。
    ///
    /// 走**拒绝**而不是"交给下一个"：后者会让宿主一直等一个永远不来的回答，
    /// agent 只能挂到超时。拒绝会立刻把"用户跳过了"这个事实交给 agent。
    func decline(question request: WaterfallRequest) async {
        pendingQuestions.removeAll { $0.eventId == request.eventId }
        guard let coordinator = eventCoordinator else { return }
        await coordinator.respond(
            request,
            outcome: WaterfallRequest.rejectionOutcome(
                name: "UserSkippedQuestion",
                message: String(localized: "用户跳过了这个问题，没有作答。")
            )
        )
        logs.log(.info, "提问 \(request.eventId) 被用户跳过")
    }

    /// 把一条 waterfall 收起来"稍后处理"（UI 层只是把它从当前聚焦移开，仍然欠着应答）。
    /// 把审批卡片收起来"稍后处理"。
    ///
    /// **不动 waterfall** —— 它仍然挂着，等用户回来。以前这里收一个 `WaterfallRequest`
    /// 参数却什么都没做（调用方还得编一个 `WaterfallPlaceholder` 来凑），现在直接说清语义。
    func deferApproval() {
        focusedApprovalId = nil
    }

    private func observe(_ event: HostEvent) async {
        switch event {
        case .ready(let clientId, _):
            logs.log(.info, "$events 世代 \(clientId.prefix(8))…")
        case .emit(let name, _):
            // 会话增删改这类通知：轻量刷新列表，不重开流。
            if name.hasPrefix("api-session/") {
                await refreshSessions()
            }
        case .waterfall:
            break
        }
    }

    private func notifyApprovalHint(toolName: String, reason: String) async {
        guard settings.notifications.approvals else { return }
        await notifier.postTetherHint(toolName: toolName, reason: reason)
    }
}

// MARK: - 适配器

/// 把 TetherKit 的日志接到同一个缓冲里。
private struct TetherLogAdapter: TetherLogSink {
    let sink: MemoryLogSink
    func log(_ message: String) { sink.log(.debug, "[tether] \(message)") }
}

/// 本地通知。
///
/// 一期只用**本地**通知：App 在后台仍可收到（只要进程未被回收）。
/// APNs 需要付费账号，列为后续增强（DESIGN §9）。
actor NotificationCenterAdapter {
    private var isAuthorized = false

    func configure() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    /// **只在用户打开开关时才请求授权**（HIG：不要在启动时弹）。
    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            isAuthorized = granted
            return granted
        } catch {
            return false
        }
    }

    func postApproval(toolName: String, reason: String, eventId: String) async {
        guard isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "有一条操作在等你批准")
        content.body = reason.isEmpty ? toolName : "\(toolName)：\(reason)"
        content.sound = .default
        content.userInfo = ["approvalId": eventId]
        await deliver(content, identifier: "approval-\(eventId)")
    }

    func postQuestion(count: Int, eventId: String) async {
        guard isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "电脑在等你回答")
        content.body = String(format: String(localized: "%lld 个问题"), count)
        content.sound = .default
        content.userInfo = ["questionId": eventId]
        await deliver(content, identifier: "question-\(eventId)")
    }

    func postTetherHint(toolName: String, reason: String) async {
        guard isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "电脑端提示：有操作待批准")
        content.body = reason.isEmpty ? toolName : "\(toolName)：\(reason)"
        await deliver(content, identifier: "hint-\(UUID().uuidString)")
    }

    private func deliver(_ content: UNMutableNotificationContent, identifier: String) async {
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

extension MuxClient.MuxState {
    var isHealthy: Bool { if case .connected = self { return true }; return false }
}


/// 会话按"归档与否"分流。
///
/// 抽成纯函数是为了能单测：归档集合来自 `workspace/follow`，会话列表来自
/// `session/list`，两条流到达顺序不定 —— 分流规则错了的表现是"归档了还在列表里"
/// 或者"刚恢复就消失"，都不是能靠肉眼稳定复现的。
enum SessionPartition {
    static func active(_ sessions: [SessionSummary], archived: Set<String>) -> [SessionSummary] {
        sessions.filter { !archived.contains($0.sessionId) }
    }

    static func archived(_ sessions: [SessionSummary], archived: Set<String>) -> [SessionSummary] {
        sessions
            .filter { archived.contains($0.sessionId) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 按范围分流，并按工作区筛选。
    ///
    /// 子代理会话**永远不进列表** —— 官方工作区 UI 也是这么做的
    /// （`if (session.origin === "subagent") return false`）。它们由父会话
    /// 时间线里的那张卡承载，混进主列表只会把真正在用的会话淹掉。
    static func inScope(
        _ sessions: [SessionSummary],
        scope: SessionScope,
        workspace: String? = nil
    ) -> [SessionSummary] {
        sessions.filter { summary in
            guard !summary.category.isSubagent else { return false }
            guard scope.matches(summary.category) else { return false }
            if let workspace, !workspace.isEmpty {
                return summary.workspaceName == workspace
            }
            return true
        }
    }
}
