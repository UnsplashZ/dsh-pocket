import Foundation

/// 一个**轮次**的时间线分组。
///
/// 桌面端的做法是：一轮跑完，把这一轮里的思考、命令、中间说明**统一收拢**到
/// 一行「已完成，用时 X」下面，只留最终结论在明面上。手机上同样需要 ——
/// 一个跑了 34 分钟的轮次能刷出几十屏，真正要看的往往只有最后那段话。
///
/// 分组规则：`turn/start` 开、`turn/end` 关，中间的条目属于这一轮；
/// 轮次之外的（会话头、用户消息…）不归组，照常显示。
public struct TimelineTurn: Sendable, Identifiable {
    public var id: Int { turn }
    public var turn: Int
    /// 这一轮跑完了没有。没跑完就**照常全展开**（正在发生的事没有收拢的道理）。
    public var isComplete: Bool
    public var startedAt: Date?
    public var endedAt: Date?
    public var endReason: TimelineItem.TurnEndReason?
    /// 轮内条目（含 `turn/start` 与 `turn/end` 本身），按 seq 升序。
    public var items: [TimelineItem]

    /// 这一轮花了多久。协议里**没有**时长字段，用两端事件的时间算。
    public var duration: TimeInterval? {
        guard let startedAt, let endedAt else { return nil }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }

    /// 默认留在明面上的那条：**最后一个有正文的助手消息**。
    ///
    /// 中间那些"我先看一下…"之类的过场话跟工具行一起收起来 ——
    /// 它们对回看没有价值，只会把结论挤下去。
    public var headline: TimelineItem? {
        items.last { item in
            guard case .assistantMessage(let message) = item.kind else { return false }
            return !message.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// **永远不折叠**的那些：用户自己说的话。
    ///
    /// 宿主的事件顺序是 `turn/start` → `user/message` → … → `turn/end`，
    /// 也就是说用户的提示词**在轮次里面**。不特意挑出来的话，它会被当成
    /// "轮内过程"一起收进摘要 —— 用户会以为自己的话被吞了。
    public var pinned: [TimelineItem] {
        items.filter { if case .userMessage = $0.kind { return true }; return false }
    }

    /// 收进摘要里的那些（`turn/start`、`turn/end`、用户消息、结论除外）。
    public var collapsible: [TimelineItem] {
        let headlineId = headline?.id
        let pinnedIds = Set(pinned.map(\.id))
        return items.filter { item in
            switch item.kind {
            case .turnStart, .turnEnd, .userMessage:
                return false
            default:
                return item.id != headlineId && !pinnedIds.contains(item.id)
            }
        }
    }

    /// 摘要里有多少东西 —— 决定摘要行要不要显示计数。
    public var collapsedCount: Int { collapsible.count }

    /// 摘要行**下面**收起时渲染的内容：只有结论。
    ///
    /// 用户消息不在这里 —— 它在摘要行**上面**单独渲染（永远可见），
    /// 放进来会重复画一遍。
    public var collapsedItems: [TimelineItem] {
        [headline].compactMap { $0 }
    }

    /// 摘要行**下面**展开时渲染的内容：全过程 + 结论，**按时间顺序**。
    ///
    /// 展开后必须回到原始时序 —— 之前是"摘要 → 结论 → 过程"，
    /// 过程跑到结论下面去了，读起来完全反了。
    public var expandedItems: [TimelineItem] {
        ordered(collapsible + [headline].compactMap { $0 })
    }

    private func ordered(_ list: [TimelineItem]) -> [TimelineItem] {
        list.sorted { $0.seq < $1.seq }
    }
}

extension TimelineBuilder {
    /// 把条目按轮次分组，保持原有顺序。
    ///
    /// 返回的是**有序的块**：`turn` 是成组的轮次，`item` 是轮次之外的独立条目。
    /// 视图照着渲染就行，不用自己再扫一遍。
    ///
    /// **过滤必须跟 `publish()` 保持一致**：这里曾经只过滤 shadowed，
    /// 于是"只有工具调用"的助手消息（`isConversational == false`）照样进了轮次分组，
    /// 渲染成一张**只有时间、没有任何文字的空白卡片** —— 在 `SessionView` 里
    /// 直接渲染 `items` 的时候是看不到的，因为那批早就被过滤过了。
    public func timelineBlocks(showRawEvents: Bool = false) -> [TimelineBlock] {
        let source = items.filter { item in
            guard !showRawEvents else { return true }
            return !item.isShadowed && item.isConversational
        }
        var blocks: [TimelineBlock] = []
        var currentTurn: Int?
        var bucket: [TimelineItem] = []

        func flushTurn() {
            guard let turn = currentTurn, !bucket.isEmpty else { return }
            let startItem = bucket.first { if case .turnStart = $0.kind { return true }; return false }
            let endItem = bucket.last { if case .turnEnd = $0.kind { return true }; return false }
            var reason: TimelineItem.TurnEndReason?
            if case .turnEnd(_, let value)? = endItem?.kind { reason = value }
            blocks.append(.turn(TimelineTurn(
                turn: turn,
                isComplete: endItem != nil,
                startedAt: startItem?.time,
                endedAt: endItem?.time,
                endReason: reason,
                items: bucket
            )))
            bucket = []
            currentTurn = nil
        }

        for item in source {
            switch item.kind {
            case .turnStart(let turn):
                // 上一个轮次没关就开了新的（中断/异常）→ 先把旧的收掉。
                flushTurn()
                currentTurn = turn
                bucket = [item]
            case .turnEnd(let turn, _):
                if currentTurn == turn {
                    bucket.append(item)
                    flushTurn()
                } else {
                    // 找不到对应 `turn/start` 的结束事件：单独收成一组，
                    // 总比把条目漏掉强。
                    flushTurn()
                    blocks.append(.turn(TimelineTurn(
                        turn: turn, isComplete: true,
                        startedAt: nil, endedAt: item.time, endReason: nil, items: [item]
                    )))
                }
            default:
                if currentTurn != nil {
                    bucket.append(item)
                } else {
                    blocks.append(.item(item))
                }
            }
        }
        flushTurn()
        return blocks
    }
}

/// `timelineBlocks()` 的两种块。
public enum TimelineBlock: Sendable, Identifiable {
    case turn(TimelineTurn)
    /// 轮次之外的独立条目（会话头、用户消息…）。
    case item(TimelineItem)

    public var id: String {
        switch self {
        case .turn(let turn): return "turn-\(turn.turn)"
        case .item(let item): return item.id
        }
    }
}
