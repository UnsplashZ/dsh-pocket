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

    /// 最近一次送达前台的审批（用于从通知跳回来时高亮）。
    var focusedApprovalId: String?

    // MARK: 内部

    private var eventCoordinator: EventStreamCoordinator?
    private var tetherMessagesTask: Task<Void, Never>?
    private var workspaceTask: Task<Void, Never>?
    private let notifier = NotificationCenterAdapter()

    // MARK: 初始化

    convenience init() {
        self.init(settings: AppSettings())
    }

    init(settings: AppSettings) {
        self.settings = settings
        self.logs = MemoryLogSink(capacity: 2_000, minimumLevel: .debug)

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

        if settings.devDirectEnabled {
            await activateClient(modeLabel: String(localized: "开发直连"))
        } else if let hostId = settings.activeHostId, !hostId.isEmpty {
            await connect(hostId: hostId, pairingCode: nil, silent: true)
        }
    }

    /// 退到前台：iOS 不允许常驻后台连接，所以这里**立即重连**（DESIGN §9）。
    func handleForeground() async {
        guard !settings.devDirectEnabled, let hostId = settings.activeHostId, !hostId.isEmpty else {
            if settings.devDirectEnabled, !connection.isConnected {
                await activateClient(modeLabel: String(localized: "开发直连"))
            }
            return
        }
        if connection.isConnected, muxState.isHealthy { return }
        logs.log(.info, "回到前台，重连")
        await connect(hostId: hostId, pairingCode: nil, silent: true)
    }

    /// 退到后台：断开传输，只保留通知（iOS 上这是正解，别试图保活）。
    func handleBackground() async {
        logs.log(.info, "退到后台，断开传输")
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
        if !settings.devDirectEnabled { connection = .idle }
    }

    // MARK: 连接

    func connect(hostId: String, pairingCode: String?, silent: Bool = false) async {
        connection = .connecting(hostId: hostId)
        if !silent { pendingApprovals.removeAll(); pendingQuestions.removeAll() }
        do {
            let base = try await tether.connect(hostId: hostId, pairingCode: pairingCode)
            coordinator.setRemoteBaseURL(base)
            settings.activeHostId = hostId
            hosts = await tether.hosts()
            await activateClient(modeLabel: String(localized: "远端连接"))
            logs.log(.info, "已连接 \(hostId.prefix(12))…")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            connection = .failed(message)
            logs.log(.error, "连接失败：\(message)")
        }
    }

    func disconnect() async {
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
        await client.closeTransport()
        client = DSHClient(provider: coordinator, logger: logs)
        connection = .connected(mode: modeLabel)

        let coordinator = EventStreamCoordinator(client: client, logger: logs)
        await coordinator.setAnswerer { [weak self] request in
            await self?.route(request)
        }
        await coordinator.setHandler { [weak self] event in
            await self?.observe(event)
        }
        await coordinator.start()
        eventCoordinator = coordinator

        await observeMuxState()
        await observeTetherMessages()
        await observeWorkspace()
        await refreshSessions()
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
        case .baseline(let archived, let pinned, _):
            archivedSessionIds = Set(archived)
            pinnedSessionIds = Set(pinned)
            logs.log(.info, "工作区基线：\(archived.count) 个已归档、\(pinned.count) 个已置顶")
        case .archived(let ids):
            archivedSessionIds = Set(ids)
        case .pinned(let ids):
            pinnedSessionIds = Set(ids)
        case .workspaces, .other:
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
            sessions = try await client.listSessions()
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

    func createSession(cwd: String?) async -> String? {
        do {
            let id = try await client.createSession(cwd: cwd)
            await refreshSessions()
            return id
        } catch {
            sessionListError = (error as? DSHClientError)?.displayMessage ?? error.localizedDescription
            return nil
        }
    }

    // MARK: 主机管理

    func forgetHost(_ id: String) async {
        await tether.forgetHost(id: id)
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

    /// 到期未被处理的审批/提问统一收在这里。返回 `nil` 表示"我不答"，
    /// 协调器会回 `{kind:'next'}`（审批那边最终落到 fail-closed 的 unavailable）。
    private func route(_ request: WaterfallRequest) async -> JSONValue? {
        if request.isApproval {
            guard !pendingApprovals.contains(where: { $0.eventId == request.eventId }) else { return nil }
            pendingApprovals.append(request)
            await notifier.postApproval(toolName: request.approvalToolName, reason: request.approvalReason, eventId: request.eventId)
            return nil   // 等用户决定；由 decide(...) 负责应答
        }
        if request.isUserQuestion {
            guard !pendingQuestions.contains(where: { $0.eventId == request.eventId }) else { return nil }
            pendingQuestions.append(request)
            await notifier.postQuestion(count: request.questions.count, eventId: request.eventId)
            return nil
        }
        return nil
    }

    /// 用户对审批作出了决定。**这是唯一的应答入口**，保证恰好一次。
    func decide(approval request: WaterfallRequest, decision: WaterfallRequest.ApprovalDecision) async {
        pendingApprovals.removeAll { $0.eventId == request.eventId }
        guard let coordinator = eventCoordinator else { return }
        do {
            try await client.answerEvent(
                clientId: await coordinator.currentGeneration()?.clientId ?? "",
                eventId: request.eventId,
                outcome: WaterfallRequest.approvalOutcome(decision)
            )
            logs.log(.info, "审批 \(request.eventId) → \(decision.rawValue)")
        } catch {
            logs.log(.warning, "审批应答失败：\(error)")
        }
    }

    /// 用户回答了提问。批里必须**恰好一次**地命名每个问题。
    func answer(
        question request: WaterfallRequest,
        answers: [(id: String, selected: [String], custom: String?)]
    ) async {
        pendingQuestions.removeAll { $0.eventId == request.eventId }
        guard let coordinator = eventCoordinator else { return }
        do {
            try await client.answerEvent(
                clientId: await coordinator.currentGeneration()?.clientId ?? "",
                eventId: request.eventId,
                outcome: WaterfallRequest.answersOutcome(answers)
            )
            logs.log(.info, "提问 \(request.eventId) 已作答")
        } catch {
            logs.log(.warning, "提问应答失败：\(error)")
        }
    }

    /// 把一条 waterfall 收起来"稍后处理"（UI 层只是把它从当前聚焦移开，仍然欠着应答）。
    func deferApproval(_ request: WaterfallRequest) {
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
}
