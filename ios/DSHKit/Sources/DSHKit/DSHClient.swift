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
    private let logger: (any DSHLogSink)?

    public init(
        provider: any DSHHostProvider,
        session: URLSession = .dshShared,
        retry: RetryPolicy = .default,
        logger: (any DSHLogSink)? = nil
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

    /// `session/list` 的**原始返回**。
    ///
    /// 缓存要存它、界面要解它 —— 用同一个值，避免为了缓存再打一次同样的 RPC。
    public func listSessionsValue() async throws -> JSONValue {
        try await rpc.call(method: "session/list", payload: ["args": .object(["_request": .object([:])])])
    }

    /// `session/list`。注意参数家法：DSH 的浏览器客户端发的是 `{"_request":{}}`。
    public func listSessions() async throws -> [SessionSummary] {
        Self.decodeSessionList(try await listSessionsValue())
    }

    /// 把 `session/list` 的原始返回解成会话摘要。
    public static func decodeSessionList(_ value: JSONValue) -> [SessionSummary] {
        let items = value.array("items") ?? value.array("sessions") ?? []
        return items.compactMap(SessionSummary.decode)
    }


    // MARK: - 会话流

    /// `session/follow`。首帧恒为 `snapshot`，其后是 `event` 与（可选）`assistant-stream`。
    public nonisolated func follow(
        sessionId: String,
        assistantStream: Bool = true,
        maxMessages: Int? = 50
    ) -> AsyncThrowingStream<SessionFollowFrame, any Error> {
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
                // **必须绑定量**：不传的话宿主把整份日志一次性推回来，
                // 大会话又慢又占内存，而且 `hasMore` 永远为 false ——
                // 「载入更早的内容」就成了一个点了没反应的按钮（实测）。
                if let maxMessages { request["maxMessages"] = .number(Double(max(1, maxMessages))) }

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
                throw DSHTransportError.malformedResponse(String(localized: "follow 的 event 帧缺少 event"))
            }
            return .event(try SessionEvent.decode(event))
        case "assistant-stream":
            return .assistantStream(AssistantStreamFrame.decode(value))
        default:
            throw DSHTransportError.malformedResponse(String(localized: "未知的 follow 帧：\(value.string("type") ?? "?")"))
        }
    }

    // MARK: - 历史补页

    public struct HistoryPage: Sendable {
        public var events: [SessionEvent]
        public var hasMore: Bool
    }

    /// `session/page`。**必须带 `throughSeq`**（取自 follow 快照的 `cursor`）。
    /// 向上补一页历史。
    ///
    /// **`beforeSeq` 才是"往前翻"的开关。** 返回体里**没有** `cursor` 字段
    /// （实测：`cursor` 是 undefined），所以指望"用返回的游标再翻一页"是不成立的 ——
    /// 游标永远不前进，反复点只会拿回同一页，去重之后等于没动。
    /// 正确的做法是把**手里最老的那条 seq** 传进 `beforeSeq`。
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
    ///
    /// **线上形状是严格的**（读自 `SessionPromptRequest`，本机版本核对过）：
    ///
    /// ```ts
    /// interface SessionPromptRequest {
    ///     requestId: SessionRequestId;
    ///     sessionId: SessionId;
    ///     mode: 'queue' | 'steer';        // ← 必填！少一个字段就是边界校验失败
    ///     content: readonly PromptContentPart[];
    ///     clientTimeZone?: string;
    /// }
    /// type PromptContentPart =
    ///   | { type: 'text';  text: string }
    ///   | { type: 'image'; mediaType: ImageMediaType; data: string; name?: string }  // ← base64 内联
    ///   | { type: 'file';  receiptId: file-upload-receipt-id }
    /// ```
    ///
    /// 两个曾经踩过的坑：
    ///   · `mode` 是必填的。省略它 → `wire field "request" failed boundary validation`，
    ///     表现就是"消息发不出去"。
    ///   · 图片是**内联 base64**，不是附件引用。电脑端收到后自己落盘成 durable attachment。
    ///
    /// - Parameter mode: `queue` 排到下一轮；`steer` 插队给正在跑的这一轮。
    @discardableResult
    public func prompt(
        sessionId: String,
        requestId: String,
        text: String,
        attachments: [PromptAttachment] = [],
        clientTimeZone: String? = TimeZone.current.identifier,
        mode: PromptMode = .queue
    ) async throws -> Bool {
        var content: [JSONValue] = []
        if !text.isEmpty {
            content.append(.object(["type": .string("text"), "text": .string(text)]))
        }
        for attachment in attachments {
            switch attachment {
            case .image(let data, let mediaType, let name):
                var part: [String: JSONValue] = [
                    "type": .string("image"),
                    "mediaType": .string(mediaType),
                    "data": .string(data.base64EncodedString()),
                ]
                if let name, !name.isEmpty { part["name"] = .string(name) }
                content.append(.object(part))
            case .file(let receiptId):
                content.append(.object([
                    "type": .string("file"),
                    "receiptId": .string(receiptId),
                ]))
            }
        }
        var request: [String: JSONValue] = [
            "requestId": .string(requestId),
            "sessionId": .string(sessionId),
            "mode": .string(mode.rawValue),
            "content": .array(content),
        ]
        if let clientTimeZone { request["clientTimeZone"] = .string(clientTimeZone) }

        let value = try await rpc.call(method: "session/prompt", payload: ["args": .object(["request": .object(request)])])
        return value.bool("accepted") ?? false
    }

    /// 打断正在跑的一轮。
    ///
    /// 请求形状只有 `{sessionId}` —— 多发一个字段（比如 `requestId`）就会被边界校验拒掉。
    @discardableResult
    public func cancel(sessionId: String) async throws -> Bool {
        let value = try await rpc.call(method: "session/cancel", payload: [
            "args": .object([
                "request": .object(["sessionId": .string(sessionId)])
            ])
        ])
        // 宿主不保证返回 accepted；没有明确失败就算成功。
        if let accepted = value.bool("accepted") { return accepted }
        return true
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

    /// 建一个会话。
    ///
    /// **传 `workspaceId`，不要只传 `cwd`。** 宿主对 `session.create` 的校验是
    /// "workspaceId 或 cwd 二选一"（两个都给会被拒），而只给 `cwd` 建出来的会话
    /// 在电脑端会落到「未分组」—— 用户看到的就是"选了工作区但不生效"。
    public func createSession(
        workspaceId: String? = nil,
        cwd: String? = nil,
        agentPreset: String? = nil
    ) async throws -> String {
        var request: [String: JSONValue] = [:]
        if let workspaceId { request["workspaceId"] = .string(workspaceId) }
        else if let cwd { request["cwd"] = .string(cwd) }
        if let agentPreset { request["agentPreset"] = .string(agentPreset) }
        let value = try await rpc.call(method: "session/create", payload: ["args": .object(["request": .object(request)])])
        guard let sessionId = value.string("sessionId") else {
            throw DSHClientError.transport(.malformedResponse(String(localized: "session/create 没有返回 sessionId")))
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

    /// 归档一个会话。返回**完整的**已归档集合（宿主是权威，别自己维护增量）。
    @discardableResult
    public func archiveSession(sessionId: String, stopActivity: Bool = false) async throws -> [String] {
        var request: [String: JSONValue] = ["sessionId": .string(sessionId)]
        if stopActivity { request["stopActivity"] = .bool(true) }
        let value = try await rpc.call(method: "workspace/archiveSession", payload: [
            "args": .object(["request": .object(request)])
        ])
        return value.array("archivedSessionIds")?.compactMap(\.stringValue) ?? []
    }

    /// 从归档里恢复。同样返回完整的已归档集合。
    @discardableResult
    public func unarchiveSession(sessionId: String) async throws -> [String] {
        let value = try await rpc.call(method: "workspace/unarchiveSession", payload: [
            "args": .object([
                "request": .object(["sessionId": .string(sessionId)])
            ])
        ])
        return value.array("archivedSessionIds")?.compactMap(\.stringValue) ?? []
    }

    // MARK: - 工作区流

    /// `workspace/follow`：**已归档/已置顶的会话集合只有这一条路能拿到**。
    ///
    /// `session/list` 里没有 `archived` 字段 —— 归档状态属于工作区，不属于会话。
    /// 首帧是 `baseline`（带完整的 `archivedSessionIds`），之后是增量帧
    /// （`archived` / `pinned` / `upsert` / `order`…）。
    public nonisolated func workspaceFollow() -> AsyncThrowingStream<WorkspaceFrame, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let stream = await self.mux.open(endpoint: "workspace/follow", payload: .object(["args": .object([:])]))
                do {
                    for try await frame in stream {
                        switch frame {
                        case .item(let value):
                            guard let value else { continue }
                            continuation.yield(WorkspaceFrame.decode(value))
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

    // MARK: - 模型

    /// `session/modelCatalog`：可用模型清单（按 provider 分组，每个模型带自己的推理强度选项）。
    public func modelCatalog() async throws -> ModelCatalog {
        ModelCatalog.decode(try await rpc.call("session/modelCatalog"))
    }

    /// `session/selectModel`。请求是 `SessionSelectModelRequest extends ModelSelection`，
    /// 也就是**扁平**的 `{sessionId, provider, model, reasoningEffort?}` ——
    /// 套一层 `selection` 会被边界校验拒掉。
    public func selectModel(
        sessionId: String,
        provider: String,
        model: String,
        reasoningEffort: String? = nil
    ) async throws {
        var request: [String: JSONValue] = [
            "sessionId": .string(sessionId),
            "provider": .string(provider),
            "model": .string(model),
        ]
        if let reasoningEffort { request["reasoningEffort"] = .string(reasoningEffort) }
        _ = try await rpc.call(method: "session/selectModel", payload: [
            "args": .object(["request": .object(request)])
        ])
    }

    // MARK: - 主机插件

    /// 主机上的插件清单。
    ///
    /// 线上形状是 `{args: {}}`（这个端点没有参数）。返回里带 `readOnlyReason`，
    /// 说明哪些**不能**开关 —— 不能自己猜哪些可以。
    public func listPlugins() async throws -> [HostPlugin] {
        let value = try await rpc.call(method: "pluginManager/listPlugins", payload: ["args": .object([:])])
        return (value.arrayValue ?? []).map(HostPlugin.init(json:))
    }

    /// 开关一个插件。`id` 用 `entryId`。
    ///
    /// 线上形状：`{args: {id, enabled}}`（实测报错信息直接点名了这两个字段）。
    @discardableResult
    public func setPluginEnabled(id: String, enabled: Bool) async throws -> JSONValue {
        try await rpc.call(method: "pluginManager/setPluginEnabled", payload: [
            "args": .object([
                "id": .string(id),
                "enabled": .bool(enabled),
            ])
        ])
    }

    /// 只取一个会话的投影（`{asOfSeq, values}`）。
    ///
    /// 比 `session/list` 轻得多 —— 统计栏要每几秒刷一次，
    /// 拉整个会话列表（含所有子代理）太浪费。
    public func sessionProjections(sessionId: String) async throws -> JSONValue {
        try await rpc.call(method: "session/projections", payload: [
            "args": .object(["request": .object(["sessionId": .string(sessionId)])])
        ])
    }

    // MARK: - 后台任务

    /// 列出这个会话的后台任务。
    ///
    /// `job/list` 是**流式**接口（帧类型 `{type:'rows', jobs:[…]}`），
    /// 走 mux 载具；这里只取第一帧就收工 —— 我们不需要持续订阅列表。
    public nonisolated func listJobs(sessionId: String) -> AsyncThrowingStream<[BackgroundJob], any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let stream = await self.mux.open(
                    endpoint: "job/list",
                    payload: .object(["args": .object(["request": .object(["sessionId": .string(sessionId)])])])
                )
                do {
                    for try await frame in stream {
                        if case .item(let value) = frame, let value {
                            let jobs = (value.array("jobs") ?? []).map(BackgroundJob.init(json:))
                            continuation.yield(jobs)
                            continuation.finish()
                            return
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 跟一个后台任务的实时输出。
    public nonisolated func followJob(
        jobId: String,
        sessionId: String? = nil,
        from: Int? = nil
    ) -> AsyncThrowingStream<JobFollowFrame, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var request: [String: JSONValue] = ["jobId": .string(jobId)]
                if let sessionId { request["sessionId"] = .string(sessionId) }
                if let from { request["from"] = .number(Double(from)) }
                let stream = await self.mux.open(
                    endpoint: "job/follow",
                    payload: .object(["args": .object(["request": .object(request)])])
                )
                do {
                    for try await frame in stream {
                        guard case .item(let value) = frame, let value else { continue }
                        switch value.string("type") {
                        case "opened":
                            continuation.yield(.opened(
                                job: BackgroundJob(json: value["job"] ?? .object([:])),
                                from: value.int("from") ?? 0
                            ))
                        case "output":
                            let chunks = (value.array("chunks") ?? []).map { chunk in
                                (at: Date(timeIntervalSince1970: (chunk.double("at") ?? 0) / 1000),
                                 text: chunk.string("text") ?? "")
                            }
                            continuation.yield(.output(
                                chunks: chunks,
                                next: value.int("next") ?? 0,
                                lossy: value.bool("lossy") ?? false
                            ))
                        case "status":
                            continuation.yield(.status(BackgroundJob(json: value["job"] ?? .object([:]))))
                        default:
                            continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 停掉一个后台任务。
    public func killJob(sessionId: String, jobId: String) async throws -> String {
        let value = try await rpc.call(method: "job/kill", payload: [
            "args": .object(["request": .object([
                "sessionId": .string(sessionId),
                "jobId": .string(jobId),
            ])])
        ])
        return value.string("outcome") ?? ""
    }

    // MARK: - 斜杠命令

    /// 这个会话可用的斜杠命令。
    ///
    /// 注意是**扁平的 `agentId`**，不是 `{request:{…}}`（实测）。
    public func listCommands(sessionId: String) async throws -> [SlashCommand] {
        let value = try await rpc.call(method: "commands/list", payload: [
            "args": .object(["agentId": .string(sessionId)])
        ])
        return (value.arrayValue ?? []).map(SlashCommand.init(json:))
    }

    // MARK: - 引用（`@`）

    /// `@` 后面能引用哪些**工作区文件**。
    public func fileReferenceCandidates(sessionId: String, query: String) async throws -> [FileReferenceCandidate] {
        let value = try await rpc.call(method: "fileReferences/list", payload: [
            "args": .object([
                "agentId": .string(sessionId),
                "query": .string(query),
            ])
        ])
        return (value.arrayValue ?? []).map(FileReferenceCandidate.init(json:))
    }

    /// `@` 后面能引用哪些**别的会话**。
    public func sessionReferenceCandidates(sessionId: String, query: String) async throws -> [SessionReferenceCandidate] {
        let value = try await rpc.call(method: "sessionReferenceResolver/candidates", payload: [
            "args": .object([
                "agentId": .string(sessionId),
                "query": .string(query),
            ])
        ])
        return (value.arrayValue ?? []).map(SessionReferenceCandidate.init(json:))
    }

    // MARK: - 定时提醒

    /// 这个会话的定时提醒。
    public func listSchedules(sessionId: String) async throws -> [Reminder] {
        let value = try await rpc.call(method: "schedule/list", payload: [
            "args": .object(["request": .object(["sessionId": .string(sessionId)])])
        ])
        return (value.arrayValue ?? []).map(Reminder.init(json:))
    }

    /// 全部提醒（`schedule/catalog`，不分会话）。
    public func scheduleCatalog() async throws -> [Reminder] {
        let value = try await rpc.call(method: "schedule/catalog", payload: ["args": .object([:])])
        return (value.arrayValue ?? []).map(Reminder.init(json:))
    }

    /// 删掉一条提醒。`expected` 是乐观并发控制要的**原记录**。
    @discardableResult
    public func deleteSchedule(id: String, expected: JSONValue) async throws -> Bool {
        let value = try await rpc.call(method: "schedule/delete", payload: [
            "args": .object(["request": .object([
                "id": .string(id),
                "expected": expected,
            ])])
        ])
        return value.bool("deleted") ?? value.bool("ok") ?? false
    }

    // MARK: - 会话搜索

    /// 全文搜索历史会话。
    ///
    /// **主机可能禁用**：本机就返回
    /// `session search is disabled: this deployment configures the session-query index with openAt "never"`。
    /// 这是部署配置（`dsh-session-query-sqlite` 的 `openAt`，默认是 `startup`），
    /// 不是 App 能改的 —— 所以调用方要把这个错误**翻译成人话**。
    public func searchSessions(query: String, limit: Int = 30) async throws -> [SessionSearchHit] {
        let value = try await rpc.call(method: "session/search", payload: [
            "args": .object(["request": .object([
                "query": .string(query),
                "limit": .number(Double(limit)),
            ])])
        ])
        return (value.array("hits") ?? value.arrayValue ?? []).map(SessionSearchHit.init(json:))
    }

    // MARK: - 凭据（API 密钥）

    /// 查这些 ref 配了没有。
    ///
    /// **值永远不会回传** —— 线上只给 `{configured, source?, writable}`。
    /// 这就是"密文存储"：密钥存在电脑端的凭据库里，手机只能知道"配过没有"。
    public func credentialsDescribe(refs: [String]) async throws -> [String: CredentialInfo] {
        let value = try await rpc.call(method: "credentials/describe", payload: [
            "args": .object(["refs": .array(refs.map { .string($0) })])
        ])
        guard let object = value.objectValue else { return [:] }
        return object.mapValues(CredentialInfo.init(json:))
    }

    /// 写入一个密钥。走的是**已经端到端加密的 iroh 通道**，
    /// 落到电脑端的凭据库；之后只能查到"配过没有"，读不回原文。
    public func credentialsSet(ref: String, value: String) async throws {
        _ = try await rpc.call(method: "credentials/set", payload: [
            "args": .object(["ref": .string(ref), "value": .string(value)])
        ])
    }

    /// 删掉一个密钥。
    public func credentialsUnset(ref: String) async throws {
        _ = try await rpc.call(method: "credentials/unset", payload: [
            "args": .object(["ref": .string(ref)])
        ])
    }

    // MARK: - 排队消息

    /// 对一条**排队中**的消息做点什么。
    ///
    /// 线上形状：`{sessionId, itemId, action}`，其中 `itemId` 是**服务端那条消息的 id**
    /// （不是本地的 rpcId）；`action` 是三选一：
    ///   · `{kind:'edit', content:[{type:'text',text}]}` —— 改内容；
    ///   · `{kind:'remove'}` —— 删掉；
    ///   · `{kind:'steer'}` —— **插进正在跑的这一轮**（桌面那个 ↑ 按钮）。
    @discardableResult
    public func updateQueue(sessionId: String, itemId: String, action: QueueAction) async throws -> JSONValue {
        try await rpc.call(method: "session/updateQueue", payload: [
            "args": .object(["request": .object([
                "sessionId": .string(sessionId),
                "itemId": .string(itemId),
                "action": action.json,
            ])])
        ])
    }

    // MARK: - Agent preset

    /// 可选的 agent preset（建会话时用）。
    public func agentPresets() async throws -> [AgentPreset] {
        AgentPreset.decodeList(
            try await rpc.call(method: "agentPresets/list", payload: ["args": .object([:])])
        )
    }

    // MARK: - 消息评价

    /// 读这个会话已有的评价（按 messageId）。
    public func messageFeedback(sessionId: String) async throws -> [MessageFeedback] {
        let value = try await rpc.call(method: "messageFeedback/list", payload: [
            "args": .object(["request": .object(["sessionId": .string(sessionId)])])
        ])
        // 业务结果外面还包了一层 `{ok, value}`。
        let inner = value["value"] ?? value
        return (inner.array("items") ?? []).map(MessageFeedback.init(json:))
    }

    /// 点赞/点踩一条消息。
    ///
    /// `ifVersion` 传上次读到的版本；没有就传 `null`（**必填字段，不能省略**）。
    @discardableResult
    public func putMessageFeedback(
        sessionId: String,
        messageId: String,
        rating: MessageFeedbackRating,
        ifVersion: String?
    ) async throws -> MessageFeedback? {
        var request: [String: JSONValue] = [
            "sessionId": .string(sessionId),
            "messageId": .string(messageId),
            "rating": .string(rating.rawValue),
            "ifVersion": ifVersion.map { .string($0) } ?? .null,
        ]
        if request["ifVersion"] == .null { request["ifVersion"] = .null }
        let value = try await rpc.call(method: "messageFeedback/put", payload: [
            "args": .object(["request": .object(request)])
        ])
        // **业务级拒绝也是 200**：`{ok:false, error:{code,current?}}`。
        // 最典型的是 `version-conflict` —— 别人在你之后改过。不显式抛出来的话
        // 调用方会以为"保存成功了"，而实际上什么都没写。
        try Self.throwIfBusinessRejected(value, fallbackMessage: String(localized: "评价被拒"))
        return MessageFeedback(json: value["value"] ?? value)
    }

    /// 撤销评价。
    @discardableResult
    public func deleteMessageFeedback(
        sessionId: String,
        messageId: String,
        ifVersion: String
    ) async throws -> Bool {
        let value = try await rpc.call(method: "messageFeedback/delete", payload: [
            "args": .object(["request": .object([
                "sessionId": .string(sessionId),
                "messageId": .string(messageId),
                "ifVersion": .string(ifVersion),
            ])])
        ])
        try Self.throwIfBusinessRejected(value, fallbackMessage: String(localized: "撤销评价被拒"))
        let inner = value["value"] ?? value
        return inner.bool("absent") ?? false
    }

    /// 业务结果里 `{ok:false, error:{…}}` 要当成错误抛出去。
    ///
    /// DSH 的业务错误走 HTTP 200，只检查传输层会漏掉它们。
    static func throwIfBusinessRejected(_ value: JSONValue, fallbackMessage: String) throws {
        guard value.bool("ok") == false else { return }
        let error = value["error"] ?? .object([:])
        throw DSHClientError.remote(DSHError(
            code: error.string("code") ?? "business/rejected",
            message: error.string("message") ?? fallbackMessage
        ))
    }

    // MARK: - 分支

    /// 从某条消息处**分叉**出一个新会话。
    ///
    /// 线上形状：`session/fork({sessionId, atSeq?}) → {sessionId}`。
    /// `atSeq` 省略就是从当前位置分叉。
    @discardableResult
    public func forkSession(sessionId: String, atSeq: Int?) async throws -> String {
        var request: [String: JSONValue] = ["sessionId": .string(sessionId)]
        if let atSeq { request["atSeq"] = .number(Double(atSeq)) }
        let value = try await rpc.call(method: "session/fork", payload: [
            "args": .object(["request": .object(request)])
        ])
        guard let id = value.string("sessionId"), !id.isEmpty else {
            throw DSHTransportError.malformedResponse(String(localized: "fork 没有返回 sessionId"))
        }
        return id
    }

    // MARK: - 主机插件包

    /// 主机上的插件**包**清单。
    ///
    /// 界面展示这一层：`listPlugins` 是包里的单个插件（本机 202 条），
    /// 平铺出来没法看；这里是包（本机 17 条），每个带人类可读的标题与说明。
    public func listBundles() async throws -> [HostBundle] {
        let value = try await rpc.call(method: "pluginManager/listBundles", payload: ["args": .object([:])])
        // 写成闭包而不是 `map(HostBundle.init(json:))`：`init` 带上默认参数之后
        // 就没法再当函数值用（默认参数不参与函数引用）。
        return (value.arrayValue ?? []).map { HostBundle(json: $0) }
    }

    /// 开关一个插件包。`name` 用包的 `name`。
    @discardableResult
    public func setBundleEnabled(name: String, enabled: Bool) async throws -> JSONValue {
        try await rpc.call(method: "pluginManager/setBundleEnabled", payload: [
            "args": .object([
                "name": .string(name),
                "enabled": .bool(enabled),
            ])
        ])
    }

    // MARK: - 主机设置

    /// 读取主机的设置命名空间（`settings/describe`）。
    public func settings() async throws -> SettingsSnapshot {
        SettingsSnapshot.decode(try await rpc.call(method: "settings/describe", payload: ["args": .object([:])]))
    }

    /// 改一个设置命名空间里的值。
    ///
    /// 线上形状：`{args: {ns, ops:[{op:"set", path:[…], value}], expectedRevision}}`。
    /// `expectedRevision` 是乐观并发控制 —— 传上一份快照的 revision，
    /// 别人在你之后改过就会被拒，而不是悄悄覆盖掉。
    public func mutateSettings(
        namespace: String,
        operations: [(op: String, path: [String], value: JSONValue?)],
        expectedRevision: Int?
    ) async throws -> SettingsNamespace {
        var args: [String: JSONValue] = [
            "ns": .string(namespace),
            "ops": .array(operations.map { operation in
                // `SettingsPathOpView` 是个**严格联合**：`{op:'set',path,value}` 或
                // `{op:'unset',path}`。给 `unset` 多带一个 `value` 会被拒，
                // 所以 value 是可选的、`unset` 时不带。
                var object: [String: JSONValue] = [
                    "op": .string(operation.op),
                    "path": .array(operation.path.map { .string($0) }),
                ]
                if let value = operation.value { object["value"] = value }
                return .object(object)
            }),
        ]
        if let expectedRevision { args["expectedRevision"] = .number(Double(expectedRevision)) }
        let value = try await rpc.call(method: "settings/mutate", payload: ["args": .object(args)])
        return SettingsNamespace(json: value, isWritable: true)
    }

    // MARK: - 权限档位

    /// 可选的权限档位（`permissionPresets/catalog`，只读）。
    public func permissionPresets() async throws -> PermissionPresetCatalog {
        PermissionPresetCatalog.decode(try await rpc.call("permissionPresets/catalog"))
    }

    /// 执行一条**斜杠命令**。
    ///
    /// 权限档位的"写"走的就是这条路：`dsh-permission-presets` 注册了一个
    /// `permission` 命令（`/permission <preset>`，不带参数则打印当前档位）。
    /// 线上形状是 `{args: {agentId, line, submittedAttachments}}` ——
    /// agent scope 是**放进 args 里**的，放到 payload 顶层会被拒
    /// （`Remote payload must contain exactly one plain-object args field`）。
    ///
    /// 这是 DSH 客户端协议里**唯一**能改权限的入口：`permissionPresets` 只暴露
    /// `catalog`（只读），直接写回去要走 `settings/*`（那是全局默认值，不是当前会话）。
    @discardableResult
    public func executeCommand(sessionId: String, line: String) async throws -> CommandExecution {
        let value = try await rpc.call(method: "commands/execute", payload: [
            "args": .object([
                "agentId": .string(sessionId),
                "line": .string(line),
                "submittedAttachments": .array([]),
            ])
        ])
        return CommandExecution.decode(value)
    }


    /// 切换当前会话的权限档位。
    @discardableResult
    public func selectPermissionPreset(sessionId: String, preset: String) async throws -> CommandExecution {
        try await executeCommand(sessionId: sessionId, line: "/permission \(preset)")
    }

    // MARK: - 图片与文件

    /// 提交时的附件。**形状与线上契约一一对应**（见 `prompt` 的说明）。
    public enum PromptAttachment: Sendable {
        /// 图片：线上要 base64 内联。
        case image(data: Data, mediaType: String, name: String? = nil)
        /// 文件：只带上传拿到的 receiptId。
        case file(receiptId: String)
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
            throw DSHClientError.transport(.malformedResponse(String(localized: "附件数据不是合法 base64")))
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
            throw DSHClientError.transport(.malformedResponse(String(localized: "无法构造上传 URL")))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        for (name, value) in await provider.requestHeaders() {
            request.setValue(value, forHTTPHeaderField: name)
        }
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
                message: error.string("message") ?? String(localized: "上传失败"),
                details: error["details"] ?? .object([:])
            ))
        }
        let payload = value["value"] ?? .null
        guard let receiptId = payload.string("receiptId") else {
            throw DSHClientError.transport(.malformedResponse(String(localized: "上传结果缺少 receiptId")))
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


    /// `workspaceFiles/stat`：文件元信息。
    ///
    /// **`range` / `options` 这类字段是"必填但可为空对象"** —— 省略会被描述符校验拒
    /// （`missing "range"`），传 `null` 也会被拒（`wire field "range" failed boundary
    /// validation`），只有传 `{}` 才过。这是实测出来的，别照直觉写成"可选就省掉"。
    public func statFile(scopeId: String, path: String) async throws -> WorkspaceFileStat {
        let args: [String: JSONValue] = [
            "workspaceFileScopeId": .string(scopeId),
            "path": .string(path),
        ]
        let value = try await rpc.call(method: "workspaceFiles/stat", payload: ["args": .object(args)])
        return WorkspaceFileStat(json: value)
    }

    /// `workspaceFiles/read`：读文本。
    ///
    /// **`range` 必须发**（哪怕是个空对象）。之前这里是 `if let range { … }`，
    /// 不传 range 时字段缺失 → 宿主报 `missing "range"` → 所有"点开文件看看"的
    /// 功能（工作区文件、交付产物）全都打不开。实测：`range: {}` 就是"整个文件"。
    ///
    /// 路径**相对与绝对都收**（实测），但相对路径要能对上 scope 所属工作区。
    @discardableResult
    public func readFile(
        scopeId: String,
        path: String,
        range: JSONValue? = nil,
        limit: Int? = nil
    ) async throws -> WorkspaceFileText {
        var args: [String: JSONValue] = [
            "workspaceFileScopeId": .string(scopeId),
            "path": .string(path),
            // 必填：空对象 = 从头读到尾（宿主自己会给一个默认窗口）。
            "range": range ?? .object([:]),
        ]
        if let limit { args["limit"] = .number(Double(limit)) }
        let value = try await rpc.call(method: "workspaceFiles/read", payload: ["args": .object(args)])
        return WorkspaceFileText(json: value)
    }

    /// 只要文本的便捷入口（老调用点的形状）。
    public func readFileText(scopeId: String, path: String) async throws -> String {
        try await readFile(scopeId: scopeId, path: path).text
    }

    /// `workspaceFiles/readBytes`：读**原始字节**（图片、PDF 这类要交给系统预览的）。
    ///
    /// 这个端点的响应**不是 JSON**，而是 `multipart/form-data`：一个 `bytes-0` part
    /// 装原始字节、一个 `metadata` part 装 JSON 元信息。所以不能走 `rpc.call`
    ///（那条路只解 JSON），得自己发请求并解 multipart。
    ///
    /// `options` 与 `read` 的 `range` 同理：**必填，但传 `{}` 即可**。
    public func readFileBytes(scopeId: String, path: String, options: JSONValue = .object([:])) async throws -> Data {
        let base = try await provider.baseURL()
        var request = URLRequest(url: DSHAPI.url(base: base, method: "workspaceFiles/readBytes"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in await provider.requestHeaders() {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.timeoutInterval = 60
        let envelope: JSONValue = .object([
            "type": .string("client-request"),
            "rpcId": .string(RpcId.make()),
            "method": .string("workspaceFiles/readBytes"),
            "payload": .object([
                "args": .object([
                    "workspaceFileScopeId": .string(scopeId),
                    "path": .string(path),
                    "options": options,
                ])
            ]),
        ])
        request.httpBody = try JSONEncoder.dshCompact.encode(envelope)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DSHClientError.transport(.malformedResponse(String(localized: "读文件没有拿到 HTTP 响应")))
        }
        guard http.statusCode == 200 else {
            throw DSHClientError.transport(.http(
                status: http.statusCode,
                body: String(data: data.prefix(200), encoding: .utf8) ?? ""
            ))
        }
        guard let contentType = http.value(forHTTPHeaderField: "Content-Type"),
              let boundary = Self.multipartBoundary(in: contentType)
        else {
            // 不是 multipart：多半是"业务错误也是 200"的那种 JSON 错误体。
            if let value = try? JSONDecoder.dsh.decode(JSONValue.self, from: data),
               value.bool("ok") == false {
                throw Self.remoteError(from: value) ?? DSHClientError.transport(.malformedResponse(
                    String(localized: "读文件失败")
                ))
            }
            throw DSHClientError.transport(.malformedResponse(
                String(localized: "读文件的响应不是 multipart")
            ))
        }
        guard let bytes = Self.multipartPart(named: "bytes-0", in: data, boundary: boundary) else {
            throw DSHClientError.transport(.malformedResponse(
                String(localized: "读文件的响应里没有文件内容")
            ))
        }
        return bytes
    }

    /// 从 `Content-Type: multipart/form-data; boundary=xxx` 里抠出 boundary。
    static func multipartBoundary(in contentType: String) -> String? {
        for piece in contentType.split(separator: ";") {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("boundary=") else { continue }
            var value = String(trimmed.dropFirst("boundary=".count))
            if value.hasPrefix("\"") , value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// 取 multipart 里某个 name 的 part 内容（原始字节，不做任何解码）。
    ///
    /// 手写而不是引第三方：只有"一个二进制 part + 一个 JSON part"这一种形状，
    /// 而且**不能用 `String` 中转**（图片字节不是合法 UTF-8，一转就毁）。
    static func multipartPart(named name: String, in data: Data, boundary: String) -> Data? {
        // 分隔符在正文里是 `--<boundary>`；首尾各有一个。
        let delimiter = Data("--\(boundary)".utf8)
        let headerEnd = Data("\r\n\r\n".utf8)
        var searchStart = data.startIndex

        while let delimiterRange = data.range(of: delimiter, in: searchStart..<data.endIndex) {
            var partStart = delimiterRange.upperBound
            // 跳过分隔符后的 CRLF
            if partStart < data.endIndex, data[partStart] == 0x0D {
                partStart = data.index(after: partStart)
            }
            if partStart < data.endIndex, data[partStart] == 0x0A {
                partStart = data.index(after: partStart)
            }
            guard let headerRange = data.range(of: headerEnd, in: partStart..<data.endIndex) else { break }
            let headerText = String(decoding: data[partStart..<headerRange.lowerBound], as: UTF8.self)
            let bodyStart = headerRange.upperBound

            // 找这个 part 的结束（下一个分隔符），并去掉它前面的 CRLF。
            guard let nextDelimiter = data.range(of: delimiter, in: bodyStart..<data.endIndex) else { break }
            var bodyEnd = nextDelimiter.lowerBound
            if bodyEnd > bodyStart, data[data.index(before: bodyEnd)] == 0x0A {
                bodyEnd = data.index(before: bodyEnd)
                if bodyEnd > bodyStart, data[data.index(before: bodyEnd)] == 0x0D {
                    bodyEnd = data.index(before: bodyEnd)
                }
            }

            if headerText.contains("name=\"\(name)\"") {
                return data.subdata(in: bodyStart..<bodyEnd)
            }
            // 不是要找的 part：从**这个**分隔符继续（不是它的后面）——
            // 那个分隔符正是下一段的开头。写成 `upperBound` 会把下一段整个跳过，
            // 于是"要找的 part 排在第二个"时永远找不到（单测钉住了这一点）。
            searchStart = nextDelimiter.lowerBound
        }
        return nil
    }

    /// 把 `{"result":{"ok":false,"error":…}}` 解成远端错误。
    static func remoteError(from value: JSONValue) -> DSHClientError? {
        guard let error = value["error"] else { return nil }
        return .remote(DSHError(
            code: error.string("code") ?? "unknown",
            message: error.string("message") ?? String(localized: "远端返回了一个错误")
        ))
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

/// `workspaceFiles/stat` 的结果。用来在打开之前判断"这个文件还在不在、多大"。
public struct WorkspaceFileStat: Sendable, Hashable {
    /// 宿主解析出来的绝对路径 —— 拿它去 `read` 最稳。
    public var absolutePath: String?
    public var byteSize: Int?
    /// 宿主的版本戳（内容变了它就变）。诊断用。
    public var version: String?

    public init(json: JSONValue) {
        self.absolutePath = json.string("absolutePath")
        self.byteSize = json.int("bytes") ?? json.int("size") ?? json.int("byteSize")
        self.version = json.string("version")
    }
}

/// `workspaceFiles/read` 的结果。
public struct WorkspaceFileText: Sendable, Hashable {
    public var text: String
    public var absolutePath: String?
    /// 文件**总字节数**（不是这次返回的窗口大小）。
    public var byteSize: Int?
    public var lines: Int?
    /// 这次返回的是不是已经到文件末尾。
    public var isEOF: Bool
    /// 这次窗口从第几行开始。
    public var offset: Int?

    public init(json: JSONValue) {
        self.text = json.string("text") ?? json.string("content") ?? ""
        self.absolutePath = json.string("absolutePath")
        self.byteSize = json.int("bytes") ?? json.int("size") ?? json.int("byteSize")
        self.lines = json.int("lines")
        self.isEOF = json.bool("eof") ?? true
        self.offset = json.int("offset")
    }
}
