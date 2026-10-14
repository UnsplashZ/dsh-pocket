import Foundation

/// 把 `session/follow` 的帧折叠成一条**有序、可增量更新**的时间线。
///
/// 这个类型是纯值语义、无并发、无 I/O —— 所有协议理解都在这里，可单测。
/// UI 拿它的 `items` 渲染，拿每次 `apply` 返回的 `TimelineDelta` 做增量更新。
///
/// 三条与 DSH 内部实现对齐的规则：
///   1. **表面折叠**（`surfaceOp`）：`append` 推进表面尾部；`replace` 把
///      `[startSeq, endSeq]` 从表面里换成自己。被换掉的仍在时间线里，
///      但标记 `isShadowed`（UI 默认收进"已被压缩取代"）。
///   2. **对话记录 = append 起源 + 非表面事件**。replace 事件是模型可见层的
///      副本，拿它渲染会让用户已经看过的内容凭空消失。
///   3. **实时块与持久事件无缝交接**：`assistant-stream` 累积的实时项在
///      同 (turn, step) 的持久 `assistant/message` 到达时被就地接管，
///      复用同一个 `id`，因此 UI 不会闪。
public struct TimelineBuilder: Sendable {
    /// 正在丢掉"`/permission` 引发的那一组配置 note"。
    ///
    /// **要进 `State`**：手机端发起 `/permission` 后，如果事件流跨过快照边界
    /// （缓存重建 builder）时这组 note 还没到齐，内存标志会丢、note 就漏出来
    /// （KNOWN-ISSUES F4 的残留项）。它只在一次命令的几毫秒内为 true，
    /// 持久化的代价几乎为零。
    private var suppressConfigNotes = false
    // MARK: - 输出

    /// 全部条目，按 `seq` 升序。含被遮住的条目（用 `isShadowed` 过滤）。
    public private(set) var items: [TimelineItem] = []
    /// 快照覆盖到哪（`session/page` 的 `throughSeq`）。
    public private(set) var cursor: Int = -1
    /// 本地见过的最大 seq。
    public private(set) var lastSeq: Double = -1
    public private(set) var header: SessionHeader?
    public private(set) var hasMoreHistory: Bool = false

    // MARK: - 内部索引

    private var indexById: [String: Int] = [:]
    /// DSH 的"表面"：模型可见的节点顺序。
    private var surfaceNodes: [Double] = []
    /// 表面替换历史（诊断页与测试用）。
    public private(set) var replacements: [SurfaceReplacement] = []

    /// 一次表面替换的记录。用结构体而不是元组 —— 元组不是 `Codable`，落盘要用。
    public struct SurfaceReplacement: Sendable, Hashable, Codable {
        public var seq: Double
        public var start: Int
        public var end: Int

        public init(seq: Double, start: Int, end: Int) {
            self.seq = seq
            self.start = start
            self.end = end
        }
    }

    private var liveAttempt: LiveAttempt?
    /// 助手消息里已声明、但还没等到 `tool/call` 事件的工具调用。
    private var toolCalls: [String: String] = [:]        // callId → itemId
    /// 队列中的消息（`agent/inbox/spliced`）→ rpcId → itemId
    private var inboxItems: [String: String] = [:]
    /// 乐观插入的本地消息 → rpcId → itemId
    private var optimisticItems: [String: String] = [:]
    /// 待审批：approvalId → itemId
    private var approvals: [String: String] = [:]

    private struct LiveAttempt {
        var attemptId: String
        var itemId: String
        var turn: Int
        var step: Int
        var nextIndex: Int
        var text: String = ""
        var reasoning: String = ""
        var toolCalls: [Int: (id: String, name: String, arguments: String)] = [:]
    }

    public init() {}

    // MARK: - 落盘 / 恢复

    /// 折叠结果的**完整**可序列化快照。
    ///
    /// 为什么连 `surfaceNodes` / `toolCalls` 这些索引都要存：恢复之后必须能**继续增量折叠**，
    /// 而不只是把条目画出来。少一个索引，后续 `surfaceOp.replace` 就会算错区间、
    /// `tool/result` 就会合并不到对应的 `tool/call`。
    public struct State: Sendable, Codable {
        /// 版本号。形状**或折叠语义**变了就 +1，读不认识的版本一律丢弃重拉。
        ///
        /// 注意不只是"字段变了"要升版：`isShadowed` 这类**折叠结果**也存进来了，
        /// 所以修好一个"错误地标成已隐藏"的 bug 之后，旧缓存里那个错误的标记
        /// 会一直生效 —— 界面上看不出任何变化，会以为修复没生效（实测踩过）。
        public static let currentSchemaVersion = 5

        public var schemaVersion: Int = State.currentSchemaVersion
        public var header: SessionHeader?
        public var cursor: Int
        public var lastSeq: Double
        public var hasMoreHistory: Bool
        public var items: [TimelineItem]
        public var surfaceNodes: [Double]
        public var replacements: [SurfaceReplacement]
        public var toolCalls: [String: String]
        public var approvals: [String: String]
        public var inboxItems: [String: String]
        public var optimisticItems: [String: String]
        public var transientCounter: Int
        /// `/permission` 抑制窗口是否还开着（见 `suppressConfigNotes`）。
        public var suppressConfigNotes: Bool

        // 显式公开 memberwise init：`State` 要跨模块构造（App 侧的缓存）。
        public init(
            schemaVersion: Int = State.currentSchemaVersion,
            header: SessionHeader? = nil,
            cursor: Int = -1,
            lastSeq: Double = -1,
            hasMoreHistory: Bool = false,
            items: [TimelineItem] = [],
            surfaceNodes: [Double] = [],
            replacements: [SurfaceReplacement] = [],
            toolCalls: [String: String] = [:],
            approvals: [String: String] = [:],
            inboxItems: [String: String] = [:],
            optimisticItems: [String: String] = [:],
            transientCounter: Int = 0,
            suppressConfigNotes: Bool = false
        ) {
            self.schemaVersion = schemaVersion
            self.header = header
            self.cursor = cursor
            self.lastSeq = lastSeq
            self.hasMoreHistory = hasMoreHistory
            self.items = items
            self.surfaceNodes = surfaceNodes
            self.replacements = replacements
            self.toolCalls = toolCalls
            self.approvals = approvals
            self.inboxItems = inboxItems
            self.optimisticItems = optimisticItems
            self.transientCounter = transientCounter
            self.suppressConfigNotes = suppressConfigNotes
        }
    }

