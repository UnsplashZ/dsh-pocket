import Foundation

/// `$events` 的连接管理：世代跟踪 + waterfall 的**恰好一次应答**保证。
///
/// 为什么需要一个专门的类型：`$events` 的首帧 `ready` 绑定**世代**（`clientId`）。
/// 宿主侧的操作会一直阻塞到收到 `$events/result`，所以：
///   · 每条 waterfall 必须**有且只有一次**应答；
///   · 重连后旧 `clientId` 失效，未决 waterfall 会被宿主重放到新世代；
///   · 用户没来得及决定就断线时，必须回落到一个安全结论（审批 = `unavailable`，
///     即"没人答得上"，宿主会 fail closed），而不是永远不答。
/// 一条 waterfall 的处置决定。
public enum WaterfallDecision: Sendable {
    /// 现在就答。
    case answer(JSONValue)
    /// 我不负责这条，交给下一个处理者（回 `{kind:'next'}`）。
    case next
    /// **稍后由 UI 答**：保持挂起，宿主继续等。
    ///
    /// 只有"用户还没决定"这一种情况该用它。用错方向会很糟：
    /// 审批提前回 `next` 会绕过 fail-closed，提问提前回 `next` 会让界面上的提交按钮变成摆设。
    case deferred
}

public actor EventStreamCoordinator {
    public struct Generation: Sendable, Equatable {
        public var clientId: String
        public var startedAt: Date
    }

    /// 事件消费回调。
    public typealias Handler = @Sendable (HostEvent) async -> Void
    /// waterfall 应答回调。
    public typealias WaterfallAnswerer = @Sendable (WaterfallRequest) async -> WaterfallDecision

    private let client: DSHClient
    private let logger: any DSHLogSink?
    private let reconnect: RetryPolicy

    private var generation: Generation?
    private var pending: [String: WaterfallRequest] = [:]
    private var loop: Task<Void, Never>?
    private var answerer: WaterfallAnswerer?
    private var handler: Handler?

    private var generationContinuations: [UUID: AsyncStream<Generation?>.Continuation] = [:]

    public init(client: DSHClient, reconnect: RetryPolicy = .default, logger: any DSHLogSink? = nil) {
        self.client = client
        self.reconnect = reconnect
        self.logger = logger
    }

    public func setAnswerer(_ answerer: @escaping WaterfallAnswerer) {
        self.answerer = answerer
    }

    public func setAbandonmentHandler(_ handler: @escaping @Sendable ([WaterfallRequest]) async -> Void) {
        abandonmentHandler = handler
    }

    public func setHandler(_ handler: @escaping Handler) {
        self.handler = handler
    }

    public func currentGeneration() -> Generation? { generation }

    /// 世代变化（含断开时的 `nil`），UI 用它显示连接状态。
    public func generations() -> AsyncStream<Generation?> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(generation)
            generationContinuations[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.dropGeneration(id) }
            }
        }
    }

    private func dropGeneration(_ id: UUID) { generationContinuations[id] = nil }

    private func setGeneration(_ next: Generation?) {
        generation = next
        for continuation in generationContinuations.values { continuation.yield(next) }
    }

    /// 立即把一条**仍然挂着**的 waterfall 结掉。
    ///
    /// UI 走这条路回答案 —— 而不是自己去发 `$events/result`。原因有两个：
    ///   · 只有协调器知道这条是不是还挂着（宿主已经收到 `next` 的话，再发也是白发）；
    ///   · 从 `pending` 里摘掉这件事必须和发送在同一个地方做，否则"恰好一次"就没保证了。
    public func respond(_ request: WaterfallRequest, outcome: JSONValue) async {
        guard pending[request.eventId] != nil else {
            logger?.log(.warning, "这条路已结案，忽略应答 \(request.event) \(request.eventId)")
            return
        }
        pending[request.eventId] = nil
        await answer(request, outcome: outcome)
    }

    /// 这条 waterfall 是不是还挂着。UI 用它判断"我还能不能答"。
    public func isPending(eventId: String) -> Bool { pending[eventId] != nil }

    /// 连接换代导致某几条 waterfall 作废时回调。
    ///
    /// UI 必须据此撤掉那些卡片：宿主已经按安全结论把它们结掉了，界面上再让用户
    /// 对着它们点提交，只会得到"点了没反应"。
    private var abandonmentHandler: (@Sendable ([WaterfallRequest]) async -> Void)?

    /// 未决的 waterfall（UI 用它把"待审批"提示出来）。
    public func pendingRequests() -> [WaterfallRequest] { Array(pending.values) }

    // MARK: - 循环

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.run()
        }
    }

    public func stop() async {
        loop?.cancel()
        loop = nil
        setGeneration(nil)
        // 断线时把未决的 waterfall 全部按安全结论收掉，避免宿主一直等。
        let outstanding = pending
        pending.removeAll()
        for request in outstanding.values {
            await answer(request, outcome: Self.safeFallback(for: request))
        }
    }

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                attempt = 0
                for try await event in await client.events() {
                    if Task.isCancelled { return }
                    await handle(event)
                }
                // 流正常结束：宿主关掉了它（例如 DSH 重启）。
                logger?.log(.info, "$events 流结束，准备重连")
            } catch {
                if Task.isCancelled { return }
                logger?.log(.warning, "$events 断开：\(error.localizedDescription)")
            }
            if Task.isCancelled { return }
            await failPendingWaterfalls()
            setGeneration(nil)
            attempt += 1
            let wait = reconnect.delay(afterAttempt: attempt)
            logger?.log(.info, "\(wait.formatted) 后重连 $events")
            try? await Task.sleep(for: wait)
        }
    }

    private func handle(_ event: HostEvent) async {
        switch event {
        case .ready(let clientId, let host):
            setGeneration(Generation(clientId: clientId, startedAt: Date()))
            logger?.log(.info, "$events 世代就绪 clientId=\(clientId) home=\(host.string("home") ?? "?")")
        case .emit:
            break
        case .waterfall(let request):
            pending[request.eventId] = request
        }
        if let handler {
            await handler(event)
        }
        if case .waterfall(let request) = event {
            await dispatch(request)
        }
    }

    private func dispatch(_ request: WaterfallRequest) async {
        // 没有应答者 → 直接交给下一个处理者。
        guard let answerer else {
            await respond(request, outcome: WaterfallRequest.nextOutcome)
            return
        }
        switch await answerer(request) {
        case .answer(let outcome):
            await respond(request, outcome: outcome)
        case .next:
            await respond(request, outcome: WaterfallRequest.nextOutcome)
        case .deferred:
            // **保持挂起**，等用户。
            //
            // 这里曾经是错的：把 `nil` 当成"我不答"，立刻回 `{kind:'next'}` 并清掉 pending。
            // 后果是用户界面上明明弹出了问题卡片、点提交却毫无作用 —— 宿主早就收到
            // `next` 了，答案送不回去，agent 只能等到超时。
            // 远端客户端也**没有第二条路**：网关转发 waterfall 时把 `wait`/`callId` 剥掉了，
            // 所以 `userQuestions/answer(callId)` 这条路远端根本走不通（实测确认）。
            logger?.log(.info, "waterfall 挂起等用户：\(request.event) \(request.eventId)")
        }
    }

    private func answer(_ request: WaterfallRequest, outcome: JSONValue) async {
        guard let generation else {
            logger?.log(.warning, "没有世代，跳过应答 \(request.event)")
            return
        }
        do {
            try await client.answerEvent(clientId: generation.clientId, eventId: request.eventId, outcome: outcome)
            logger?.log(.debug, "已应答 \(request.event) \(request.eventId)")
        } catch {
            logger?.log(.warning, "应答 \(request.event) 失败：\(error)")
        }
    }

    /// 世代失效时给未决 waterfall 的结论。审批回落 `unavailable`（fail closed），
    /// 提问回落 `next`（交给电脑端自己的默认实现）。
    ///
    /// 同时通知 UI：这些卡片**已经作废**，界面上不能再让用户点提交。
    /// 不通知的话，用户会对着一个点不动的卡片反复点。
    private func failPendingWaterfalls() async {
        let outstanding = pending
        pending.removeAll()
        for request in outstanding.values {
            await answer(request, outcome: Self.safeFallback(for: request))
        }
        if !outstanding.isEmpty, let abandonmentHandler {
            await abandonmentHandler(Array(outstanding.values))
        }
    }

    static func safeFallback(for request: WaterfallRequest) -> JSONValue {
        request.isApproval
            ? WaterfallRequest.approvalOutcome(.unavailable)
            : WaterfallRequest.nextOutcome
    }
}
