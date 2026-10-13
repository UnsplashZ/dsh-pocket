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
    /// 从主机拉到的权限档位清单（含说明）。空的时候用内置三个兜底。
    private(set) var permissionPresetOptions: [PermissionPreset] = []
    /// 统计栏的轮询任务。
    private var statsTask: Task<Void, Never>?
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
    /// 会话累计统计（轮数/步数/TTFT/解码速度）—— 输入框下面那行。
    private(set) var sessionStats = SessionStats(json: .object([:]))
    /// 会话累计用量（缓存命中率用它）。
    private(set) var tokenUsage = TokenUsage(json: .object([:]))
    /// 已有评价，按 messageId 索引。
    private(set) var feedbacks: [String: MessageFeedback] = [:]
    /// 这个会话派出的子代理（`projections.subagentCatalog`）。
    private(set) var subagentCatalog: [SubagentInfo] = []
    /// 上下文里各部分占了多少（`projections.contextBreakdown`）。
    private(set) var contextBreakdown: ContextBreakdown?
    /// 会话的长期目标（`projections.goal`）。
    private(set) var goal: SessionGoal?
    /// 这个会话的后台任务。
    private(set) var jobs: [BackgroundJob] = []
    /// 可用的斜杠命令。
    private(set) var commands: [SlashCommand] = []
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
    /// 流式更新合帧用的待发任务。见 `scheduleStreamPublish`。
    private var pendingStreamPublish: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var pendingPromptRpcId: String?

    /// 会话列表说它在跑吗。
    ///
    /// **这是"正在跑"最权威的来源**：有界快照（`maxMessages: 20`）里可能根本
    /// 没有 `turn/start`（窗口从半途开始），光靠日志推导不出来 ——
    /// 表现就是"打开一个正在跑的会话却显示成空闲，连停止按钮都没有"（实测）。
    /// 打开之后由实时的 `turn/start` / `turn/end` 修正。
    private var summaryIsRunning: Bool

    init(sessionId: String, title: String, isRunning: Bool = false, appModel: AppModel) {
        self.sessionId = sessionId
        self.title = title
        self.summaryIsRunning = isRunning
        self.appModel = appModel
        self.settings = appModel.settings
        self.logs = appModel.logs
        self.isTurnRunning = isRunning
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
        // 评价是低频操作，打开时拉一次就够（之后本地维护）。
        await loadFeedbacks()
        // 权限档位也一样：拉一次，悬浮窗直接用。
        if let catalog = try? await client.permissionPresets() {
            permissionPresetOptions = catalog.options
        }
        startStatsPolling()
        await refreshCommands()
        await refreshJobs()
    }

    func close() {
        statsTask?.cancel()
        statsTask = nil
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
        // **有内容在屏幕上时不要先清空。**
        //
        // 用户复现："点进一条更新了很多消息的会话，原本显示的是之前的缓存，
        // 然后一下突然变空了，等了好一会又恢复。"
        //
        // 原因就在这里：之前先把 `items` 清空再分批折叠，于是
        // 缓存内容 → 一片空白（折叠期间）→ 内容回来。
        // 大会话有 40+ 个分片，空白能持续好几秒。
        //
        // 现在折到**临时 builder**里，折完一次性换上去 —— 旧内容一直留在屏幕上。
        // 冷启动（屏幕上本来就没东西）仍然走边折边渲染，那样首屏更快。
        let hasVisibleContent = !items.isEmpty
        var rebuilt = TimelineBuilder()
        if !hasVisibleContent {
            builder = TimelineBuilder()
            items = []
            shadowedItems = []
        }
        lastSeq = -1
        hasMoreHistory = snapshot.hasMore
        applyProjections(snapshot.projections)
        if !hasVisibleContent { publish() }

        let events = snapshot.events
        let chunkSize = 120
        var index = 0
        while index < events.count {
            if Task.isCancelled { return }
            let end = min(index + chunkSize, events.count)
            for event in events[index..<end] {
                // 双缓冲折到 `rebuilt`，冷启动直接折进 `builder`。
                // **不能写成 `let target = hasVisibleContent ? rebuilt : builder`** ——
                // `builder` 是结构体，那样只是复制一份，改不到真的那个。
                if hasVisibleContent { _ = rebuilt.apply(event) } else { _ = builder.apply(event) }
            }
            index = end
            // 双缓冲时**中途不发布** —— 发布了就会把旧内容换掉，
            // 又变回"折一半给人看"。
            if !hasVisibleContent { publish() }
            // 让出一次主线程：831 KB 的快照要"边到边渲染"，不能等全部解码完。
            await Task.yield()
        }
        if hasVisibleContent {
            builder = rebuilt
            publish()
            logs.log(.info, "全量重建完成（双缓冲，\\(events.count) 条事件），期间旧内容一直在屏幕上")
        } else {
            logs.log(.info, "冷启动折叠完成（\\(events.count) 条事件）")
        }
        lastSeq = max(lastSeq, Double(snapshot.cursor))
        phase = .live
        // 日志里能看出这一轮还开着就用它；看不出来（有界快照切在半途）
        // 就退回会话列表给的 running —— **不能无条件设 false**。
        isTurnRunning = builder.isTurnOpen || summaryIsRunning
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
        if event.type == "turn/start" {
            isTurnRunning = true
            summaryIsRunning = true
        }
        if event.type == "turn/end" {
            // 实时的 `turn/end` 是终局判据：它到了就是跑完了，
            // 不再让可能过期的列表标志把它拉回"运行中"。
            isTurnRunning = false
            summaryIsRunning = false
        }
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
        guard !delta.isEmpty else { return }
        if case .chunk = frame { isStreaming = true }

        switch frame {
        case .end:
            // 收尾必须**立刻**落屏，否则最后一段文字会晚一帧才出现。
            pendingStreamPublish?.cancel()
            pendingStreamPublish = nil
            publish()
        default:
            scheduleStreamPublish()
        }
    }

    /// 把流式更新的 `publish()` **合帧**。
    ///
    /// 之前每个 chunk 都直接 `publish()` —— 而 `publish()` 会把整个时间线
    /// 重新算一遍并交给 SwiftUI 重新渲染。宿主吐字快的时候，
    /// 一次输出能触发成百上千次全量重渲染，滚动就是在这时候卡住的。
    ///
    /// 现在最多约 60 次/秒（16 ms 一帧），而且同一帧内的多个 chunk 只算一次。
    private func scheduleStreamPublish() {
        guard pendingStreamPublish == nil else { return }
        pendingStreamPublish = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled, let self else { return }
            self.pendingStreamPublish = nil
            self.publish()
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
        // 队列**不从这里读** —— 投影只在快照时更新一次，
        // 电脑上删掉排队任务后手机要退出会话才消失（实测）。
        // 它由 `publish()` 从日志推导，见 `publishQueuedMessages()`。
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
        sessionStats = SessionStats(json: values["sessionStats"] ?? .object([:]))
        subagentCatalog = (values.array("subagentCatalog") ?? []).map(SubagentInfo.init(json:))
        contextBreakdown = values["contextBreakdown"].map(ContextBreakdown.init(json:))
        goal = values["goal"].map(SessionGoal.init(json:))
        tokenUsage = TokenUsage(json: values["tokenUsage"] ?? .object([:]))
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
        publishQueuedMessages()

        // **自检：条目在、分组却空了。**
        // 这会让界面变成一片空白（骨架要求条目为空、空态要求 phase != loading，
        // 两个条件都不满足）。实测重连时偶尔出现。
        // 分组是"哪些该显示"的唯一真相，它空了就必须说清为什么。
        let visibleCount = visible.count
        if visibleCount > 0, timelineBlocks.isEmpty {
            let shadowed = visible.filter(\.isShadowed).count
            let nonConversational = visible.filter { !$0.isConversational }.count
            logs.log(.warning, """
            时间线分组为空但条目有 \(visibleCount) 条 ——             已隐藏 \(shadowed)、不可渲染 \(nonConversational)、phase=\(phase)
            """)
        }
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

    /// 发送。
    ///
    /// `mode` 是线上契约里的必填字段（`SessionPromptRequest.mode`）：
    ///   · `.queue` —— 排到下一轮（默认，也是"追加排队"）；
    ///   · `.steer` —— **插队给正在跑的这一轮**（"立刻打断"）。
    func send(mode: PromptMode = .queue) async {
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
        // **跑着的时候不要乐观插入。**
        //
        // 用户："发消息排队时也应该直接去排队，而不是先加入对话框，然后再进入排队。"
        // 乐观气泡是给"立刻要发出去"用的；排队的话宿主会用
        // `agent/inbox/spliced` 把它放进队列区，多插一条只会让人看到它
        // 先出现在时间线上、再跳进队列。
        let willQueue = isTurnRunning
        if !willQueue {
            _ = builder.insertOptimisticUserMessage(text: text, images: imageRefs, files: fileRefs, rpcId: rpcId)
            isTurnRunning = true
        }
        draft = ""
        attachments = []
        publish()
        if !willQueue { requestScrollToBottom() }

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
                mode: mode
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

    /// 队列变了：**从日志推导**，并把已经被队列接管的乐观插入撤掉。
    ///
    /// 不撤的话同一句话会显示两遍 —— 一遍是"发送中…"的乐观气泡，
    /// 一遍是"排队中"的队列项。
    private func publishQueuedMessages() {
        queuedMessages = builder.queuedMessages
        let queuedRpcIds = Set(queuedMessages.compactMap(\.rpcId))
        guard !queuedRpcIds.isEmpty else { return }
        var removed = false
        for rpcId in queuedRpcIds {
            if !builder.removeOptimisticUserMessage(rpcId: rpcId).removedIds.isEmpty { removed = true }
        }
        if removed { publish() }
    }

    // MARK: 统计轮询

    /// 底部统计栏定时刷新。
    ///
    /// 这些数字（轮数/步数/首字/速度/缓存/上下文）只在**快照**里来，
    /// 而快照只在打开会话时给一次 —— 所以跑着的时候那一行是**冻住的**。
    /// 用 `session/projections`（轻量）每几秒补一次。
    private func startStatsPolling() {
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                await self.refreshStatsOnce()
            }
        }
    }

    private func refreshStatsOnce() async {
        guard let value = try? await client.sessionProjections(sessionId: sessionId) else { return }
        let values = value["values"] ?? .object([:])
        sessionStats = SessionStats(json: values["sessionStats"] ?? .object([:]))
        tokenUsage = TokenUsage(json: values["tokenUsage"] ?? .object([:]))
        if let pressure = values["contextPressure"] {
            contextPressure = ContextPressure(json: pressure)
        }
        if let breakdown = values["contextBreakdown"] {
            contextBreakdown = ContextBreakdown(json: breakdown)
        }
        goal = values["goal"].map(SessionGoal.init(json:))
    }

    // MARK: 斜杠命令 / 后台任务

    /// 只刷新目标（目标面板打开时用）。
    func refreshGoal() async {
        guard let value = try? await client.sessionProjections(sessionId: sessionId) else { return }
        goal = value["values"]?["goal"].map(SessionGoal.init(json:))
    }

    /// 拉一次可用的斜杠命令。
    func refreshCommands() async {
        commands = (try? await client.listCommands(sessionId: sessionId)) ?? []
    }

    /// 刷新后台任务列表。
    func refreshJobs() async {
        do {
            for try await jobs in client.listJobs(sessionId: sessionId) {
                self.jobs = jobs
                break
            }
        } catch {
            logs.log(.debug, "后台任务列表拉取失败：\(error.localizedDescription)")
        }
    }

    /// 停掉一个后台任务，然后刷新。
    func killJob(_ job: BackgroundJob) async {
        do {
            _ = try await client.killJob(sessionId: sessionId, jobId: job.id)
            await refreshJobs()
        } catch {
            failureMessage = (error as? DSHClientError)?.displayMessage ?? error.localizedDescription
        }
    }

    /// 跟一个后台任务的实时输出。
    func followJob(_ job: BackgroundJob) -> AsyncThrowingStream<JobFollowFrame, any Error> {
        // 先把 client 取出来再交给流的构建闭包 —— `client` 是主 actor 隔离的，
        // 而 `followJob` 本身是 nonisolated 的。
        let client = self.client
        return client.followJob(jobId: job.id, sessionId: nil, from: nil)
    }

    /// 跑一条斜杠命令。
    ///
    /// 命令是**发进对话**的（`commands/execute`），所以它跟普通消息一样会出现在时间线上。
    func runCommand(_ command: SlashCommand, argument: String = "") async {
        let line = argument.isEmpty ? "/\(command.name)" : "/\(command.name) \(argument)"
        do {
            _ = try await client.executeCommand(sessionId: sessionId, line: line)
            draft = ""
            publish()
        } catch {
            failureMessage = (error as? DSHClientError)?.displayMessage ?? error.localizedDescription
        }
    }

    /// `@` 的候选（文件 + 别的会话）。
    func referenceCandidates(query: String) async -> (files: [FileReferenceCandidate], sessions: [SessionReferenceCandidate]) {
        async let files = try? await client.fileReferenceCandidates(sessionId: sessionId, query: query)
        async let sessions = try? await client.sessionReferenceCandidates(sessionId: sessionId, query: query)
        return (await files ?? [], await sessions ?? [])
    }

    /// 改目标。走 `/goal` 命令 —— 目标没有独立的写接口。
    func updateGoal(_ argument: String) async {
        do {
            _ = try await client.executeCommand(sessionId: sessionId, line: "/goal \(argument)")
        } catch {
            failureMessage = (error as? DSHClientError)?.displayMessage ?? error.localizedDescription
        }
    }

    // MARK: 评价 / 分支

    /// 拉一次已有评价。会话打开时调一次即可（评价是低频操作）。
    func loadFeedbacks() async {
        do {
            let items = try await client.messageFeedback(sessionId: sessionId)
            feedbacks = Dictionary(uniqueKeysWithValues: items.map { ($0.messageId, $0) })
        } catch {
            logs.log(.debug, "评价拉取失败：\(error.localizedDescription)")
        }
    }

    /// 点赞/点踩。再点一次同一个就是**撤销**（跟桌面端一致）。
    func toggleFeedback(messageId: String, rating: MessageFeedbackRating) async {
        let existing = feedbacks[messageId]
        do {
            if existing?.rating == rating, let version = existing?.version {
                _ = try await client.deleteMessageFeedback(
                    sessionId: sessionId, messageId: messageId, ifVersion: version
                )
                feedbacks[messageId] = nil
            } else {
                do {
                    feedbacks[messageId] = try await client.putMessageFeedback(
                        sessionId: sessionId,
                        messageId: messageId,
                        rating: rating,
                        ifVersion: existing?.version
                    )
                } catch let error as DSHClientError where error.isVersionConflict {
                    // 别人在你之后改过。**重新拉一次再重试**，而不是把错误甩给用户 ——
                    // 他只是点了个赞。
                    await loadFeedbacks()
                    feedbacks[messageId] = try await client.putMessageFeedback(
                        sessionId: sessionId,
                        messageId: messageId,
                        rating: rating,
                        ifVersion: feedbacks[messageId]?.version
                    )
                }
            }
        } catch {
            failureMessage = (error as? DSHClientError)?.displayMessage ?? error.localizedDescription
        }
    }

    /// 找出某次子代理调用对应的**子代理会话 id**（实现在 DSHKit 里，纯函数可测）。
    func subagentSessionId(label: String, at time: Date) -> String? {
        subagentCatalog.subagentSessionId(label: label, at: time)
    }

    /// 对一条排队中的消息做点什么（编辑 / 删除 / 插进这一轮）。
    ///
    /// 队列本身会由日志里的 `agent/inbox/spliced` 事件推回来，所以这里
    /// **不需要**手动改本地状态 —— 发出去就行。
    func updateQueue(itemId: String, action: QueueAction) async {
        do {
            try await client.updateQueue(sessionId: sessionId, itemId: itemId, action: action)
        } catch {
            failureMessage = (error as? DSHClientError)?.displayMessage ?? error.localizedDescription
        }
    }

    /// 从某条消息处分叉出一个新会话，返回新会话 id。
    func fork(atSeq: Int?) async -> String? {
        do {
            return try await client.forkSession(sessionId: sessionId, atSeq: atSeq)
        } catch {
            failureMessage = (error as? DSHClientError)?.displayMessage ?? error.localizedDescription
            return nil
        }
    }

    /// 可选的权限档位。
    func loadPermissionPresets() async throws -> PermissionPresetCatalog {
        try await client.permissionPresets()
    }

    /// 悬浮窗要用的三选一。
    ///
    /// 拉不到清单时**退回硬编码的三个** —— 这三个是 DSH 内置的档位名，
    /// 比"悬浮窗空白"强（拉不到通常只是那一瞬间的网络问题）。
    var permissionOptions: [PermissionPreset] {
        if !permissionPresetOptions.isEmpty { return permissionPresetOptions }
        return ["read-only", "workspace-write", "danger-full-access"].map {
            PermissionPreset(value: $0, name: $0)
        }
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

    /// 切换权限档位并把失败记下来。
    ///
    /// 悬浮窗里直接点选，没有地方展示错误 —— 所以在这里兜住，
    /// 写进 `failureMessage`（会话顶部的状态条会显示）。
    func applyPermissionPreset(_ preset: String) async {
        do {
            try await selectPermissionPreset(preset)
        } catch {
            failureMessage = (error as? DSHClientError)?.displayMessage ?? error.localizedDescription
        }
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