    public var state: State {
        State(
            header: header,
            cursor: cursor,
            lastSeq: lastSeq,
            hasMoreHistory: hasMoreHistory,
            items: items,
            surfaceNodes: surfaceNodes,
            replacements: replacements,
            toolCalls: toolCalls,
            approvals: approvals,
            inboxItems: inboxItems,
            optimisticItems: optimisticItems,
            transientCounter: transientCounter,
            suppressConfigNotes: suppressConfigNotes
        )
    }

    /// 从落盘状态恢复。版本对不上就返回 `nil`（调用方退回重拉）。
    public init?(state: State) {
        guard state.schemaVersion == State.currentSchemaVersion else { return nil }
        header = state.header
        cursor = state.cursor
        lastSeq = state.lastSeq
        hasMoreHistory = state.hasMoreHistory
        items = state.items
        surfaceNodes = state.surfaceNodes
        replacements = state.replacements
        toolCalls = state.toolCalls
        approvals = state.approvals
        inboxItems = state.inboxItems
        optimisticItems = state.optimisticItems
        transientCounter = state.transientCounter
        suppressConfigNotes = state.suppressConfigNotes
        rebuildIndex()
    }

    /// **续拉**：把一份快照合并进来，而不是把它当成全部。
    ///
    /// 与 `apply(snapshot:)` 的区别是这里的语义是"我手里已经有东西了，补齐就好"：
    ///   · 按 `seq` 去重（`upsert` 天然幂等），老条目原样留着；
    ///   · 如果宿主的 cursor **落后于**我们的 lastSeq（日志被换过 / 缓存过旧），
    ///     说明缓存不可信 —— 返回 `false`，调用方退回 `apply(snapshot:)` 整体重建。
    public mutating func resume(with snapshot: SessionSnapshot) -> Bool {
        if snapshot.cursor < Int(lastSeq) { return false }
        header = snapshot.header
        hasMoreHistory = snapshot.hasMore
        for event in snapshot.events where event.seq > lastSeq {
            _ = apply(event)
        }
        cursor = snapshot.cursor
        lastSeq = max(lastSeq, Double(snapshot.cursor))
        return true
    }

    public var isEmpty: Bool { items.isEmpty }

    /// 默认视图要渲染的条目（去掉 `raw`、被遮住的单独由 UI 决定）。
    /// 这句是不是宿主自己注入的机器通知（不是用户打的字）。
    ///
    /// 目前只认审批策略变化那一句 —— 它是 DSH 里唯一会往**用户消息**里
    /// 注入"通知"的地方。**版本耦合**，换措辞就会失效（失效只是噪音回来）。
    static func isMachineNotice(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("The approval policy changed from ")
    }

    /// 当前这一轮是不是还开着（最后一条 `turn/start` 之后没有 `turn/end`）。
    ///
    /// **从日志推导，不靠快照里的标志位。** 之前 `applySnapshot` 直接把
    /// "正在跑"设成 false —— 于是**打开一个正在跑的会话会显示成空闲**，
    /// 连停止按钮都没有（实测：手机上看着像跑完了，其实电脑还在跑）。
    public var isTurnOpen: Bool {
        for item in items.reversed() {
            switch item.kind {
            case .turnEnd: return false
            case .turnStart: return true
            default: continue
            }
        }
        return false
    }

    /// 排队中的消息。
    ///
    /// **从日志推导，不是读投影。** `applyInbox` 本来就在维护这些项
    /// （`agent/inbox/spliced` 的 `inserted` 建项、被消化时标 shadowed），
    /// 所以队列一变这里就跟着变。
    ///
    /// 之前渲染的是 `projections.inbox` —— 那个**只在快照时更新一次**，
    /// 于是在电脑上删掉排队任务之后，手机上要退出会话再进来才会消失（实测）。
    public var queuedMessages: [QueuedMessage] {
        items
            .filter { item in
                guard !item.isShadowed, case .userMessage(let message) = item.kind else { return false }
                return message.isQueued
            }
            .sorted { $0.seq < $1.seq }
            .map { item in
                guard case .userMessage(let message) = item.kind else {
                    return QueuedMessage(json: .object([:]))
                }
                return QueuedMessage(
                    id: item.id,
                    text: message.text,
                    rpcId: message.rpcId,
                    imageCount: message.images.count,
                    fileCount: message.files.count
                )
            }
    }

    public var conversationalItems: [TimelineItem] {
        items.filter(\.isConversational)
    }

    // MARK: - 快照

    /// 用一份快照**重建**时间线（重连、切会话、补历史后调用）。
    public mutating func apply(snapshot: SessionSnapshot) -> TimelineDelta {
        self = TimelineBuilder()
        header = snapshot.header
        cursor = snapshot.cursor
        hasMoreHistory = snapshot.hasMore
        var delta = TimelineDelta()
        for event in snapshot.events {
            delta.merge(apply(event))
        }
        // 快照里可能带一个仍在进行的 attempt 的压缩前缀；这里不重建它
        // （DSH 的 expandAssistantStream 需要压缩记录的解压逻辑），
        // 交给紧随其后的实时 chunk 直接把文本长出来。
        delta.shouldFollowScroll = true
        return delta
    }

    /// 用一页历史**前置**进时间线（`session/page` 向上补页）。
    public mutating func prepend(page: [SessionEvent]) -> TimelineDelta {
        guard !page.isEmpty else { return .none }
        // 历史页是更早的事件：用一个临时 builder 折叠它们，再整体前插。
        var earlier = TimelineBuilder()
        for event in page { _ = earlier.apply(event) }
        let existing = Set(items.map(\.id))
        let fresh = earlier.items.filter { !existing.contains($0.id) }

        // 重新编号：把新条目放在前面，并重建索引。
        var merged = fresh + items
        // 被遮住状态以"更新的一次折叠"为准：历史页里 replace 的区间若落在
        // 现有条目上，也要标记。
        merged.sort { $0.seq < $1.seq }
        items = merged
        rebuildIndex()
        cursor = min(cursor, earlier.cursor >= 0 ? earlier.cursor : cursor)
        hasMoreHistory = earlier.hasMoreHistory
        var delta = TimelineDelta()
        delta.inserted = fresh
        return delta
    }

