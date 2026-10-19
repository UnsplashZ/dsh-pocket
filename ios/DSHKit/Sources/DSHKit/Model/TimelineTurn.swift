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
    public var items: [TimelineItem] {
        didSet { deriveCollections() }
    }

    // MARK: 派生集合
    //
    // **在构造时算一次，不要做成 computed property。**
    // 这些属性每个都要扫一遍 `items`（其中两个还要排序），而 `body` 会挨个读它们 ——
    // 每次渲染就是六七遍全扫 + 一次排序。渲染比 publish 频繁得多（滚动、动画都会触发），
    // 长轮次上这就是卡顿的来源。

    /// 默认留在明面上的那条：**最后一个有正文的助手消息**。
    public private(set) var headline: TimelineItem?
    /// **永远不折叠**的那些：用户自己说的话。
    public private(set) var pinned: [TimelineItem] = []
    /// 交付的产物（`present` 的 `deliverables/presented`）。
    ///
    /// 它也**永远留在明面上**：一轮跑完会收拢，产物卡要是跟着收进折叠区，
    /// 用户在时间线上就看不到"到底交付了什么"（用户："交付的文件看不到"）。
    /// 收起时它紧跟在结论后面渲染。
    public private(set) var deliverables: [TimelineItem] = []
    /// 收进摘要里的那些。
    public private(set) var collapsible: [TimelineItem] = []
    /// 摘要行下面、收起时渲染的内容。
    public private(set) var collapsedItems: [TimelineItem] = []
    /// 摘要行下面、展开时渲染的内容（按 seq 升序）。
    public private(set) var expandedItems: [TimelineItem] = []

    /// 这一轮花了多久。协议里**没有**时长字段，用两端事件的时间算。
    public var duration: TimeInterval? {
        guard let startedAt, let endedAt else { return nil }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }

    public init(
        turn: Int,
        isComplete: Bool,
        startedAt: Date?,
        endedAt: Date?,
        endReason: TimelineItem.TurnEndReason?,
        items: [TimelineItem]
    ) {
        self.turn = turn
        self.isComplete = isComplete
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.endReason = endReason
        self.items = items
        // `didSet` 在 init 里不触发，显式算一次。
        deriveCollections()
    }

    /// 摘要里有多少东西 —— 决定摘要行要不要显示计数。
    public var collapsedCount: Int { collapsible.count }

    /// 把所有派生集合算好。构造时调一次。
    private mutating func deriveCollections() {
        // 结论 = 最后一个有正文的助手消息。中间那些"我先看一下…"跟工具行一起收起来。
        headline = items.last { item in
            guard case .assistantMessage(let message) = item.kind else { return false }
            return !message.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        // 用户消息永远不折叠：宿主的事件顺序是 `turn/start` → `user/message` → … → `turn/end`，
        // 提示词**在轮次里面**，不挑出来就会被当成"轮内过程"收进摘要。
        pinned = items.filter { if case .userMessage = $0.kind { return true }; return false }
        // 产物跟用户消息一样是"这一轮的产出"，不参与折叠。
        deliverables = items.filter { if case .deliverables = $0.kind { return true }; return false }
        let headlineId = headline?.id
        let pinnedIds = Set(pinned.map(\.id))
        collapsible = items.filter { item in
            switch item.kind {
            case .turnStart, .turnEnd, .userMessage, .deliverables:
                return false
            default:
                return item.id != headlineId && !pinnedIds.contains(item.id)
            }
        }
        // 用户消息不在这里 —— 它在摘要行**上面**单独渲染，放进来会重复画一遍。
        // 产物排在结论**后面**：先给"做完了什么"，再给"交付了什么"。
        collapsedItems = [headline].compactMap { $0 } + deliverables
        // 展开后必须回到原始时序（产物也算在内 —— 它只是"不参与折叠"，
        // 不是"不渲染"，所以「N 步」那个计数里也不该算它）。
        expandedItems = (collapsible + [headline].compactMap { $0 } + deliverables)
            .sorted { $0.seq < $1.seq }
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
        /// **窗口顶部那半截轮次**：它在 `turn/start` 之前，因为我们只加载到了
        /// 这一轮的中段（`session/page` 按 seq 往回翻，边界落在哪就是哪）。
        var leading: [TimelineItem] = []
        /// `leading` 里有没有"属于某一轮"的条目。
        ///
        /// 没有的话它只是会话头（`session/title`、权限 note、压缩记录…），
        /// 那些本来就该一条条独立渲染；有的话它就是一轮的尾巴，必须整体收拢。
        var leadingHasTurnItems = false

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

        /// 收掉窗口顶部那半截。
        ///
        /// **为什么不能一条条摊出去**：一轮里能有几十上百条过程消息
        ///（思考、工具调用、过场说明）。窗口顶部那半截没有 `turn/start`，
        /// 老代码于是把每一条都当成"轮次之外的独立条目"渲染 ——
        /// 用户往上翻历史时，屏幕上是**一大串思考和过程**，只有一路滚到
        /// 这轮真正的开头（`turn/start` 也被加载进来）才会突然收拢
        ///（用户："优先获取完结的那份回复，而不是逐条获取，滚动到合适位置才收缩"）。
        ///
        /// 正确做法：把这段尾巴连同它的 `turn/end` 收成**一个**轮次块。
        /// 有 `turn/end` → `isComplete` 为真 → 照常收拢成「摘要 + 结论」；
        /// 没有（整条会话就一轮、还在跑）→ 走"跑着就全展开"那条路，也是对的。
        func flushLeading() {
            guard !leading.isEmpty else { return }
            let chunk = leading
            let hasTurnItems = leadingHasTurnItems
            leading = []
            leadingHasTurnItems = false
            guard hasTurnItems else {
                blocks.append(contentsOf: chunk.map { TimelineBlock.item($0) })
                return
            }
            let endItem = chunk.last { if case .turnEnd = $0.kind { return true }; return false }
            var reason: TimelineItem.TurnEndReason?
            var endTurn: Int?
            if case .turnEnd(let value, let endReason)? = endItem?.kind {
                endTurn = value
                reason = endReason
            }
            // 轮号：优先用 `turn/end` 自己声明的，退而取这段里第一条带轮号的。
            // 它同时是这个块的 id（`turn-<n>`），而它一定是**最小**的轮号
            //（它在最顶上），不会跟后面的完整轮次撞 id。
            let turn = endTurn ?? chunk.compactMap(\.turn).first ?? 0
            blocks.append(.turn(TimelineTurn(
                turn: turn,
                isComplete: endItem != nil,
                // 开头没加载到 → 没有真实起点，时长就算不出来（宁可不显示，也不瞎算）。
                startedAt: nil,
                endedAt: endItem?.time,
                endReason: reason,
                items: chunk
            )))
        }

        for item in source {
            switch item.kind {
            case .turnStart(let turn):
                // 上一个轮次没关就开了新的（中断/异常）→ 先把旧的收掉。
                flushLeading()
                flushTurn()
                currentTurn = turn
                bucket = [item]
            case .turnEnd(let turn, _):
                if currentTurn == turn {
                    bucket.append(item)
                    flushTurn()
                } else if currentTurn == nil, leadingHasTurnItems {
                    // **窗口正好从这一轮的中段开始**：把结束事件补进顶部那半截，
                    // 整段就成了一次"缺开头但有结尾"的轮次 —— 于是它照常收拢，
                    // 而不是把几十条过程消息一条条摊在屏幕上。
                    leading.append(item)
                    flushLeading()
                } else {
                    // 找不到对应 `turn/start` 的结束事件：单独收成一组，
                    // 总比把条目漏掉强。
                    flushLeading()
                    flushTurn()
                    blocks.append(.turn(TimelineTurn(
                        turn: turn, isComplete: true,
                        startedAt: nil, endedAt: item.time, endReason: nil, items: [item]
                    )))
                }
            default:
                if currentTurn != nil {
                    bucket.append(item)
                } else if leadingHasTurnItems || item.turn != nil {
                    // 已经在顶部那半截里，或这条本身就带着轮号（属于某一轮）。
                    if item.turn != nil { leadingHasTurnItems = true }
                    leading.append(item)
                } else {
                    blocks.append(.item(item))
                }
            }
        }
        flushLeading()
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

extension Array where Element == TimelineBlock {
    /// 这批块里有没有**对话内容**（轮次，或轮次之外的任何非 note 条目）。
    ///
    /// 真机案例（2026-10-19）：一个只切过权限的新会话，主机日志里只有
    /// `permission/preset`、`sandbox/mode`、`approval/policy`、`model/selection`
    /// 这些控制事件，一条对话都没有。它们全是 `isConversational == true` 的
    /// `note`，于是视图照常渲染 —— 屏幕上就是几行 `workspace-write`／`ask`
    /// 配着大片空白，用户看到的是"页面坏了、重进也没反应"。
    ///
    /// 这些 note 是**配置现状**（输入框的权限胶囊与模型标签都在显示），
    /// 所以"只有控制 note"的会话应当按空会话呈现。
    public var hasConversation: Bool {
        contains { block in
            switch block {
            case .turn: return true
            case .item(let item):
                if case .note = item.kind { return false }
                return true
            }
        }
    }

    /// 找到**包含**某条目的那个块的 id。
    ///
    /// 用在"补完历史之后滚到新进来的第一条"上：那条条目很可能已经被收进一个
    /// 收拢的轮次块里（窗口顶部那半截，或者页边界落在某个已加载轮次的中段），
    /// 而收拢状态下只有摘要与结论带 `.id` —— 条目自己的 id **不在视图里**，
    /// `ScrollViewReader.scrollTo` 会静默什么都不做，屏幕上一点变化都没有
    ///（用户会以为「点了没反应」）。滚它所属的那个块才是稳的锚点。
    ///
    /// 找不到（条目被 `isShadowed` / `isConversational` 过滤掉了）返回 `nil`。
    public func blockId(containing itemId: String) -> String? {
        for block in self {
            switch block {
            case .item(let item):
                if item.id == itemId { return block.id }
            case .turn(let turn):
                if turn.items.contains(where: { $0.id == itemId }) { return block.id }
            }
        }
        return nil
    }
}
