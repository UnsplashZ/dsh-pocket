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
        await subscribe()
    }

    func close() {
        followTask?.cancel()
        followTask = nil
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
    }

    private func apply(_ event: SessionEvent) {
        let delta = builder.apply(event)
        lastSeq = max(lastSeq, event.seq)
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
        if let selection = values["modelSelection"] {
            let next = selection["next"] ?? selection["lastUsed"] ?? .null
            let provider = next.string("provider") ?? ""
            let model = next.string("model") ?? ""
            modelLabel = model.isEmpty ? provider : model
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
    }

    /// 每次"应该滚到底"时自增。View 观察它做一次 `scrollTo`。
    ///
    /// 为什么不能只靠"最后一条 item 变了就滚"：快照是分批入视图的，分批期间
    /// 布局还没稳定，`scrollTo` 会落在半路上；而分完之后最后一条又不一定再变。
    /// 所以由模型显式发一个"滚到底"的信号。
    private(set) var scrollToBottomTicket = 0

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

    func loadOlderHistoryIfNeeded() async {
        guard hasMoreHistory, !isLoadingHistory else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        let through = builder.cursor
        guard through > 0 else { return }
        do {
            let page = try await client.page(sessionId: sessionId, throughSeq: through, maxMessages: 50)
            guard !page.events.isEmpty else {
                hasMoreHistory = false
                return
            }
            _ = builder.prepend(page: page.events)
            hasMoreHistory = page.hasMore
            publish()
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
            // 附件先上传拿到 receipt，再随 prompt 一起提交。
            var promptAttachments: [DSHClient.PromptAttachment] = []
            for attachment in snapshotAttachments {
                let upload = try await client.uploadFile(
                    sessionId: sessionId,
                    name: attachment.name,
                    data: attachment.data
                )
                if attachment.isImage {
                    promptAttachments.append(.image(upload.file))
                } else {
                    promptAttachments.append(.fileReceipt(receiptId: upload.receiptId, file: upload.file))
                }
            }
            _ = try await client.prompt(
                sessionId: sessionId,
                requestId: rpcId,
                text: text,
                attachments: promptAttachments
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

    func selectModel(provider: String, model: String, reasoningEffort: String?) async {
        do {
            try await client.selectModel(
                sessionId: sessionId,
                provider: provider,
                model: model,
                reasoningEffort: reasoningEffort
            )
            modelLabel = model
        } catch {
            failureMessage = (error as? DSHClientError)?.displayMessage ?? error.localizedDescription
        }
    }

    func loadModelCatalog() async -> JSONValue? {
        try? await client.modelCatalog()
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