    // MARK: - 事件

    /// 应用一条持久事件。
    public mutating func apply(_ event: SessionEvent) -> TimelineDelta {
        var delta = TimelineDelta()
        lastSeq = max(lastSeq, event.seq)

        // **`/permission` 引发的那一组配置 note，整组丢掉。**
        //
        // 它一次会留下 5 行（`⌘ permission` / `sandbox/mode` /
        // `permission/preset` / `approval/policy` / `command/done`）——
        // 而权限已经显示在输入框的胶囊上了，这 5 行纯属噪音
        //（用户："切换权限时会显示一条消息加入排队，这个要优化一下"）。
        //
        // 只在**紧跟着的**那几条上生效：窗口在 `command/done` 处关闭，
        // 所以别的地方（比如从电脑上改权限）照常显示。
        if event.type == "command/run", event.string("data.name") == "permission" {
            suppressConfigNotes = true
            return delta
        }
        if suppressConfigNotes {
            switch event.type {
            case "sandbox/mode", "permission/preset", "approval/policy":
                return delta
            case "command/done":
                suppressConfigNotes = false
                return delta
            default:
                break
            }
        }

        // 表面折叠先做：它决定 isShadowed，也决定 replace 事件自己算不算对话。
        let shadowed = foldSurface(event)
        if !shadowed.isEmpty {
            for id in shadowed {
                if let index = indexById[id] {
                    items[index].isShadowed = true
                    delta.shadowedIds.append(id)
                }
            }
        }

        switch event.type {
        case "turn/start":
            let turn = event.int("data.turn") ?? event.turnHint
            upsert(
                TimelineItem(
                    id: Self.durableId(event.seq), seq: event.seq, time: event.time, turn: turn,
                    kind: .turnStart(turn: turn ?? 0)
                ),
                into: &delta
            )

        case "turn/end":
            let turn = event.int("data.turn") ?? event.turnHint
            upsert(
                TimelineItem(
                    id: Self.durableId(event.seq), seq: event.seq, time: event.time, turn: turn,
                    kind: .turnEnd(turn: turn ?? 0, reason: .init(json: event.data["reason"]))
                ),
                into: &delta
            )
            delta.shouldFollowScroll = true

        case "step/start", "step/end":
            // 步边界本身不渲染（turn 分隔已经够用），但 step/end 要退休实时项。
            if event.type == "step/end" {
                retireLiveAttempt(turn: event.int("data.turn"), step: event.int("data.step"), into: &delta)
            }

        case "user/message":
            applyUserMessage(event, into: &delta)

        case "assistant/message":
            applyAssistantMessage(event, into: &delta)

        case "assistant/attempt":
            upsert(
                TimelineItem(
                    id: Self.durableId(event.seq), seq: event.seq, time: event.time,
                    turn: event.int("data.turn"), step: event.int("data.step"),
                    kind: .note(.init(
                        text: event.data["interrupted"] != nil ? "这一轮被中断" : "一次尝试未产出内容",
                        symbolName: "arrow.triangle.2.circlepath",
                        tone: .warning,
                        sourceEventType: event.type,
                        isProminent: false
                    ))
                ),
                into: &delta
            )

        case "tool/call":
            applyToolCall(event, into: &delta)

        case "tool/result":
            applyToolResult(event, into: &delta)

        case "agent/inbox/spliced":
            applyInbox(event, into: &delta)

        case "todo/write":
            let todos = (event.data.array("todos") ?? []).map { entry in
                TimelineItem.TodoEntry(
                    text: entry.string("content") ?? entry.string("text") ?? "",
                    status: .init(raw: entry.string("status"))
                )
            }
            upsert(
                TimelineItem(
                    id: Self.durableId(event.seq), seq: event.seq, time: event.time,
                    kind: .todo(.init(items: todos))
                ),
                into: &delta
            )

        case "approval/asked":
            applyApprovalAsked(event, into: &delta)

        case "approval/decided":
            applyApprovalDecided(event, into: &delta)

        case "compaction/start", "compaction/summary", "compaction/end", "compaction/prune":
            applyCompaction(event, into: &delta)

        case "goal/change":
            let operation = event.string("data.operation") ?? ""
            let objective = event.string("data.goal.objective")
            upsert(
                TimelineItem(
                    id: Self.durableId(event.seq), seq: event.seq, time: event.time,
                    kind: .goal(.init(objective: objective, status: operation))
                ),
                into: &delta
            )

        case "plan/mode":
            upsert(
                TimelineItem(
                    id: Self.durableId(event.seq), seq: event.seq, time: event.time,
                    kind: .planMode(.init(
                        isActive: event.bool("data.active") ?? false,
                        isPending: event.bool("data.pending") ?? false
                    ))
                ),
                into: &delta
            )

        case "deliverables/presented":
            let list = (event.data.array("deliverables") ?? event.data.array("items") ?? []).map { item in
                TimelineItem.Deliverable(
                    title: item.string("title") ?? item.string("name") ?? "产物",
                    path: item.string("path"),
                    description: item.string("description")
                )
            }
            upsert(
                TimelineItem(
                    id: Self.durableId(event.seq), seq: event.seq, time: event.time,
                    kind: .deliverables(list)
                ),
                into: &delta
            )

        case "model/selection":
            upsert(
                TimelineItem(
                    id: Self.durableId(event.seq), seq: event.seq, time: event.time,
                    kind: .note(.init(
                        text: noteText(modelSelection: event.data),
                        symbolName: "cpu",
                        tone: .neutral,
                        sourceEventType: event.type,
                        isProminent: false
                    ))
                ),
                into: &delta
            )

        case "session/title":
            upsert(
                TimelineItem(
                    id: Self.durableId(event.seq), seq: event.seq, time: event.time,
                    kind: .note(.init(
                        text: event.string("data.title") ?? "",
                        symbolName: "textformat.size",
                        tone: .neutral,
                        sourceEventType: event.type,
                        isProminent: false
                    ))
                ),
                into: &delta
            )

        case "sandbox/mode", "permission/preset", "approval/policy", "agent-preset/selected",
             "model/selection-request", "session/end-seed":
            upsert(
                TimelineItem(
                    id: Self.durableId(event.seq), seq: event.seq, time: event.time,
                    kind: .note(.init(
                        text: noteText(controlEvent: event),
                        symbolName: symbolName(forControl: event.type),
                        tone: .neutral,
                        sourceEventType: event.type,
                        isProminent: false
                    ))
                ),
                into: &delta
            )

        case "request/header", "request/context", "system/message", "developer/message",
             "compaction/summary-raw", "tool/ptc-dispatch", "tool/ptc-dispatch-start",
             "image/offload", "llm/retry", "llm/retry-started", "workspace/changes",
             "hook/invoked", "hook/result", "feedback/record", "feedback/message-put",
             "feedback/message-delete", "subagent/catalog", "subagent/model-selection-policy",
             "team/member", "team/task", "team/message/queued", "team/message/delivered",
             "session/title-llm-request", "web/deepseek-search-llm-request",
             "session-log-deepseek/delivery-accepted", "schedule/change",
             "tool-workflow/run-start", "tool-workflow/run-end",
             "tool-workflow/agent-start", "tool-workflow/agent-end":
            // 已知、但属于"模型管道"而不是对话。收进 raw，默认隐藏。
            upsert(
                TimelineItem(
                    id: Self.durableId(event.seq), seq: event.seq, time: event.time,
                    turn: event.int("data.turn"), step: event.int("data.step"),
                    kind: .raw(type: event.type, data: event.data)
                ),
                into: &delta
            )

        case "subagent/descriptor":
            let name = event.string("data.name") ?? event.string("data.agentId") ?? String(localized: "子 agent")
            upsert(
                TimelineItem(
                    id: Self.durableId(event.seq), seq: event.seq, time: event.time,
                    kind: .note(.init(
                        text: name,
                        symbolName: "person.2",
                        tone: .info,
                        sourceEventType: event.type,
                        isProminent: false
                    ))
                ),
                into: &delta
            )

        case "command/run":
            upsert(
                TimelineItem(
                    id: Self.durableId(event.seq), seq: event.seq, time: event.time,
                    kind: .note(.init(
                        text: event.string("data.name") ?? String(localized: "命令"),
                        symbolName: "command",
                        tone: .neutral,
                        sourceEventType: event.type,
                        isProminent: true
                    ))
                ),
                into: &delta
            )

        case "command/done":
            let failed = event.string("data.kind") == "error"
            upsert(
                TimelineItem(
                    id: Self.durableId(event.seq), seq: event.seq, time: event.time,
                    kind: .note(.init(
                        text: event.string("data.text") ?? (failed ? "命令失败" : "命令完成"),
                        symbolName: failed ? "xmark.octagon.fill" : "checkmark.circle.fill",
                        tone: failed ? .failure : .success,
                        sourceEventType: event.type,
                        isProminent: false
                    ))
                ),
                into: &delta
            )

        default:
            if event.ignorable {
                // 宿主明确标记"不认识也能跳过"的外部事件：静默跳过，不占用 UI。
                return delta
            }
            upsert(
                TimelineItem(
                    id: Self.durableId(event.seq), seq: event.seq, time: event.time,
                    kind: .unknown(type: event.type, data: event.data)
                ),
                into: &delta
            )
        }

        return delta
    }

