import DSHKit
import Foundation
import Observation
import SwiftUI

/// 一个会话的时间线状态。
///
/// 三条硬要求（docs/DESIGN.md §4.4、docs/IOS-DESIGN.md §4 S2）：
///   1. **快照可能很大**（实测 831 KB）→ 先出骨架，再分批入视图，不阻塞首帧；
///   2. **流式追加不错位、不重复** → 实时项与持久事件复用同一个 id（TimelineBuilder 保证）；
///   3. **断线重连按 seq 补齐** → 重订阅后用自己的 `lastSeq` 过滤掉重复事件。
@MainActor
@Observable
public final class SessionModel {
    let sessionId: String
    /// 通过 AppModel 拿 client，而不是在初始化时抓一份引用。
    ///
    /// 传输掉线重连后 AppModel 会换一个 `DSHClient`（本地代理端口可能变、旧的 WS 全死），
    /// 抓着旧引用的话重订阅会一直失败 —— 表现就是"界面永远在重连"。
    private unowned let appModel: AppModel
    private var client: DSHClient { appModel.client }
    private let settings: AppSettings
    private let logs: MemoryLogSink

    // MARK: 时间线

    private var builder = TimelineBuilder()
    private(set) var items: [TimelineItem] = []
    /// 被 `surfaceOp.replace` 遮住的条目：默认收进"已被压缩取代"，仍可回溯。
    private(set) var shadowedItems: [TimelineItem] = []

    // MARK: 状态

    enum Phase: Equatable {
        case idle
        case loading
        case live
        case reconnecting(String)
        case failed(String)

        var isLive: Bool { if case .live = self { return true }; return false }
    }

    private(set) var phase: Phase = .idle
    private(set) var isTurnRunning = false
    private(set) var isStreaming = false
    private(set) var hasMoreHistory = false
    private(set) var isLoadingHistory = false
    private(set) var lastSeq: Double = -1
    private(set) var title: String = ""
    private(set) var modelLabel: String = ""
    /// 这个会话当前用的模型（`projections.modelSelection` 的 `next`/`lastUsed`）。
    /// 模型页拿它做初始选中项。
    private(set) var modelSelection: ModelSelection?
    /// 这个会话当前的文件读写/审批档位（`projections.permissions.currentValue`）。
    private(set) var currentPermission: String?
    /// 排队中的消息（`projections.inbox`）。
    ///
    /// 队列**不在会话日志里** —— 实测：轮次跑着的时候发一条，日志里一条 `user/message`
    /// 都没有，它只出现在这个投影里。所以想显示"排队中"，唯一的数据来源是它。
    private(set) var queuedMessages: [QueuedMessage] = []
    /// 已经结束的轮次。
    ///
    /// 用它决定"思考过程要不要收起来" —— 用户要的是**输出最终结果之后**才收，
    /// 跑的过程中仍然可以看（那时候推理正是有用的实时反馈）。
    /// 在 `publish()` 里算一次，别在每一行的渲染里遍历整个时间线。
    private(set) var completedTurns: Set<Int> = []
    /// 按轮次分组后的渲染块。在 `publish()` 里算一次。
    private(set) var timelineBlocks: [TimelineBlock] = []
    private(set) var contextPressure: ContextPressure?
    private(set) var todos: [TimelineItem.TodoEntry] = []

    /// 上一次跟随失败的提示（给"所有失败都要有文案"这条）。
    private(set) var failureMessage: String?

    // MARK: 输入区

    var draft: String = ""
    private(set) var attachments: [PendingAttachment] = []

    struct PendingAttachment: Identifiable, Sendable, Equatable {
        let id = UUID()
        var name: String
        var mediaType: String
        var data: Data
        var thumbnail: Data?

        var isImage: Bool { mediaType.hasPrefix("image/") }
        var byteCount: Int { data.count }
    }

    // MARK: 内部

