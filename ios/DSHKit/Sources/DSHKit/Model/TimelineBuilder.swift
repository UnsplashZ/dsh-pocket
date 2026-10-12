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
    public private(set) var replacements: [(seq: Double, start: Int, end: Int)] = []

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

    public var isEmpty: Bool { items.isEmpty }

    /// 默认视图要渲染的条目（去掉 `raw`、被遮住的单独由 UI 决定）。
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
            let name = event.string("data.name") ?? event.string("data.agentId") ?? "子 agent"
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
                        text: event.string("data.name") ?? "命令",
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
                kind: .userMessage(.init(text: text, images: images, files: files, rpcId: rpcId, isPending: true))
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
            replacements.append((seq: event.seq, start: start, end: end))
            return shadowed
        }
    }

    // MARK: - 各事件的具体折叠

    private mutating func applyUserMessage(_ event: SessionEvent, into delta: inout TimelineDelta) {
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
            items[index].seq = event.seq
            items[index].time = event.time
            items[index].id = Self.durableId(event.seq)
            items[index].kind = .userMessage(.init(
                text: text, images: images, files: files, rpcId: rpcId, isPending: false
            ))
            indexById[existingId] = nil
            indexById[Self.durableId(event.seq)] = index
            delta.updated.append(items[index])
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
                return .reasoning(block.string("text") ?? "")
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
        if removed > 0 {
            // 队列项被消化掉了：留着也没意义，直接撤掉。
            for (rpcId, itemId) in inboxItems where indexById[itemId] != nil {
                _ = rpcId
                if let index = indexById[itemId] {
                    items[index].isShadowed = true
                    delta.shadowedIds.append(itemId)
                }
            }
        }
        guard event.string("data.outcome") == nil else { return }
        for inserted in event.array("data.inserted") ?? [] {
            let rpcId = inserted.string("source.rpcId") ?? UUID().uuidString
            let text = Self.plainText(of: inserted.array("content") ?? [])
            let itemId = "inbox-\(rpcId)"
            inboxItems[rpcId] = itemId
            upsert(
                TimelineItem(
                    id: itemId, seq: nextTransientSeq(), time: event.time,
                    kind: .userMessage(.init(text: text, rpcId: rpcId, isPending: true))
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
        if !attempt.reasoning.isEmpty { blocks.append(.reasoning(attempt.reasoning)) }
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