    // MARK: - 实时流

    /// 应用一帧 `assistant-stream`。
    public mutating func apply(assistantStream frame: AssistantStreamFrame) -> TimelineDelta {
        var delta = TimelineDelta()
        switch frame {
        case .start(let attemptId, _, let turn, let step):
            if liveAttempt != nil {
                // 上一轮没退休干净：先收掉，避免两段实时文本叠着。
                retireLiveAttempt(turn: nil, step: nil, into: &delta)
            }
            let itemId = "live-\(attemptId)"
            liveAttempt = LiveAttempt(attemptId: attemptId, itemId: itemId, turn: turn, step: step, nextIndex: 0)
            upsert(
                TimelineItem(
                    id: itemId,
                    seq: nextTransientSeq(),
                    time: Date(),
                    turn: turn, step: step,
                    kind: .assistantMessage(.init(blocks: [], isStreaming: true, isSettled: false))
                ),
                into: &delta
            )
            delta.shouldFollowScroll = true

        case .chunk(let chunk):
            guard var attempt = liveAttempt, attempt.attemptId == chunk.attemptId else {
                // 没有 start 帧（例如控制器挂载得晚）：忽略这段实时尾巴，
                // 持久事件到达时会直接渲染完整消息。
                return delta
            }
            // index 跳号说明中间有丢帧；已有的文本留着，继续往后长。
            attempt.nextIndex = chunk.index + 1
            switch chunk.chunk {
            case .textDelta(_, let text):
                attempt.text += text
            case .reasoningDelta(_, let text):
                attempt.reasoning += text
            case .toolCallDelta(let index, let id, let name, let argumentsDelta):
                var entry = attempt.toolCalls[index] ?? (id: id, name: name ?? "", arguments: "")
                if !id.isEmpty { entry.id = id }
                if let name, !name.isEmpty { entry.name = name }
                entry.arguments += argumentsDelta
                attempt.toolCalls[index] = entry
            case .blockStart, .blockEnd, .usage, .finish, .other:
                break
            }
            liveAttempt = attempt
            if let index = indexById[attempt.itemId] {
                items[index].kind = .assistantMessage(.init(
                    blocks: blocks(for: attempt),
                    isStreaming: true,
                    isSettled: false
                ))
                items[index].time = chunk.time
                delta.updated.append(items[index])
                delta.shouldFollowScroll = true
            }

        case .end(let attemptId, _, let outcome):
            guard let attempt = liveAttempt, attempt.attemptId == attemptId else { return delta }
            switch outcome.kind {
            case "abandoned":
                retireLiveAttempt(turn: nil, step: nil, into: &delta)
            default:
                // committed：持久事件马上到，先把光标收掉但保留文本，
                // 等 assistant/message 到达时接管同一个 id。
                if let index = indexById[attempt.itemId] {
                    items[index].kind = .assistantMessage(.init(
                        blocks: blocks(for: attempt),
                        isStreaming: false,
                        isSettled: false
                    ))
                    delta.updated.append(items[index])
                }
            }

        case .unknown:
            break
        }
        return delta
    }