    private var followTask: Task<Void, Never>?
    private var generationTask: Task<Void, Never>?
    /// 本次打开是不是先用缓存铺出来的。决定快照到达时走"续拉"还是"整体重建"。
    private var restoredFromCache = false
    private var backgroundObserver: (any NSObjectProtocol)?
    private var reconnectAttempt = 0
    private var pendingPromptRpcId: String?

    init(sessionId: String, title: String, appModel: AppModel) {
        self.sessionId = sessionId
        self.title = title
        self.appModel = appModel
        self.settings = appModel.settings
        self.logs = appModel.logs
    }

    // MARK: 打开 / 关闭

    func open() async {
        guard followTask == nil else { return }
        phase = .loading

        // 先用缓存把内容铺出来 —— 这一步是"切换会话不用等"的全部意义。
        if let cached = await appModel.sessionCache.session(for: sessionId),
           let restored = TimelineBuilder(state: cached.timeline) {
            builder = restored
            if !cached.title.isEmpty { title = cached.title }
            currentPermission = cached.permission
            lastSeq = cached.timeline.lastSeq
            restoredFromCache = true
            publish()
            // 内容已经在屏幕上了，就别再显示加载骨架。
            phase = .live
            logs.log(.debug, "会话 \(sessionId.prefix(12))… 命中缓存（\(builder.items.count) 条，seq \(Int(lastSeq))）")
        }

        observeBackgroundSave()
        observeTransportGeneration()
        await subscribe()
    }

