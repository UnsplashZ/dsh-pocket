import Foundation

/// 一条 mux 逻辑流上收到的帧。
public enum MuxFrame: Sendable {
    /// 一个流值。宿主允许 `item` 不带 `value`（顶层 undefined），此时是 `nil`。
    case item(JSONValue?)
    case end
    case error(DSHError)
}

/// 单条 WebSocket 上的多路复用（`/api/remote.mux`）。
///
/// 线上契约（读自 `dsh-api-gateway/lib/types/stream-protocol.js`，本机版本核对）：
///
/// ```
/// 上行 {type:'open',   streamId, endpoint, payload:{args:{…}}}
///      {type:'cancel', streamId}
/// 下行 {type:'item',  streamId, value?}
///      {type:'end',   streamId}
///      {type:'error', streamId, error:{code,message,details}}
/// ```
///
/// 要点：
///   · `streamId` 客户端自选、服务端回显；
///   · **开流失败也是 `error` 帧，不是 HTTP 错误**；
///   · 没有逐流确认；`cancel` 或关 socket 即结束该世代；
///   · 所有流共用这一条 socket —— 不要为每条流各开一条。
public actor MuxClient {
    private let provider: any DSHHostProvider
    private let session: URLSession
    private let logger: (any DSHLogSink)?

    private var socket: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var pingLoop: Task<Void, Never>?
    private var continuations: [String: AsyncThrowingStream<MuxFrame, any Error>.Continuation] = [:]
    private var endpoints: [String: String] = [:]
    private var closedReason: String?
    /// 正在建的那条 socket（单飞，见 `ensureSocket`）。并发开流时共用它，避免建出两条。
    private var socketCreation: Task<URLSessionWebSocketTask, any Error>?
    /// 我们自己调了 `close()`。
    ///
    /// 主动关闭会让 `receiveLoop` 抛「Socket未连接」，那**不是**故障 ——
    /// 真机日志里 4 条 `mux 断开：未能完成该操作。Socket未连接` 全部紧跟在
    /// `退到后台，断开传输` 之后，是纯噪音。有它就能静音。
    private var isClosing = false

    private var stateContinuations: [UUID: AsyncStream<MuxState>.Continuation] = [:]

    public init(
        provider: any DSHHostProvider,
        session: URLSession = .dshShared,
        logger: (any DSHLogSink)? = nil
    ) {
        self.provider = provider
        self.session = session
        self.logger = logger
    }

    /// 连接状态，供 UI 显示"连接中 / 已连接 / 已断开"。
    public enum MuxState: Sendable, Equatable {
        case idle
        case connecting
        case connected
        case disconnected(reason: String)
    }

    private var state: MuxState = .idle

    public func currentState() -> MuxState { state }

    /// 订阅状态变化。取消迭代即退订。
    public func states() -> AsyncStream<MuxState> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(state)
            stateContinuations[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.dropStateContinuation(id) }
            }
        }
    }

    private func dropStateContinuation(_ id: UUID) {
        stateContinuations[id] = nil
    }

    private func setState(_ next: MuxState) {
        guard state != next else { return }
        state = next
        for continuation in stateContinuations.values { continuation.yield(next) }
    }

    // MARK: - 开流

    /// 打开一条逻辑流。返回的序列在 `end` 或 `error` 后自然结束。
    /// - Parameters:
    ///   - endpoint: 如 `$events`、`session/follow`。
    ///   - payload: 完整 payload，通常是 `["args": …]`。
    public func open(endpoint: String, payload: JSONValue) -> AsyncThrowingStream<MuxFrame, any Error> {
        let streamId = "s\(StreamIdCounter.next())"
        return AsyncThrowingStream { continuation in
            Task { await self.register(streamId: streamId, endpoint: endpoint, payload: payload, continuation: continuation) }
            continuation.onTermination = { reason in
                Task { await self.terminate(streamId: streamId, reason: reason) }
            }
        }
    }

    private func register(
        streamId: String,
        endpoint: String,
        payload: JSONValue,
        continuation: AsyncThrowingStream<MuxFrame, any Error>.Continuation
    ) async {
        continuations[streamId] = continuation
        endpoints[streamId] = endpoint
        do {
            let socket = try await ensureSocket()
            let message: JSONValue = .object([
                "type": .string("open"),
                "streamId": .string(streamId),
                "endpoint": .string(endpoint),
                "payload": payload,
            ])
            try await send(message, on: socket)
            logger?.log(.debug, "mux open \(endpoint) (\(streamId))")
        } catch {
            continuations[streamId] = nil
            endpoints[streamId] = nil
            continuation.finish(throwing: Self.asClientError(error))
        }
    }

    private func terminate(streamId: String, reason: AsyncThrowingStream<MuxFrame, any Error>.Continuation.Termination) {
        guard continuations[streamId] != nil else { return }
        continuations[streamId] = nil
        endpoints[streamId] = nil
        if case .cancelled = reason, let socket {
            let message: JSONValue = .object([
                "type": .string("cancel"),
                "streamId": .string(streamId),
            ])
            Task { try? await self.send(message, on: socket) }
        }
    }

    /// 主动取消一条流（等价于取消迭代）。
    public func cancel(streamId: String) {
        guard let continuation = continuations[streamId] else { return }
        continuations[streamId] = nil
        endpoints[streamId] = nil
        if let socket {
            let message: JSONValue = .object([
                "type": .string("cancel"),
                "streamId": .string(streamId),
            ])
            Task { try? await self.send(message, on: socket) }
        }
        continuation.finish()
    }

    // MARK: - socket 生命周期

    /// 建 socket 的**单飞**入口。
    ///
    /// 为什么必须有它（2026-10-21 真机日志：`mux 已连接` 在**同一毫秒**打两条，
    /// 一天 3 次）：`open()` 给每条流各起一个 Task，`$events` 和 `workspace/follow`
    /// 是并发开的，于是两个调用同时进到 `ensureSocket`。复用判断在
    /// `await webSocketURL()` / `await requestHeaders()` **之前**做，两条都判定
    /// "还没有 socket" → 各建一条 → 后写的覆盖前写的：前一条既没 cancel、
    /// `receiveLoop` 变量也被覆盖（旧循环再也取消不掉），泄漏下来的那条稍后出错
    /// 还会走 `socketFailed` 把所有流全清掉、全量重订阅。
    ///
    /// 现在把"建一条"这件事做成单飞任务：并发调用共享同一个结果，只可能建一条。
    private func ensureSocket() async throws -> URLSessionWebSocketTask {
        // **只在"确实还能用"时复用。**
        //
        // `state == .running` 不够：URLSessionWebSocketTask 在底层 socket 已经
        // 不可用时仍可能停留在 `.running`（真机日志里 `sendPing` 报"Socket未连接"
        // 却仍然是 running）。复用它会让后续所有请求都打在一个死连接上，
        // 然后每次都要等一轮超时才重建。
        // 加上 `closedReason == nil`：它由 `socketFailed` / 正常关闭时置上，
        // 是"这条 socket 已经被判死"的直接证据。
        if let socket, socket.state == .running, closedReason == nil { return socket }
        if let inflight = socketCreation { return try await inflight.value }
        let creation = Task { try await self.createSocket() }
        socketCreation = creation
        do {
            let created = try await creation.value
            socketCreation = nil
            return created
        } catch {
            socketCreation = nil
            throw error
        }
    }

    /// 真正建一条 socket（只由 `ensureSocket` 的单飞任务调用）。
    private func createSocket() async throws -> URLSessionWebSocketTask {
        isClosing = false
        if let socket { socket.cancel(with: .goingAway, reason: nil) }
        setState(.connecting)
        let base = try await provider.webSocketURL()
        // webSocketURL() 给的是"基址"（ws://127.0.0.1:<port>）；所有流都走同一条
        // /api/remote.mux。忘了拼这一段的表现是代理端收到 `WS ↑ /` 然后立刻断开。
        let url = DSHAPI.remoteMux(base: base)
        var request = URLRequest(url: url)
        for (name, value) in await provider.requestHeaders() {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 64 * 1024 * 1024   // 单会话快照实测 ~1 MB，给足余量
        socket = task
        closedReason = nil
        task.resume()
        // 建 socket 期间被 `close()` 了（退到后台）：这条已经没人要，别把循环挂上去。
        if isClosing {
            task.cancel(with: .goingAway, reason: nil)
            socket = nil
            throw DSHClientError.transport(.socketClosed(reason: String(localized: "连接已取消")))
        }
        startReceiveLoop(task)
        startPingLoop(task)
        setState(.connected)
        logger?.log(.info, "mux 已连接 \(url.absoluteString)")
        return task
    }

    private func startReceiveLoop(_ task: URLSessionWebSocketTask) {
        receiveLoop?.cancel()
        receiveLoop = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    guard let text = Self.text(of: message) else { continue }
                    await self.handle(text: text)
                } catch {
                    await self.socketFailed(error, from: task)
                    return
                }
            }
        }
    }

    /// 保活 ping。
    ///
    /// **ping 出错不等于连接断了。** 这里原来只要 `sendPing` 回一个 error 就立刻
    /// `socketFailed` —— 把所有流全部断掉、清空订阅，然后整套重连。
    /// 但 `URLSessionWebSocketTask.sendPing` 在 socket 还没真正就绪、或者
    /// 正在被系统挂起时，会直接回一个"Socket未连接"的 error，
    /// 而底层连接其实还活着（真机日志 2026-10-19：`mux 断开：未能完成该操作。
    /// Socket未连接` 在没有任何后台切换的情况下每 20~35 秒刷一次，
    /// 每次都要重订阅全部流）。
    ///
    /// 现在改成"连续失败才算真断"：单次 ping 失败只是记一笔；连续两次失败
    /// （间隔一个周期，说明连接确实不通了）才判定断开。真正的断开由
    /// `receiveLoop` 立刻发现 —— 那才是可靠信号，ping 只是补漏。
    private func startPingLoop(_ task: URLSessionWebSocketTask) {
        pingLoop?.cancel()
        pingLoop = Task { [weak self] in
            var consecutiveFailures = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                let failed = await withCheckedContinuation { continuation in
                    task.sendPing { error in
                        continuation.resume(returning: error != nil)
                    }
                }
                if failed {
                    consecutiveFailures += 1
                    guard let self else { return }
                    await self.logger?.log(.debug, "mux ping 失败（连续第 \(consecutiveFailures) 次）")
                    // 连续两次失败才当真：单次多半是 socket 短暂不可用。
                    if consecutiveFailures >= 2 {
                        await self.socketFailed(
                            DSHClientError.transport(.socketClosed(reason: String(localized: "连接已断开"))),
                            from: task
                        )
                        return
                    }
                } else {
                    consecutiveFailures = 0
                }
            }
        }
    }

    private static func text(of message: URLSessionWebSocketTask.Message) -> String? {
        switch message {
        case .string(let text): return text
        case .data(let data): return String(data: data, encoding: .utf8)
        @unknown default: return nil
        }
    }

    private func handle(text: String) {
        guard let data = text.data(using: .utf8),
              let frame = try? JSONDecoder.dsh.decode(JSONValue.self, from: data),
              let type = frame.string("type"),
              let streamId = frame.string("streamId"),
              let continuation = continuations[streamId]
        else {
            // 不认识的帧丢掉即可：宿主可能为未来的帧类型保留前向兼容。
            return
        }
        switch type {
        case "item":
            continuation.yield(.item(frame["value"]))
        case "end":
            continuations[streamId] = nil
            endpoints[streamId] = nil
            continuation.yield(.end)
            continuation.finish()
        case "error":
            let error = frame["error"] ?? .null
            let remote = DSHError(
                code: error.string("code") ?? "stream/unknown",
                message: error.string("message") ?? String(localized: "流错误"),
                details: error["details"] ?? .object([:])
            )
            continuations[streamId] = nil
            endpoints[streamId] = nil
            continuation.yield(.error(remote))
            continuation.finish()
        default:
            break
        }
    }

    /// socket 出事了。
    ///
    /// `from` 是**出事的那条** socket：它可能已经不是当前这条了。
    ///
    /// 为什么必须认身份（2026-10-21 装机后第一次启动的真机日志）：旧的 receiveLoop
    /// 是异步发现 socket 死了的，如果这期间 `ensureSocket` 已经换了一条新的，
    /// 这条迟到的死讯会把**新 socket 一起清掉**（`socket = nil` + 结束所有流），
    /// 表现就是"刚连上十几秒就断一次、然后立刻重连"。
    private func socketFailed(_ error: any Error, from task: URLSessionWebSocketTask) {
        let reason = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
        // 主动 `close()` 之后 socket 被 cancel，`receiveLoop` 必然抛一次
        //「Socket未连接」。那是**我们让它断的**，不是故障 —— 记 debug 就够，
        // 否则每次退到后台都会在日志里留一条 WARN，把真问题淹掉。
        if isClosing {
            logger?.log(.debug, "mux 已关闭（主动，忽略底层报错：\(reason)）")
            return
        }
        // 这条 socket 已经被换掉了：它的死讯不该影响现在这条连接。
        if socket !== task {
            logger?.log(.debug, "旧 socket 报错（已被替换，忽略）：\(reason)")
            return
        }
        guard !continuations.isEmpty || state != .disconnected(reason: reason) else { return }
        logger?.log(.warning, "mux 断开：\(reason)")
        socket = nil
        receiveLoop = nil
        pingLoop?.cancel()
        pingLoop = nil
        let pending = continuations
        continuations.removeAll()
        endpoints.removeAll()
        for continuation in pending.values {
            continuation.finish(throwing: DSHClientError.transport(.socketClosed(reason: reason)))
        }
        setState(.disconnected(reason: reason))
    }

    public func close() {
        isClosing = true
        socketCreation?.cancel()
        socketCreation = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        receiveLoop?.cancel()
        pingLoop?.cancel()
        socket = nil
        receiveLoop = nil
        pingLoop = nil
        for continuation in continuations.values { continuation.finish() }
        continuations.removeAll()
        endpoints.removeAll()
        setState(.idle)
    }

    // MARK: - 发送

    private func send(_ value: JSONValue, on task: URLSessionWebSocketTask) async throws {
        let data = try JSONEncoder.dshCompact.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw DSHTransportError.malformedResponse(String(localized: "无法编码为 UTF-8"))
        }
        try await task.send(.string(text))
    }

    static func asClientError(_ error: any Error) -> DSHClientError {
        if let error = error as? DSHClientError { return error }
        if let error = error as? DSHTransportError { return .transport(error) }
        return .transport(.underlying(error.localizedDescription))
    }
}

/// `streamId` 只需要在一条 socket 生命期内唯一；用进程级计数器最省事。
enum StreamIdCounter {
    private static let lock = NSLock()
    private static var value: UInt64 = 0

    static func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