    // MARK: - 本地乐观插入

    /// 用户按下发送时立刻插一条本地消息；宿主日志里的 `user/message` 到达后
    /// 用它替换（按 rpcId 对应），因此不会出现两条。
    public mutating func insertOptimisticUserMessage(
        text: String,
        images: [TimelineItem.ImageRef] = [],
        files: [TimelineItem.FileRef] = [],
        rpcId: String
    ) -> TimelineDelta {
        var delta = TimelineDelta()
        let itemId = "optimistic-\(rpcId)"
        optimisticItems[rpcId] = itemId
        lastSeq = max(lastSeq, nextTransientSeq())
        upsert(
            TimelineItem(
                id: itemId,
                seq: nextTransientSeq(),
                time: Date(),
                kind: .userMessage(.init(
                text: text, images: images, files: files, rpcId: rpcId, isPending: true, isQueued: false
            ))
            ),
            into: &delta
        )
        delta.shouldFollowScroll = true
        return delta
    }

    /// 发送失败（宿主拒绝）：把乐观项标记出来，UI 显示重试。
    public mutating func failOptimisticUserMessage(rpcId: String) -> TimelineDelta {
        guard let itemId = optimisticItems[rpcId], let index = indexById[itemId] else { return .none }
        guard case .userMessage(var message) = items[index].kind else { return .none }
        message.isPending = false
        items[index].kind = .userMessage(message)
        return TimelineDelta(updated: [items[index]])
    }

    /// 撤掉一条乐观插入。
    ///
    /// 用在"它已经出现在队列里"的时候：那条消息交给队列渲染成「排队中」，
    /// 乐观插入再留着就会变成两个气泡。
    public mutating func removeOptimisticUserMessage(rpcId: String) -> TimelineDelta {
        guard let itemId = optimisticItems[rpcId], let index = indexById[itemId] else { return .none }
        optimisticItems[rpcId] = nil
        indexById[itemId] = nil
        let removed = items.remove(at: index)
        reindex(from: index)
        return TimelineDelta(removedIds: [removed.id])
    }

    // MARK: - 表面折叠

    /// 返回被这次替换遮住的条目 id。
    private mutating func foldSurface(_ event: SessionEvent) -> [String] {
        guard let op = event.surfaceOp else { return [] }
        switch op {
        case .append:
            surfaceNodes.append(event.seq)
            return []
        case .replace(let start, let end):
            let startIdx = surfaceNodes.firstIndex(of: Double(start))
            let endIdx = surfaceNodes.firstIndex(of: Double(end))
            var shadowed: [String] = []
            if let startIdx, let endIdx, startIdx <= endIdx {
                let range = surfaceNodes[startIdx...endIdx]
                shadowed = range.map { Self.durableId($0) }
                surfaceNodes.replaceSubrange(startIdx...endIdx, with: [event.seq])
            } else {
                // 区间不在当前表面里（例如我们只加载了一页历史）：
                // 退化成"按 seq 区间标记"，宁可多标也不要漏标导致重复显示。
                shadowed = items
                    .filter { $0.isDurable && $0.seq >= Double(start) && $0.seq <= Double(end) }
                    .map(\.id)
                surfaceNodes.append(event.seq)
            }
            replacements.append(SurfaceReplacement(seq: event.seq, start: start, end: end))
            return shadowed
        }
    }

    // MARK: - 各事件的具体折叠

    private mutating func applyUserMessage(_ event: SessionEvent, into delta: inout TimelineDelta) {
        // **只有 `source.kind == "user"` 才是人打的字。**
        //
        // 别的一律是机器注入的上下文，它们同样以 `user/message` 事件落到日志里：
        // 实测见过的 kind 有 `runtime-context`、`skill-catalog`、`time-context`、
        // `memory-manager-catalog`、`mcp-manager-catalog`、`system-prompt`、
        // `tool-registry`、`user-approval`、`model-selection`…
        //
        // 把它们当用户消息渲染的后果很难看：一整个 `<system-reminder>…</available_skills>`
        // 会被画成右侧的蓝色气泡，看起来像用户自己粘贴了一段提示词。
        // 正确做法是收进 raw（默认隐藏，打开"显示模型可见的原始事件"才看得到）。
        let sourceKind = event.string("data.source.kind") ?? ""
        guard sourceKind == "user" else {
            upsert(
                TimelineItem(
                    id: Self.durableId(event.seq), seq: event.seq, time: event.time,
                    kind: .raw(type: "user/message · \(sourceKind.isEmpty ? "?" : sourceKind)", data: event.data)
                ),
                into: &delta
            )
            return
        }

        let content = event.data.array("content") ?? []
        let text = content.compactMap { block -> String? in
            guard block.string("type") == "text" else { return nil }
            return block.string("text")
        }.joined(separator: "\n\n")
        let images: [TimelineItem.ImageRef] = content.compactMap { block in
            guard block.string("type") == "image" else { return nil }
            return imageRef(from: block["attachment"], sessionId: header?.id)
        }
        let files: [TimelineItem.FileRef] = content.compactMap { block in
            guard block.string("type") == "file" else { return nil }
            let attachment = block["attachment"]
            return TimelineItem.FileRef(
                attachmentId: attachment?.string("attachmentId") ?? UUID().uuidString,
                name: attachment?.string("name"),
                byteSize: attachment?.int("byteSize") ?? attachment?.int("size")
            )
        }
        let rpcId = event.string("data.source.rpcId")

        // 与乐观插入 / 队列项去重：同一 rpcId 只留一条。
        if let rpcId, let existingId = optimisticItems.removeValue(forKey: rpcId) ?? inboxItems.removeValue(forKey: rpcId),
           let index = indexById[existingId] {
            // 被接管的可能是**已经标成 shadowed 的队列项**：消息进队列时建了一条
            // `inbox-<rpcId>`，队列被消费时 `applyInbox` 把它标成 shadowed，
            // 随后真正的 `user/message` 带着**同一个 rpcId** 到达、接管它。
            //
            // 所以这里有两件事必须做对：
            //   1. **清掉 `isShadowed`** —— 不清就继承"已隐藏"，用户的提示词整条消失
            //      （实测踩过：用户在 App 里发的消息自己看不到，还以为是 App 吞了）；
            //   2. **按新的 seq 重新入位** —— 原来只是就地改 `seq`，条目还留在旧位置
            //      （队列项的临时 seq 在 `turn/start` 之前），于是轮次分组把它当成
            //      轮次外的条目，用户消息在摘要上面出不来。
            var taken = items[index]
            items.remove(at: index)
            rebuildIndex()
            taken.seq = event.seq
            taken.time = event.time
            taken.id = Self.durableId(event.seq)
            taken.isShadowed = false
            taken.kind = .userMessage(.init(
                text: text, images: images, files: files, rpcId: rpcId, isPending: false, isQueued: false
            ))
            // 旧的 id 要在 delta 里说明"它没了"，否则界面会留着那条待发项。
            delta.removedIds.append(existingId)
            upsert(taken, into: &delta)
            return
        }

        upsert(
            TimelineItem(
                id: Self.durableId(event.seq), seq: event.seq, time: event.time,
                kind: .userMessage(.init(text: text, images: images, files: files, rpcId: rpcId, isPending: false))
            ),
            into: &delta
        )
        delta.shouldFollowScroll = true
    }

