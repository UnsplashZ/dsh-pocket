import Foundation

/// DSH 客户端协议门面。
///
/// 只暴露 [DESIGN.md](../../../docs/DESIGN.md) §4.2 的一期端点子集：
/// `$events` + `$events/result`、`session/list`、`session/follow`、`session/page`、
/// `session/prompt`、`session/cancel`、`session/modelCatalog`、`session/selectModel`、
/// `session/create`、`session/rename`、`workspace/archiveSession`、
/// `session/attachment`、`session/uploadFileBinary`、`workspaceFiles/*`。
///
/// **刻意不做**：`settings/*`、`credentials/*`、`skills/list`、
/// `directoryPicker/*`（`pick` 会在电脑上弹系统对话框）、`session/fork`。
public actor DSHClient {
    public let provider: any DSHHostProvider
    private let rpc: RPCClient
    private let mux: MuxClient
    private let session: URLSession
    private let logger: any DSHLogSink?

    public init(
        provider: any DSHHostProvider,
        session: URLSession = .dshShared,
        retry: RetryPolicy = .default,
        logger: any DSHLogSink? = nil
    ) {
        self.provider = provider
        self.session = session
        self.logger = logger
        self.rpc = RPCClient(provider: provider, session: session, retry: retry, logger: logger)
        self.mux = MuxClient(provider: provider, session: session, logger: logger)
    }

    // MARK: - 连接状态

    public nonisolated func muxStates() async -> AsyncStream<MuxClient.MuxState> {
        await mux.states()
    }

    public func closeTransport() async {
        await mux.close()
    }

    // MARK: - 会话列表

    /// `session/list`。注意参数家法：DSH 的浏览器客户端发的是 `{"_request":{}}`。
    public func listSessions() async throws -> [SessionSummary] {
        let value = try await rpc.call(method: "session/list", payload: ["args": .object(["_request": .object([:])])])
        let items = value.array("items") ?? value.array("sessions") ?? []
        return items.compactMap(SessionSummary.decode)
    }

    /// 会话投影（`session/list` 单条，用于列表页之外的地方补齐）。
    public func listProjections(sessionIds: [String]) async throws -> JSONValue {
        try await rpc.call(method: "session/list", payload: [
            "args": .object(["_request": .object(["sessionIds": .array(sessionIds.map { .string($0) })])])
        ])
    }

    // MARK: - 会话流

    /// `session/follow`。首帧恒为 `snapshot`，其后是 `event` 与（可选）`assistant-stream`。
    public nonisolated func follow(sessionId: String, assistantStream: Bool = true) -> AsyncThrowingStream<SessionFollowFrame, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                // `assistantStream` 在描述符里是字面量 `true`：**传 false 会被边界校验拒掉**
                // （实测报 `wire field "request" failed boundary validation`）。
                // 所以"不要实时帧"的正确写法是**省略这个字段**，不是写 false。
                var request: [String: JSONValue] = [
                    "address": .object([
                        "kind": .string("session"),
                        "sessionId": .string(sessionId),
                    ])
                ]
                if assistantStream { request["assistantStream"] = .bool(true) }

                let stream = await self.mux.open(
                    endpoint: "session/follow",
                    payload: .object([
                        "args": .object([
                            "request": .object(request)
                        ])
                    ])
                )
                do {
                    for try await frame in stream {
                        switch frame {
                        case .item(let value):
                            guard let value else { continue }
                            guard let decoded = try? Self.decodeFollowFrame(value) else {
                                self.logger?.log(.warning, "follow 帧无法解析：\(value.displayText(limit: 200))")
                                continue
                            }
                            continuation.yield(decoded)
                        case .end:
                            continuation.finish()
                            return
                        case .error(let error):
                            continuation.finish(throwing: DSHClientError.remote(error))
                            return
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: MuxClient.asClientError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func decodeFollowFrame(_ value: JSONValue) throws -> SessionFollowFrame {
        switch value.string("type") {
        case "snapshot":
            return .snapshot(try SessionSnapshot.decode(value))
        case "event":
            guard let event = value["event"] else {
                throw DSHTransportError.malformedResponse("follow 的 event 帧缺少 event")
            }
            return .event(try SessionEvent.decode(event))
        case "assistant-stream":
            return .assistantStream(AssistantStreamFrame.decode(value))
        default:
            throw DSHTransportError.malformedResponse("未知的 follow 帧：\(value.string("type") ?? "?")")
        }
    }

    // MARK: - 历史补页

    public struct HistoryPage: Sendable {
        public var events: [SessionEvent]
        public var hasMore: Bool
    }

    /// `session/page`。**必须带 `throughSeq`**（取自 follow 快照的 `cursor`）。
    public func page(
        sessionId: String,
        throughSeq: Int,
        beforeSeq: Int? = nil,
        maxMessages: Int = 50
    ) async throws -> HistoryPage {
        var request: [String: JSONValue] = [
            "address": .object([
                "kind": .string("session"),
                "sessionId": .string(sessionId),
            ]),
            "throughSeq": .number(Double(throughSeq)),
            "maxMessages": .number(Double(max(1, maxMessages))),
        ]
        if let beforeSeq {
            request["beforeSeq"] = .number(Double(beforeSeq))
        }
        let value = try await rpc.call(method: "session/page", payload: ["args": .object(["request": .object(request)])])
        let records = value.array("records") ?? []
        let events = records.compactMap { record -> SessionEvent? in
            guard record.string("type") == "event", let payload = record["event"] else { return nil }
            return try? SessionEvent.decode(payload)
        }
        return HistoryPage(events: events, hasMore: value.bool("hasMore") ?? false)
    }

    // MARK: - 交互

    /// 提交一条消息。
    /// - Parameter mode: `steer` 表示"插队给正在跑的这一轮"；不传表示排到下一轮。
    @discardableResult
    public func prompt(
        sessionId: String,
        requestId: String,
        text: String,
        attachments: [PromptAttachment] = [],
        clientTimeZone: String? = TimeZone.current.identifier,
        mode: String? = nil
    ) async throws -> Bool {
        var content: [JSONValue] = []
        if !text.isEmpty { content.append(.object(["type": .string("text"), "text": .string(text)])) }
        for attachment in attachments {
            switch attachment {
            case .image(let ref):
                content.append(.object([
                    "type": .string("image"),
                    "attachment": .object(ref.json),
                ]))
            case .fileReceipt(let receiptId, _):
                content.append(.object([
                    "type": .string("file"),
                    "receiptId": .string(receiptId),
                ]))
            case .stagedFile(let attachment):
                content.append(.object([
                    "type": .string("file"),
                    "attachment": .object(attachment.json),
                ]))
            }
        }
        var request: [String: JSONValue] = [
            "sessionId": .string(sessionId),
            "requestId": .string(requestId),
            "content": .array(content),
        ]
        if let clientTimeZone { request["clientTimeZone"] = .string(clientTimeZone) }
        if let mode { request["mode"] = .string(mode) }

        let value = try await rpc.call(method: "session/prompt", payload: ["args": .object(["request": .object(request)])])
        return value.bool("accepted") ?? false
    }

    /// 打断正在跑的一轮。返回是否被接受。
    @discardableResult
    public func cancel(sessionId: String, requestId: String = RpcId.make()) async throws -> Bool {
        let value = try await rpc.call(method: "session/cancel", payload: [
            "args": .object([
                "request": .object([
                    "sessionId": .string(sessionId),
                    "requestId": .string(requestId),
                ])
            ])
        ])
        return value.bool("accepted") ?? (value.isNull ? true : false)
    }

    /// 会话排队项（`session/updateQueue`）：编辑或删除还没被消化的消息。
    public func updateQueue(sessionId: String, itemId: String, action: JSONValue) async throws {
        _ = try await rpc.call(method: "session/updateQueue", payload: [
            "args": .object([
                "request": .object([
                    "sessionId": .string(sessionId),
                    "itemId": .string(itemId),
                    "action": action,
                ])
            ])
        ])
    }

    // MARK: - 会话管理

    public func createSession(cwd: String? = nil, agentPreset: String? = nil) async throws -> String {
        var request: [String: JSONValue] = [:]
        if let cwd { request["cwd"] = .string(cwd) }
        if let agentPreset { request["agentPreset"] = .string(agentPreset) }
        let value = try await rpc.call(method: "session/create", payload: ["args": .object(["request": .object(request)])])
        guard let sessionId = value.string("sessionId") else {
            throw DSHClientError.transport(.malformedResponse("session/create 没有返回 sessionId"))
        }
        return sessionId
    }

    public func rename(sessionId: String, title: String) async throws {
        _ = try await rpc.call(method: "session/rename", payload: [
            "args": .object([
                "request": .object([
                    "sessionId": .string(sessionId),
                    "title": .string(title),
                ])
            ])
        ])
    }

    public func archiveSession(sessionId: String) async throws {
        _ = try await rpc.call(method: "workspace/archiveSession", payload: [
            "args": .object([
                "request": .object(["sessionId": .string(sessionId)])
            ])
        ])
    }

    // MARK: - 模型

    /// `session/modelCatalog`：可用模型清单。
    public func modelCatalog() async throws -> JSONValue {
        try await rpc.call("session/modelCatalog")
    }

    public func selectModel(
        sessionId: String,
        provider: String,
        model: String,
        reasoningEffort: String? = nil
    ) async throws {
        var selection: [String: JSONValue] = [
            "provider": .string(provider),
            "model": .string(model),
        ]
        if let reasoningEffort { selection["reasoningEffort"] = .string(reasoningEffort) }
        _ = try await rpc.call(method: "session/selectModel", payload: [
            "args": .object([
                "request": .object([
                    "sessionId": .string(sessionId),
                    "selection": .object(selection),
                ])
            ])
        ])
    }

    // MARK: - 图片与文件

    public enum PromptAttachment: Sendable {
        case image(DSHAttachmentRef)
        case fileReceipt(receiptId: String, file: DSHAttachmentRef)
        case stagedFile(DSHAttachmentRef)
    }

    /// 取回一张会话里引用过的图片（base64 → Data）。
    public func attachment(sessionId: String, attachmentId: String) async throws -> (ref: DSHAttachmentRef, data: Data) {
        let value = try await rpc.call(method: "session/attachment", payload: [
            "args": .object([
                "request": .object([
                    "sessionId": .string(sessionId),
                    "attachmentId": .string(attachmentId),
                ])
            ])
        ])
        guard let base64 = value.string("data"), let data = Data(base64Encoded: base64) else {
            throw DSHClientError.transport(.malformedResponse("附件数据不是合法 base64"))
        }
        return (DSHAttachmentRef(json: value["attachment"] ?? .object([:])), data)
    }

    public struct UploadResult: Sendable {
        public var receiptId: String
        public var file: DSHAttachmentRef
    }

    /// 上传原始字节。走 `POST /api/session/uploadFileBinary`（流式路由，不经过 JSON）。
    public func uploadFile(sessionId: String, name: String?, data: Data) async throws -> UploadResult {
        let base = try await provider.baseURL()
        var components = URLComponents(url: base.appendingPathComponent("api/session/uploadFileBinary"), resolvingAgainstBaseURL: false)
        var query: [URLQueryItem] = [URLQueryItem(name: "sessionId", value: sessionId)]
        if let name { query.append(URLQueryItem(name: "name", value: name)) }
        components?.queryItems = query
        guard let url = components?.url else {
            throw DSHClientError.transport(.malformedResponse("无法构造上传 URL"))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        request.timeoutInterval = 120

        let (responseData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw DSHClientError.transport(.http(status: status, body: String(data: responseData.prefix(200), encoding: .utf8) ?? ""))
        }
        let value = try JSONDecoder.dsh.decode(JSONValue.self, from: responseData)
        if value.bool("ok") == false {
            let error = value["error"] ?? .null
            throw DSHClientError.remote(DSHError(
                code: error.string("code") ?? "upload/failed",
                message: error.string("message") ?? "上传失败",
                details: error["details"] ?? .object([:])
            ))
        }
        let payload = value["value"] ?? .null
        guard let receiptId = payload.string("receiptId") else {
            throw DSHClientError.transport(.malformedResponse("上传结果缺少 receiptId"))
        }
        return UploadResult(receiptId: receiptId, file: DSHAttachmentRef(json: payload["file"] ?? .object([:])))
    }

    // MARK: - 工作区文件

    /// `workspaceFiles/list`：**用工作区相对路径**。
    public func listFiles(scopeId: String, path: String?) async throws -> [WorkspaceFileEntry] {
        var request: [String: JSONValue] = ["workspaceFileScopeId": .string(scopeId)]
        if let path, !path.isEmpty { request["path"] = .string(path) }
        let value = try await rpc.call(method: "workspaceFiles/list", payload: ["args": .object(request)])
        let entries = value.array("entries") ?? value.array("files") ?? value.array("items") ?? []
        return entries.compactMap(WorkspaceFileEntry.init(json:))
    }

    /// `workspaceFiles/stat`：**用绝对路径**。
    public func statFile(scopeId: String, path: String) async throws -> JSONValue {
        try await rpc.call(method: "workspaceFiles/stat", payload: [
            "args": .object([
                "workspaceFileScopeId": .string(scopeId),
                "path": .string(path),
            ])
        ])
    }

    /// `workspaceFiles/read`：**用绝对路径**。
    public func readFile(scopeId: String, path: String, range: JSONValue? = nil) async throws -> String {
        var args: [String: JSONValue] = [
            "workspaceFileScopeId": .string(scopeId),
            "path": .string(path),
        ]
        if let range { args["range"] = range }
        let value = try await rpc.call(method: "workspaceFiles/read", payload: ["args": .object(args)])
        return value.string("text") ?? value.string("content") ?? ""
    }

    // MARK: - 事件通道

    /// `$events`：宿主应用的转发事件。
    public nonisolated func events() -> AsyncThrowingStream<HostEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let stream = await self.mux.open(endpoint: "$events", payload: .object(["args": .object([:])]))
                do {
                    for try await frame in stream {
                        switch frame {
                        case .item(let value):
                            guard let value else { continue }
                            continuation.yield(HostEvent.decode(value))
                        case .end:
                            continuation.finish()
                            return
                        case .error(let error):
                            continuation.finish(throwing: DSHClientError.remote(error))
                            return
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: MuxClient.asClientError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 应答一条 waterfall 事件。**不答宿主会一直卡住**，所以调用方必须保证
    /// 每条 waterfall 都有且只有一次应答（见 `EventStreamCoordinator`）。
    public func answerEvent(clientId: String, eventId: String, outcome: JSONValue) async throws {
        _ = try await rpc.call(method: "$events/result", payload: [
            "args": .object([
                "clientId": .string(clientId),
                "eventId": .string(eventId),
                "outcome": outcome,
            ])
        ])
    }
}

/// 附件引用。
public struct DSHAttachmentRef: Sendable, Hashable {
    public var attachmentId: String
    public var name: String?
    public var mediaType: String?
    public var byteSize: Int?

    public init(json: JSONValue) {
        attachmentId = json.string("attachmentId") ?? json.string("id") ?? ""
        name = json.string("name")
        mediaType = json.string("mediaType")
        byteSize = json.int("byteSize") ?? json.int("size")
    }

    public var json: [String: JSONValue] {
        var object: [String: JSONValue] = ["attachmentId": .string(attachmentId)]
        if let name { object["name"] = .string(name) }
        if let mediaType { object["mediaType"] = .string(mediaType) }
        if let byteSize { object["byteSize"] = .number(Double(byteSize)) }
        return object
    }
}

/// 工作区文件条目。
public struct WorkspaceFileEntry: Sendable, Identifiable, Hashable {
    public var id: String { path ?? name }
    public var name: String
    public var path: String?
    public var isDirectory: Bool
    public var byteSize: Int?

    public init?(json: JSONValue) {
        guard let name = json.string("name") ?? json.string("path").map({ ($0 as NSString).lastPathComponent }) else { return nil }
        self.name = name
        self.path = json.string("path") ?? json.string("relativePath")
        let kind = json.string("type") ?? json.string("kind") ?? ""
        self.isDirectory = kind == "directory" || kind == "dir" || (json.bool("isDirectory") ?? false)
        self.byteSize = json.int("size") ?? json.int("byteSize")
    }
}