    func close() {
        followTask?.cancel()
        followTask = nil
        generationTask?.cancel()
        generationTask = nil
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
            self.backgroundObserver = nil
        }
        // 切走时落盘 —— 这正是"下次切回来要等远程加载"的那一次。
        saveToCache()
    }

    /// 退到后台也落盘：App 可能在后台被系统回收，回来时不该白等一次远程快照。
    private func observeBackgroundSave() {
        guard backgroundObserver == nil else { return }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveToCache() }
        }
    }

    private func saveToCache() {
        guard builder.lastSeq >= 0 else { return }
        let cached = SessionCache.CachedSession(
            timeline: builder.state,
            title: title,
            permission: currentPermission
        )
        let sessionId = sessionId
        Task { [appModel] in
            await appModel.sessionCache.store(cached, for: sessionId)
        }
    }

    /// 传输重连后 AppModel 会换一个 `DSHClient`（端口可能变、旧 WS 全死）。
    /// 这里盯着它的世代计数器，一变就**立刻**重订阅 —— 不等自己那套退避慢慢转过来，
    /// 否则用户会看到"电脑上刚发的消息，手机上要等好几秒才出现"。
    private func observeTransportGeneration() {
        generationTask?.cancel()
        generationTask = Task { [weak self] in
            guard let self else { return }
            var last = -1
            for await generation in await self.appModel.generationUpdates() {
                if Task.isCancelled { return }
                defer { last = generation }
                guard last >= 0, generation != last else { continue }
                // 重连后按已有的 lastSeq 续拉：宿主的快照会重放，用 seq 去重。
                await self.subscribe()
            }
        }
    }

    private func subscribe() async {
        followTask?.cancel()
        let resumeAfter = lastSeq
        followTask = Task { [weak self] in
            guard let self else { return }
            await self.runFollow(resumeAfter: resumeAfter)
        }
    }

    private func runFollow(resumeAfter: Double) async {
        var sawSnapshot = false
        do {
            for try await frame in client.follow(sessionId: sessionId, assistantStream: true) {
                if Task.isCancelled { return }
                switch frame {
                case .snapshot(let snapshot):
                    sawSnapshot = true
                    await applySnapshot(snapshot)
                case .event(let event):
                    // 重连后宿主会把快照重放一遍；用自己的 lastSeq 去重。
                    guard event.seq > lastSeq else { continue }
                    apply(event)
                case .assistantStream(let streamFrame):
                    applyStream(streamFrame)
                }
                reconnectAttempt = 0
            }
            if !Task.isCancelled {
                await handleDisconnect(reason: String(localized: "电脑端结束了这条会话流"), sawSnapshot: sawSnapshot)
            }
        } catch {
            if Task.isCancelled { return }
            let message = (error as? DSHClientError)?.displayMessage ?? error.localizedDescription
            await handleDisconnect(reason: message, sawSnapshot: sawSnapshot)
        }
    }

    private func applySnapshot(_ snapshot: SessionSnapshot) async {
        // 命中缓存时走**增量续拉**：快照只带最近 N 条消息，而我们手里有更早的。
        // 整体重建会把用户已经翻过的历史丢掉，也会白等一次全量折叠。
        if restoredFromCache, builder.resume(with: snapshot) {
            restoredFromCache = false
            applyProjections(snapshot.projections)
            hasMoreHistory = snapshot.hasMore
            lastSeq = max(lastSeq, Double(snapshot.cursor))
            phase = .live
            publish()
            saveToCache()
            return
        }
        restoredFromCache = false
        builder = TimelineBuilder()
        items = []
        shadowedItems = []
        lastSeq = -1
        // 先出骨架：把标题/投影立刻落到界面上，再分批折叠事件。
        hasMoreHistory = snapshot.hasMore
        applyProjections(snapshot.projections)
        publish()

        let events = snapshot.events
        let chunkSize = 120
        var index = 0
        while index < events.count {
            if Task.isCancelled { return }
            let end = min(index + chunkSize, events.count)
            for event in events[index..<end] {
                _ = builder.apply(event)
            }
            index = end
            publish()
            // 让出一次主线程：831 KB 的快照要"边到边渲染"，不能等全部解码完。
            await Task.yield()
        }
        lastSeq = max(lastSeq, Double(snapshot.cursor))
        phase = .live
        isTurnRunning = false
        publish()
        // 快照分完了：这时候布局才稳定，明确要求滚到底一次。
        requestScrollToBottom()
        saveToCache()
    }

    private func apply(_ event: SessionEvent) {
        let delta = builder.apply(event)
        lastSeq = max(lastSeq, event.seq)
        // 标题是**事件**推过来的（`session/title`），不是只在投影里。
        // 不处理它的话，自动生成的标题永远反映不到 App 上
        // （用户看到的就是新建的会话一直显示 `session-xxxx`）。
        if event.type == "session/title", let newTitle = event.string("data.title"), !newTitle.isEmpty {
            title = newTitle
        }
        if event.type == "turn/start" { isTurnRunning = true }
        if event.type == "turn/end" { isTurnRunning = false }
        if event.type == "step/end" { isStreaming = false }
        _ = delta
        publish()
    }

    private func applyStream(_ frame: AssistantStreamFrame) {
        let delta = builder.apply(assistantStream: frame)
        switch frame {
        case .start:
            isStreaming = true
        case .end:
            isStreaming = false
        default:
            break
        }
        if !delta.isEmpty {
            if case .chunk = frame { isStreaming = true }
            publish()
        }
    }

    private func applyProjections(_ projections: JSONValue) {
        let values = projections["values"] ?? .object([:])
        if let title = values.string("title"), !title.isEmpty { self.title = title }
        if let pressure = values["contextPressure"] {
            contextPressure = ContextPressure(json: pressure)
        }
        if let value = values.string("permissions.currentValue") ?? values["permissions"]?.string("currentValue") {
            currentPermission = value
        }
        let inbox = InboxState(json: values["inbox"] ?? .object([:]))
        if inbox.total != queuedMessages.count || inbox.nextTurn.map(\.id) != queuedMessages.map(\.id) {
            publishQueuedMessages(inbox)
        }
        if let raw = values["modelSelection"] {
            // 嵌套形状：`{lastUsed: {...}, next: {...}}`。当扁平读会永远拿到空值。
            let chosen = raw["next"] ?? raw["lastUsed"] ?? raw
            let selection = ModelSelection(json: chosen)
            if !selection.provider.isEmpty || !selection.model.isEmpty {
                modelSelection = selection
                modelLabel = selection.model.isEmpty ? selection.provider : selection.model
            }
        }
        todos = (values.array("todos") ?? []).map {
            TimelineItem.TodoEntry(text: $0.string("content") ?? "", status: .init(raw: $0.string("status")))
        }
        if let running = values["sessionStats"]?.int("turns") { _ = running }
    }

    private func publish() {
        let conversational = builder.conversationalItems
        let visible = settings.showRawEvents ? builder.items : conversational
        items = visible
        shadowedItems = visible.filter(\.isShadowed)
        completedTurns = Set(builder.items.compactMap { item in
            if case .turnEnd(let turn, _) = item.kind { return turn }
            return nil
        })
        timelineBlocks = builder.timelineBlocks(showRawEvents: settings.showRawEvents)
    }

    /// 每次"应该滚到底"时自增。View 观察它做一次 `scrollTo`。
    ///
    /// 为什么不能只靠"最后一条 item 变了就滚"：快照是分批入视图的，分批期间
    /// 布局还没稳定，`scrollTo` 会落在半路上；而分完之后最后一条又不一定再变。
    /// 所以由模型显式发一个"滚到底"的信号。
    private(set) var scrollToBottomTicket = 0

    /// 补完历史后要滚到哪一条。视图观察 `historyScrollTicket` 做一次 `scrollTo`。
    ///
    /// 没有它的话，补进来的内容全在视口**上方**，屏幕上一点变化都没有 ——
    /// 用户会以为按钮坏了（实测就是）。
    private(set) var historyScrollTarget: String?
    private(set) var historyScrollTicket = 0

    func requestScrollToBottom() {
        scrollToBottomTicket &+= 1
    }

    // MARK: 断线与补齐

    private func handleDisconnect(reason: String, sawSnapshot: Bool) async {
        guard !Task.isCancelled else { return }
        isStreaming = false
        reconnectAttempt += 1
        let wait = RetryPolicy.default.delay(afterAttempt: reconnectAttempt)
        phase = .reconnecting(reason)
        logs.log(.warning, "会话流断开：\(reason)，\(wait.formatted) 后重订阅")

        try? await Task.sleep(for: wait)
        guard !Task.isCancelled else { return }
        phase = sawSnapshot ? .live : .loading
        await subscribe()
    }

    // MARK: 补历史

    /// 向上补一页历史。
    ///
    /// 两个曾经让它"点了没反应"的坑：
    ///   1. 用返回的游标翻页 —— 返回体里**没有 `cursor`**，游标永远不前进，
    ///      反复点只会拿回同一页（去重后等于没动）。现在用**手里最老的 seq** 当 `beforeSeq`。
    ///   2. 新内容插在**视口上方**而滚动位置不动 —— 屏幕上什么都不会变。
    ///      所以补完要给出一个滚动目标（`historyScrollTarget`）。
    func loadOlderHistoryIfNeeded() async {
        guard hasMoreHistory, !isLoadingHistory else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }

        guard let oldest = builder.items.first?.seq, oldest > 0 else {
            hasMoreHistory = false
            return
        }
        do {
            let page = try await client.page(
                sessionId: sessionId,
                throughSeq: builder.cursor,
                beforeSeq: Int(oldest),
                maxMessages: 50
            )
            guard !page.events.isEmpty else {
                hasMoreHistory = false
                return
            }
            let delta = builder.prepend(page: page.events)
            hasMoreHistory = page.hasMore
            publish()
            // 让视图滚到新内容的第一条 —— 否则它插在视口上方，看起来什么都没发生。
            if let first = delta.inserted.min(by: { $0.seq < $1.seq }) {
                historyScrollTarget = first.id
                historyScrollTicket &+= 1
            }
        } catch {
            failureMessage = (error as? DSHClientError)?.displayMessage ?? error.localizedDescription
            logs.log(.warning, "补历史失败：\(failureMessage ?? "")")
        }
    }

    // MARK: 发送 / 打断

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }

        let rpcId = RpcId.make()
        pendingPromptRpcId = rpcId
        let snapshotAttachments = attachments

        // 乐观插入：立刻出现在时间线上，日志里的 user/message 到达后按 rpcId 接管同一条。
        var imageRefs: [TimelineItem.ImageRef] = []
        var fileRefs: [TimelineItem.FileRef] = []
        for attachment in snapshotAttachments where attachment.isImage {
            imageRefs.append(TimelineItem.ImageRef(
                attachmentId: "pending-\(attachment.id)",
                name: attachment.name,
                mediaType: attachment.mediaType,
                sessionId: sessionId
            ))
        }
        for attachment in snapshotAttachments where !attachment.isImage {
            fileRefs.append(TimelineItem.FileRef(attachmentId: "pending-\(attachment.id)", name: attachment.name))
        }
        _ = builder.insertOptimisticUserMessage(text: text, images: imageRefs, files: fileRefs, rpcId: rpcId)
        draft = ""
        attachments = []
        isTurnRunning = true
        publish()
        requestScrollToBottom()

        do {
            // 附件：图片**内联 base64** 直接随 prompt 走；文件必须先上传拿 receiptId。
            // （这是线上契约，不是优化选择 —— 见 DSHClient.prompt 的注释。）
            var promptAttachments: [DSHClient.PromptAttachment] = []
            for attachment in snapshotAttachments {
                if attachment.isImage {
                    promptAttachments.append(.image(
                        data: attachment.data,
                        mediaType: attachment.mediaType,
                        name: attachment.name
                    ))
                } else {
                    let upload = try await client.uploadFile(
                        sessionId: sessionId,
                        name: attachment.name,
                        data: attachment.data
                    )
                    promptAttachments.append(.file(receiptId: upload.receiptId))
                }
            }
            _ = try await client.prompt(
                sessionId: sessionId,
                requestId: rpcId,
                text: text,
                attachments: promptAttachments,
                mode: .queue
            )
            pendingPromptRpcId = nil
        } catch {
            let message = (error as? DSHClientError)?.displayMessage ?? error.localizedDescription
            failureMessage = message
            _ = builder.failOptimisticUserMessage(rpcId: rpcId)
            isTurnRunning = false
            publish()
            logs.log(.warning, "发送失败：\(message)")
        }
    }

    func cancel() async {
        do {
            _ = try await client.cancel(sessionId: sessionId)
            isTurnRunning = false
        } catch {
            failureMessage = (error as? DSHClientError)?.displayMessage ?? error.localizedDescription
        }
    }

    func clearFailure() {
        failureMessage = nil
    }

    // MARK: 输入区附件

    func addAttachment(name: String, mediaType: String, data: Data) {
        let thumbnail: Data? = mediaType.hasPrefix("image/") ? data : nil
        attachments.append(PendingAttachment(name: name, mediaType: mediaType, data: data, thumbnail: thumbnail))
    }

    func removeAttachment(id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    // MARK: 图片取回

    /// 会话里引用过的图片：走 `session/attachment`（base64）。带一层内存缓存。
    func image(for reference: TimelineItem.ImageRef) async -> Data? {
        if let cached = imageCache[reference.attachmentId] { return cached }
        if reference.attachmentId.hasPrefix("pending-") {
            return attachments.first { "pending-\($0.id)" == reference.attachmentId }?.data
        }
        do {
            let result = try await client.attachment(sessionId: sessionId, attachmentId: reference.attachmentId)
            imageCache[reference.attachmentId] = result.data
            return result.data
        } catch {
            logs.log(.warning, "取图片失败：\(reference.attachmentId)")
            return nil
        }
    }

    private var imageCache: [String: Data] = [:]

    // MARK: 会话操作

    func rename(to newTitle: String) async {
        do {
            try await client.rename(sessionId: sessionId, title: newTitle)
            title = newTitle
        } catch {
            failureMessage = (error as? DSHClientError)?.displayMessage ?? error.localizedDescription
        }
    }

    /// 切换模型。失败会抛出去 —— 模型页要在原地给出"切换失败"，而不是悄悄什么都不做。
    func selectModel(provider: String, model: String, reasoningEffort: String?) async throws {
        try await client.selectModel(
            sessionId: sessionId,
            provider: provider,
            model: model,
            reasoningEffort: reasoningEffort
        )
        modelLabel = model
        modelSelection = ModelSelection(provider: provider, model: model, reasoningEffort: reasoningEffort)
    }

    /// 队列变了：更新列表，并把已经被队列接管的乐观插入撤掉。
    ///
    /// 不撤的话同一句话会显示两遍 —— 一遍是"发送中…"的乐观气泡，
    /// 一遍是"排队中"的队列项。
    private func publishQueuedMessages(_ inbox: InboxState) {
        queuedMessages = inbox.nextTurn + inbox.nextStep
        let queuedRpcIds = Set(queuedMessages.compactMap(\.rpcId))
        guard !queuedRpcIds.isEmpty else { return }
        for rpcId in queuedRpcIds {
            _ = builder.removeOptimisticUserMessage(rpcId: rpcId)
        }
        publish()
    }

    /// 可选的权限档位。
    func loadPermissionPresets() async throws -> PermissionPresetCatalog {
        try await client.permissionPresets()
    }

    /// 切换权限档位。走斜杠命令 `/permission <preset>` ——
    /// 这是 DSH 客户端协议里唯一能改当前会话权限的入口。
    func selectPermissionPreset(_ preset: String) async throws {
        let execution = try await client.selectPermissionPreset(sessionId: sessionId, preset: preset)
        guard execution.isSuccess else {
            throw DSHClientError.remote(DSHError(
                code: "command/failed",
                message: execution.text.isEmpty ? String(localized: "切换权限失败") : execution.text
            ))
        }
        currentPermission = preset
    }

    /// 模型清单。**失败要抛出去**，让模型页能显示"读不到 + 重试"，
    /// 而不是永远转圈（之前返回可选值、失败了就当空数组，UI 分不清"没读到"和"还没读到"）。
    func loadModelCatalog() async throws -> ModelCatalog {
        try await client.modelCatalog()
    }

    /// 给"诊断"用的：把当前时间线导出为纯文本。
    func exportTranscript() -> String {
        var lines: [String] = ["# \(title)", "session: \(sessionId)", ""]
        for item in items where !item.isShadowed {
            switch item.kind {
            case .userMessage(let message):
                lines.append("## 你\n\(message.text)\n")
            case .assistantMessage(let message):
                let text = message.renderableBlocks.map(\.plainText).joined()
                if !text.isEmpty { lines.append("## 助手\n\(text)\n") }
            case .toolCall(let call):
                lines.append("· 工具 \(call.name) (\(call.status))\n\(call.output)\n")
            case .note(let note):
                lines.append("· \(note.text)")
            default:
                break
            }
        }
        return lines.joined(separator: "\n")
    }
}

extension TimelineItem.ToolCall.Status {
    var localizedLabel: String {
        switch self {
        case .running: return String(localized: "运行中")
        case .success: return String(localized: "成功")
        case .failed: return String(localized: "失败")
        case .cancelled: return String(localized: "已取消")
        }
    }
}

extension TimelineItem.Approval.Decision {
    var localizedLabel: String {
        switch self {
        case .approvedOnce: return String(localized: "已批准一次")
        case .approvedAlways: return String(localized: "已始终允许")
        case .denied: return String(localized: "已拒绝")
        case .cancelled: return String(localized: "已取消")
        case .other(let raw): return raw
        }
    }
}