    private mutating func applyAssistantMessage(_ event: SessionEvent, into delta: inout TimelineDelta) {
        let content = event.data.array("message.content") ?? event.data.array("message") ?? []
        let blocks: [TimelineItem.AssistantBlock] = content.compactMap { block in
            switch block.string("type") {
            case "text":
                return .text(block.string("text") ?? "")
            case "reasoning":
                // 空/纯空白的推理块不产出 —— 画出来就是一张空的"思考过程"卡片。
                let reasoning = block.string("text") ?? ""
                return reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : .reasoning(reasoning)
            case "tool-call":
                return .toolCall(callId: block.string("id") ?? "", name: block.string("name") ?? "")
            case "image":
                return imageRef(from: block["attachment"], sessionId: header?.id).map { .image($0) }
            default:
                return nil
            }
        }
        let message = TimelineItem.AssistantMessage(
            blocks: blocks,
            usage: event.data["usage"].map(MessageUsage.init(json:)),
            messageId: event.string("data.message.id"),
            isStreaming: false,
            interrupted: event.data["interrupted"] != nil,
            isSettled: true
        )

        // 实时项接管：同 (turn, step) 的实时项就地变成持久项，复用 id。
        let turn = event.int("data.turn")
        let step = event.int("data.step")
        if let attempt = liveAttempt, attempt.turn == turn, attempt.step == step,
           let index = indexById[attempt.itemId] {
            let liveId = attempt.itemId
            items[index].seq = event.seq
            items[index].time = event.time
            items[index].id = Self.durableId(event.seq)
            items[index].kind = .assistantMessage(message)
            indexById[liveId] = nil
            indexById[Self.durableId(event.seq)] = index
            liveAttempt = nil
            delta.updated.append(items[index])
            for call in attempt.toolCalls.values where !call.id.isEmpty {
                ensureToolItem(callId: call.id, name: call.name, arguments: call.arguments, seq: event.seq, time: event.time, turn: turn, step: step, into: &delta)
            }
            return
        }

        upsert(
            TimelineItem(
                id: Self.durableId(event.seq), seq: event.seq, time: event.time, turn: turn, step: step,
                kind: .assistantMessage(message)
            ),
            into: &delta
        )
        // 助手消息里声明的工具调用：**立刻**建出工具行（用它自己的 seq），
        // 随后的 tool/call 事件就地补全而不是再插一条。
        for block in blocks {
            guard case .toolCall(let callId, let name) = block, !callId.isEmpty else { continue }
            let arguments = content.first { $0.string("type") == "tool-call" && $0.string("id") == callId }?.string("arguments") ?? ""
            ensureToolItem(callId: callId, name: name, arguments: arguments, seq: event.seq, time: event.time, turn: turn, step: step, into: &delta)
        }
        delta.shouldFollowScroll = true
    }

    /// 保证 `tool-<callId>` 这一条存在。已存在就只记住映射，不改状态。
    private mutating func ensureToolItem(
        callId: String,
        name: String,
        arguments: String,
        seq: Double,
        time: Date,
        turn: Int?,
        step: Int?,
        into delta: inout TimelineDelta
    ) {
        let itemId = "tool-\(callId)"
        toolCalls[callId] = itemId
        guard indexById[itemId] == nil else { return }
        upsert(
            TimelineItem(
                id: itemId, seq: seq, time: time, turn: turn, step: step,
                kind: .toolCall(.init(callId: callId, name: name, arguments: arguments, startedAt: time))
            ),
            into: &delta
        )
    }

    private mutating func applyToolCall(_ event: SessionEvent, into delta: inout TimelineDelta) {
        let callId = event.string("data.callId") ?? ""
        let name = event.string("data.name") ?? "tool"
        let arguments = event.string("data.arguments") ?? ""
        guard !callId.isEmpty else { return }
        let itemId = "tool-\(callId)"

        if let index = indexById[itemId] {
            // 助手消息里已经建过占位：就地补上规范数据，状态保持。
            if case .toolCall(var call) = items[index].kind {
                call.name = name
                call.arguments = arguments
                items[index].kind = .toolCall(call)
                items[index].turn = event.int("data.turn")
                items[index].step = event.int("data.step")
                delta.updated.append(items[index])
            }
            toolCalls[callId] = itemId
            return
        }

        toolCalls[callId] = itemId
        upsert(
            TimelineItem(
                id: itemId, seq: event.seq, time: event.time,
                turn: event.int("data.turn"), step: event.int("data.step"),
                kind: .toolCall(.init(callId: callId, name: name, arguments: arguments, startedAt: event.time))
            ),
            into: &delta
        )
        delta.shouldFollowScroll = true
    }

