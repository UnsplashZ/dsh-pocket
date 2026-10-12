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
    private let logger: any DSHLogSink?

    private var socket: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var pingLoop: Task<Void, Never>?
    private var continuations: [String: AsyncThrowingStream<MuxFrame, any Error>.Continuation] = [:]
    private var endpoints: [String: String] = [:]
    private var closedReason: String?

    private var stateContinuations: [UUID: AsyncStream<MuxState>.Continuation] = [:]

    public init(
        provider: any DSHHostProvider,
        session: URLSession = .dshShared,
        logger: any DSHLogSink? = nil
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

    private func ensureSocket() async throws -> URLSessionWebSocketTask {
        if let socket, socket.state == .running { return socket }
        if let socket { socket.cancel(with: .goingAway, reason: nil) }
        setState(.connecting)
        let base = try await provider.webSocketURL()
        // webSocketURL() 给的是"基址"（ws://127.0.0.1:<port>）；所有流都走同一条
        // /api/remote.mux。忘了拼这一段的表现是代理端收到 `WS ↑ /` 然后立刻断开。
        let url = DSHAPI.remoteMux(base: base)
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 64 * 1024 * 1024   // 单会话快照实测 ~1 MB，给足余量
        socket = task
        closedReason = nil
        task.resume()
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
                    await self.socketFailed(error)
                    return
                }
            }
        }
    }

    private func startPingLoop(_ task: URLSessionWebSocketTask) {
        pingLoop?.cancel()
        pingLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                task.sendPing { error in
                    if let error { Task { await self?.socketFailed(error) } }
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
                message: error.string("message") ?? "流错误",
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

    private func socketFailed(_ error: any Error) {
        let reason = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
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
            throw DSHTransportError.malformedResponse("无法编码为 UTF-8")
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
