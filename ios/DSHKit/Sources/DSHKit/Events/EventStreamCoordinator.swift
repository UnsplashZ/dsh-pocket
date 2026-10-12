import Foundation

/// `$events` 的连接管理：世代跟踪 + waterfall 的**恰好一次应答**保证。
///
/// 为什么需要一个专门的类型：`$events` 的首帧 `ready` 绑定**世代**（`clientId`）。
/// 宿主侧的操作会一直阻塞到收到 `$events/result`，所以：
///   · 每条 waterfall 必须**有且只有一次**应答；
///   · 重连后旧 `clientId` 失效，未决 waterfall 会被宿主重放到新世代；
///   · 用户没来得及决定就断线时，必须回落到一个安全结论（审批 = `unavailable`，
///     即"没人答得上"，宿主会 fail closed），而不是永远不答。
public actor EventStreamCoordinator {
    public struct Generation: Sendable, Equatable {
        public var clientId: String
        public var startedAt: Date
    }

    /// 事件消费回调。返回 `nil` 表示"我不答这条"，由协调器回 `next`。
    public typealias Handler = @Sendable (HostEvent) async -> Void
    /// waterfall 应答回调。返回 `nil` 表示回 `{kind:'next'}`。
    public typealias WaterfallAnswerer = @Sendable (WaterfallRequest) async -> JSONValue?

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
        let outcome = await answerer?(request)
        guard pending[request.eventId] != nil else { return }   // 已经不欠这条了
        pending[request.eventId] = nil
        await answer(request, outcome: outcome ?? WaterfallRequest.nextOutcome)
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
    private func failPendingWaterfalls() async {
        let outstanding = pending
        pending.removeAll()
        for request in outstanding.values {
            await answer(request, outcome: Self.safeFallback(for: request))
        }
    }

    static func safeFallback(for request: WaterfallRequest) -> JSONValue {
        request.isApproval
            ? WaterfallRequest.approvalOutcome(.unavailable)
            : WaterfallRequest.nextOutcome
    }
}