    private mutating func applyToolResult(_ event: SessionEvent, into delta: inout TimelineDelta) {
        let callId = event.string("data.message.toolCallId") ?? event.string("data.callId") ?? ""
        guard !callId.isEmpty else { return }
        let itemId = toolCalls[callId] ?? "tool-\(callId)"
        let output = Self.plainText(of: event.data.array("message.content") ?? [])
        let isError = event.bool("data.message.isError") ?? (event.data["error"] != nil)

        if let index = indexById[itemId] {
            if case .toolCall(var call) = items[index].kind {
                call.status = isError ? .failed : .success
                call.output = output
                call.isError = isError
                call.endedAt = event.time
                call.rawResult = event.data
                items[index].kind = .toolCall(call)
                delta.updated.append(items[index])
            }
            return
        }

        // 历史里只加载到了 result（会话中段进入）：仍然渲染出来。
        toolCalls[callId] = itemId
        upsert(
            TimelineItem(
                id: itemId, seq: event.seq, time: event.time,
                turn: event.int("data.turn"), step: event.int("data.step"),
                kind: .toolCall(.init(
                    callId: callId,
                    name: event.string("data.meta.name") ?? "tool",
                    arguments: "",
                    status: isError ? .failed : .success,
                    output: output,
                    isError: isError,
                    startedAt: event.time,
                    endedAt: event.time,
                    rawResult: event.data
                ))
            ),
            into: &delta
        )
    }

    private mutating func applyInbox(_ event: SessionEvent, into delta: inout TimelineDelta) {
        let removed = event.int("data.removedCount") ?? 0
        // `start` 是**下标**：这个事件是"从第 start 条起删掉 removedCount 条、
        // 再把 inserted 插进去"的一次 splice。
        let start = event.int("data.start") ?? 0
        if removed > 0 {
            // **只撤掉被消化的那几条。**
            //
            // 之前这里把**所有**队列项都标成已隐藏 —— 于是宿主消化掉一条之后，
            // 手机上剩下的排队消息**全都不见了**（用户："排队的消息在手机上看不到"）。
            // 更糟的是它们既不在队列区、也不在时间线里（队列项本来就不进时间线），
            // 等于凭空消失。
            //
            // 队列是先进先出，所以按**插入顺序**取 `[start, start+removed)` 那一段。
            let ordered = inboxItems.values
                .compactMap { indexById[$0] }
                .sorted()
                .map { items[$0].id }
            for itemId in ordered.dropFirst(start).prefix(removed) {
                guard let index = indexById[itemId] else { continue }
                items[index].isShadowed = true
                delta.shadowedIds.append(itemId)
                if let rpcId = inboxItems.first(where: { $0.value == itemId })?.key {
                    inboxItems.removeValue(forKey: rpcId)
                }
            }
        }
        guard event.string("data.outcome") == nil else { return }
        for inserted in event.array("data.inserted") ?? [] {
            let rpcId = inserted.string("source.rpcId") ?? UUID().uuidString
            let text = Self.plainText(of: inserted.array("content") ?? [])
            // **丢掉"审批策略变了"这类机器通知。**
            //
            // `dsh-user-approval` 在策略变化时走 `agent.inject(createUserMessage(…))`，
            // 把一句 `The approval policy changed from "x" to "y" (changed by the user).`
            // 当成**用户消息**塞进队列。而 `/permission <preset>` 一次改两样
            //（沙箱模式 + 审批策略），于是切一次权限就冒出**两条排队消息**。
            //
            // 用户没说过这两句话，而且权限已经显示在输入框的胶囊上了 —— 纯噪音。
            //
            // 注意：这是**版本耦合**的判断（匹配 DSH 硬编码的那句英文模板）。
            // 宿主换措辞的话这里会失效 —— 失效的后果只是噪音回来，不会丢用户消息。
            if Self.isMachineNotice(text) { continue }
            // **优先用服务端那条消息的 id 当条目 id** —— `session/updateQueue`
            // 要的 `itemId` 就是它（编辑/删除/插队都按它定位）。
            // 拿不到才退回本地的 `inbox-<rpcId>`。
            let itemId = inserted.string("id") ?? "inbox-\(rpcId)"
            inboxItems[rpcId] = itemId
            upsert(
                TimelineItem(
                    id: itemId, seq: nextTransientSeq(), time: event.time,
                    kind: .userMessage(.init(text: text, rpcId: rpcId, isPending: true, isQueued: true))
                ),
                into: &delta
            )
        }
        delta.shouldFollowScroll = true
    }

    private mutating func applyApprovalAsked(_ event: SessionEvent, into delta: inout TimelineDelta) {
        let approvalId = event.string("data.id") ?? ""
        guard !approvalId.isEmpty else { return }
        let itemId = "approval-\(approvalId)"
        approvals[approvalId] = itemId
        let options = Self.approvalOptions(from: event.data["options"])
        upsert(
            TimelineItem(
                id: itemId, seq: event.seq, time: event.time,
                kind: .approval(.init(
                    approvalId: approvalId,
                    callId: event.string("data.callId"),
                    toolName: event.string("data.toolName") ?? "工具",
                    reason: event.string("data.reason") ?? "",
                    options: options
                ))
            ),
            into: &delta
        )
        delta.shouldFollowScroll = true
    }

    private mutating func applyApprovalDecided(_ event: SessionEvent, into delta: inout TimelineDelta) {
        let approvalId = event.string("data.id") ?? ""
        guard let itemId = approvals[approvalId] ?? (approvalId.isEmpty ? nil : "approval-\(approvalId)"),
              let index = indexById[itemId]
        else { return }
        if case .approval(var approval) = items[index].kind {
            approval.decision = .init(raw: event.string("data.outcome"))
            approval.decidedAt = event.time
            items[index].kind = .approval(approval)
            delta.updated.append(items[index])
        }
    }

    private mutating func applyCompaction(_ event: SessionEvent, into delta: inout TimelineDelta) {
        let summary = Self.plainText(of: event.data.array("summary") ?? [])
        let phase: TimelineItem.Compaction.Phase
        switch event.type {
        case "compaction/start": phase = .start
        case "compaction/summary": phase = .summary
        case "compaction/prune": phase = .prune
        default: phase = .end
        }
        upsert(
            TimelineItem(
                id: Self.durableId(event.seq), seq: event.seq, time: event.time,
                kind: .compaction(.init(phase: phase, summary: summary))
            ),
            into: &delta
        )
    }

    // MARK: - 实时项退休

    private mutating func retireLiveAttempt(turn: Int?, step: Int?, into delta: inout TimelineDelta) {
        guard let attempt = liveAttempt else { return }
        if let turn, let step, (attempt.turn != turn || attempt.step != step) { return }
        liveAttempt = nil
        // 未结算的实时项（没有等到持久事件）就把光标收掉，内容留着。
        if let index = indexById[attempt.itemId],
           case .assistantMessage(var message) = items[index].kind,
           !message.isSettled {
            message.isStreaming = false
            items[index].kind = .assistantMessage(message)
            delta.updated.append(items[index])
        }
    }

    // MARK: - 索引维护

    private mutating func upsert(_ item: TimelineItem, into delta: inout TimelineDelta) {
        if let index = indexById[item.id] {
            items[index] = item
            delta.updated.append(item)
            return
        }
        // 按 seq 找插入位置（大多数时候是追加到尾部）。
        let position = items.lastIndex { $0.seq <= item.seq }.map { $0 + 1 } ?? 0
        items.insert(item, at: position)
        indexById[item.id] = position
        reindex(from: position + 1)
        delta.inserted.append(item)
    }

    private mutating func reindex(from start: Int) {
        guard start < items.count else { return }
        for index in start..<items.count {
            indexById[items[index].id] = index
        }
    }

    private mutating func rebuildIndex() {
        indexById.removeAll(keepingCapacity: true)
        for (index, item) in items.enumerated() { indexById[item.id] = index }
    }

    // MARK: - 工具

    /// 持久事件的条目 id。整数 seq 写成 `e5` 而不是 `e5.0` ——
    /// id 会出现在无障碍标签、测试断言与日志里，别让浮点尾巴漏出去。
    static func durableId(_ seq: Double) -> String {
        if seq.rounded() == seq, abs(seq) < 9_007_199_254_740_992 {
            return "e\(Int(seq))"
        }
        return "e\(seq)"
    }

    /// 实时项用的"挤在末尾"的 seq：`durableCursor + 1 - 1/(n+1)`。
    /// 与 DSH 客户端同构，保证实时内容永远排在最后一条持久事件之后。
    private var transientCounter = 0
    private mutating func nextTransientSeq() -> Double {
        transientCounter += 1
        return lastSeq.rounded(.down) + 1 - 1 / Double(transientCounter + 1)
    }

    private func blocks(for attempt: LiveAttempt) -> [TimelineItem.AssistantBlock] {
        var blocks: [TimelineItem.AssistantBlock] = []
        if !attempt.reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(.reasoning(attempt.reasoning))
        }
        if !attempt.text.isEmpty { blocks.append(.text(attempt.text)) }
        for index in attempt.toolCalls.keys.sorted() {
            guard let call = attempt.toolCalls[index], !call.id.isEmpty else { continue }
            blocks.append(.toolCall(callId: call.id, name: call.name))
        }
        return blocks
    }

    private static func plainText(of blocks: [JSONValue]) -> String {
        blocks.compactMap { block -> String? in
            switch block.string("type") {
            case "text": return block.string("text")
            case "reasoning": return nil
            default: return nil
            }
        }.joined()
    }

    private static func approvalOptions(from value: JSONValue?) -> [TimelineItem.Approval.Option] {
        guard let array = value?.arrayValue else { return [] }
        return array.compactMap { entry in
            let kind = entry.string("kind") ?? entry.string("outcome") ?? entry.string("id") ?? ""
            guard !kind.isEmpty else { return nil }
            return TimelineItem.Approval.Option(
                kind: kind,
                label: entry.string("label") ?? entry.string("title") ?? kind,
                isPrimary: entry.bool("primary") ?? entry.bool("isPrimary") ?? false
            )
        }
    }

    private func imageRef(from value: JSONValue?, sessionId: String?) -> TimelineItem.ImageRef? {
        guard let value else { return nil }
        guard let attachmentId = value.string("attachmentId") ?? value.string("id") else { return nil }
        return TimelineItem.ImageRef(
            attachmentId: attachmentId,
            name: value.string("name"),
            mediaType: value.string("mediaType") ?? "image/png",
            width: value.int("width"),
            height: value.int("height"),
            sessionId: sessionId
        )
    }

    private func noteText(modelSelection value: JSONValue) -> String {
        let provider = value.string("provider") ?? ""
        let model = value.string("model") ?? ""
        let effort = value.string("reasoningEffort")
        var text = model.isEmpty ? provider : "\(provider) · \(model)"
        if let effort, !effort.isEmpty { text += " · \(effort)" }
        return text
    }

    private func noteText(controlEvent event: SessionEvent) -> String {
        switch event.type {
        case "sandbox/mode": return event.string("data.mode") ?? ""
        case "permission/preset": return event.string("data.preset") ?? ""
        case "approval/policy": return event.string("data.policy") ?? ""
        case "agent-preset/selected": return event.string("data.agentPreset") ?? ""
        default: return event.type
        }
    }

    private func symbolName(forControl type: String) -> String {
        switch type {
        case "sandbox/mode": return "shield.lefthalf.filled"
        case "permission/preset": return "lock.shield"
        case "approval/policy": return "hand.raised"
        case "agent-preset/selected": return "person.crop.square"
        default: return "info.circle"
        }
    }
}
