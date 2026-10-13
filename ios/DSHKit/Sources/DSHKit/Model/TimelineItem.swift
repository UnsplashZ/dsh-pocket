import Foundation

/// 时间线上的一条可渲染项。
///
/// 身份（`id`）是稳定的、可跨更新复用的：
///   · 持久事件 → `"e<seq>"`
///   · 工具调用 → `"tool-<callId>"`（`tool/call` 与 `tool/result` 合并到同一条）
///   · 实时流式 → `"live-<attemptId>"`
///   · 队列中的消息 → `"inbox-<rpcId>"`
///
/// 流式转持久时我们**沿用实时项的 id**，所以 SwiftUI 不会闪一下重建视图。
public struct TimelineItem: Sendable, Identifiable, Hashable, Codable {
    public internal(set) var id: String
    /// 排序键。持久事件是自己的 seq；实时块用 `durableCursor + 1 - 1/(n+1)` 挤在末尾。
    public internal(set) var seq: Double
    public internal(set) var time: Date
    public internal(set) var turn: Int?
    public internal(set) var step: Int?
    /// 被某次 `surfaceOp.replace` 遮住：仍在时间线里，但默认收进"已压缩取代"。
    public internal(set) var isShadowed: Bool
    public internal(set) var kind: Kind

    public init(
        id: String,
        seq: Double,
        time: Date,
        turn: Int? = nil,
        step: Int? = nil,
        isShadowed: Bool = false,
        kind: Kind
    ) {
        self.id = id
        self.seq = seq
        self.time = time
        self.turn = turn
        self.step = step
        self.isShadowed = isShadowed
        self.kind = kind
    }

    public var isDurable: Bool { seq.rounded() == seq }

    public var kindName: String {
        switch kind {
        case .turnStart: return "turn/start"
        case .turnEnd: return "turn/end"
        case .userMessage: return "user/message"
        case .assistantMessage: return "assistant/message"
        case .toolCall: return "tool"
        case .todo: return "todo/write"
        case .approval: return "approval"
        case .compaction: return "compaction"
        case .goal: return "goal/change"
        case .planMode: return "plan/mode"
        case .deliverables: return "deliverables/presented"
        case .note(let note): return note.sourceEventType
        case .raw(let type, _): return type
        case .unknown(let type, _): return type
        }
    }
}

// MARK: - 各种 Kind

extension TimelineItem {
    public enum Kind: Sendable, Hashable, Codable {
        /// `turn/start`：一轮对话开始。
        case turnStart(turn: Int)
        /// `turn/end`：一轮结束 + 结束原因。
        case turnEnd(turn: Int, reason: TurnEndReason)
        /// `user/message`。
        case userMessage(UserMessage)
        /// `assistant/message` 与实时流。
        case assistantMessage(AssistantMessage)
        /// `tool/call` 与 `tool/result` 合并后的一条。
        case toolCall(ToolCall)
        /// `todo/write`。
        case todo(TodoList)
        /// `approval/asked` + `approval/decided`。
        case approval(Approval)
        /// `compaction/*`。
        case compaction(Compaction)
        /// `goal/change`。
        case goal(Goal)
        /// `plan/mode`。
        case planMode(PlanMode)
        /// `deliverables/presented`。
        case deliverables([Deliverable])
        /// 一眼能看懂的说明行（模型切换、沙箱模式、权限预设、子 agent 启动…）。
        case note(Note)
        /// 已知、但不属于"对话"的原始事件（系统提示、request/header、模型流记录…）。
        /// 默认隐藏，会话菜单里的"显示模型可见的原始事件"打开后才渲染。
        case raw(type: String, data: JSONValue)
        /// 认不出的事件。**不丢**，折叠成一条"未知事件"，便于诊断页与协议漂移排查。
        case unknown(type: String, data: JSONValue)
    }

    /// 默认视图里要不要渲染这一条。
    ///
    /// 除了 `raw`（机器注入的上下文），**没有任何可渲染内容的助手消息也不渲染** ——
    /// 否则流式刚开始、或宿主发来一个空 `assistant/message` 时，
    /// 屏幕上会先冒出一个空气泡再被填上，看起来像"空消息"。
    public var isConversational: Bool {
        switch kind {
        case .raw:
            return false
        case .assistantMessage(let message):
            return message.hasRenderableContent
        case .userMessage(let message):
            // 队列项**不进时间线** —— 它只出现在底部的「排队中」区。
            // 两处都画的话，电脑上排队的任务看起来就像已经发出去了。
            return !message.isQueued
        default:
            return true
        }
    }

    public struct UserMessage: Sendable, Hashable, Codable {
        public var text: String
        public var images: [ImageRef]
        public var files: [FileRef]
        public var rpcId: String?
        /// 由客户端乐观插入、尚未在日志里出现。
        public var isPending: Bool
        /// **来自队列**（`agent/inbox/spliced` 建的项），不是已经发出去的消息。
        ///
        /// 必须跟"乐观插入"区分开：两者 `isPending` 都是 true，但
        ///   · 乐观插入 = **你自己刚发的**，该在时间线上立刻出现（"发送中…"）；
        ///   · 队列项 = **还没轮到它**，只该出现在底部的「排队中」区。
        /// 不区分的话队列项会被画成一个蓝色气泡、还带"发送中…"，
        /// 看起来就像消息已经发出去了（实测：电脑上排队的任务在手机上就是这样）。
        public var isQueued: Bool

        public init(
            text: String,
            images: [ImageRef] = [],
            files: [FileRef] = [],
            rpcId: String? = nil,
            isPending: Bool = false,
            isQueued: Bool = false
        ) {
            self.text = text
            self.images = images
            self.files = files
            self.rpcId = rpcId
            self.isPending = isPending
            self.isQueued = isQueued
        }
    }

    public struct AssistantMessage: Sendable, Hashable, Codable {
        public var blocks: [AssistantBlock]
        /// 这条消息的用量（`assistant/message` 的 `data.usage`）。
        public var usage: MessageUsage?
        /// 日志里这条消息的 id（`data.message.id`）。
        /// **评价（点赞点踩）按它索引**，不是 seq、也不是时间线条目的 id。
        public var messageId: String?
        public var isStreaming: Bool
        public var interrupted: Bool
        /// 实时块与持久事件交接后置为 true（用于诊断，也方便测试断言）。
        public var isSettled: Bool

        public init(
            blocks: [AssistantBlock],
            usage: MessageUsage? = nil,
            messageId: String? = nil,
            isStreaming: Bool = false,
            interrupted: Bool = false,
            isSettled: Bool = true
        ) {
            self.blocks = blocks
            self.usage = usage
            self.messageId = messageId
            self.isStreaming = isStreaming
            self.interrupted = interrupted
            self.isSettled = isSettled
        }

        /// 有没有值得画出来的东西。
        ///
        /// 两种块都**不算**：
        ///   · 空白（含只有换行/空格的）文本与推理块 —— 实测宿主会发来 `text: ""`
        ///     的 `reasoning` 块、以及流式刚开始的空 `text` 块，画出来就是一张
        ///     点不开也看不到内容的"思考过程"卡片、或者一个空气泡；
        ///   · `.toolCall` —— 工具调用走单独的 `ToolRow`，助手卡片对它是 `EmptyView`。
        ///     算进来的话，"只声明了一个工具调用"的助手消息会渲染成一张
        ///     **只有时间、没有任何文字的空白卡片**（实测就是这样）。
        public var hasRenderableContent: Bool {
            blocks.contains { block in
                switch block {
                case .text(let value), .reasoning(let value):
                    return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                case .image:
                    return true
                case .toolCall:
                    return false
                }
            }
        }

        public var plainText: String {
            blocks.compactMap { block in
                if case .text(let value) = block { return value }
                return nil
            }.joined()
        }

        /// 气泡里真正要画的内容块。
        ///
        /// `.toolCall` 块**不在这里**：同 callId 的工具调用由时间线上单独的
        /// `tool-<callId>` 行承载（`tool/call` + `tool/result` 合并成一条），
        /// 两处都画就会重复。块本身保留在 `blocks` 里，便于诊断与断言。
        public var renderableBlocks: [AssistantBlock] {
            blocks.filter { block in
                if case .toolCall = block { return false }
                return true
            }
        }

        public var toolCallIds: [String] {
            blocks.compactMap { block in
                if case .toolCall(let callId, _) = block { return callId }
                return nil
            }
        }
    }

    public enum AssistantBlock: Sendable, Hashable, Codable {
        case text(String)
        case reasoning(String)
        case image(ImageRef)
        /// 助手侧声明的工具调用（会被同 callId 的 `tool/call` 事件接管）。
        case toolCall(callId: String, name: String)

        public var plainText: String {
            switch self {
            case .text(let value), .reasoning(let value): return value
            case .image: return "[图片]"
            case .toolCall(_, let name): return name
            }
        }
    }

    public struct ToolCall: Sendable, Hashable, Codable {
        public var callId: String
        public var name: String
        public var arguments: String
        public var status: Status
        public var output: String
        public var isError: Bool
        public var startedAt: Date
        public var endedAt: Date?
        /// 元数据（tool/result 的 data 里除 message 之外的东西，原样保留）。
        public var rawResult: JSONValue?

        public init(
            callId: String,
            name: String,
            arguments: String,
            status: Status = .running,
            output: String = "",
            isError: Bool = false,
            startedAt: Date = Date(),
            endedAt: Date? = nil,
            rawResult: JSONValue? = nil
        ) {
            self.callId = callId
            self.name = name
            self.arguments = arguments
            self.status = status
            self.output = output
            self.isError = isError
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.rawResult = rawResult
        }

        public enum Status: Sendable, Hashable, Codable {
            case running
            case success
            case failed
            case cancelled

            public var symbolName: String {
                switch self {
                case .running: return "circle.dotted"
                case .success: return "checkmark.circle.fill"
                case .failed: return "xmark.octagon.fill"
                case .cancelled: return "slash.circle.fill"
                }
            }
        }

        public var duration: TimeInterval? {
            guard let endedAt else { return nil }
            return endedAt.timeIntervalSince(startedAt)
        }
    }

    public struct TodoList: Sendable, Hashable, Codable {
        public var items: [TodoEntry]

        public init(items: [TodoEntry]) { self.items = items }
    }

    public struct TodoEntry: Sendable, Hashable, Identifiable, Codable {
        public var id: String { text + String(describing: status) }
        public var text: String
        public var status: Status

        public init(text: String, status: Status = .pending) {
            self.text = text
            self.status = status
        }

        public enum Status: Sendable, Hashable, Codable {
            case pending
            case inProgress
            case completed

            public init(raw: String?) {
                switch raw {
                case "in_progress", "in-progress", "inProgress": self = .inProgress
                case "completed", "complete", "done": self = .completed
                default: self = .pending
                }
            }
        }
    }

    public struct Approval: Sendable, Hashable, Codable {
        /// 审批自身的 id（`approval/asked` 的 `data.id`，一个 UUID）。
        public var approvalId: String
        /// 被审批的**工具调用** id（`data.callId`）。
        ///
        /// 两个 id 不是一回事：`approval/asked` 同时给了 `id` 与 `callId`。
        /// 当初把 `id` 当成 callId 用过，后果是①拿不到要被审批的工具参数、
        /// ②跟 waterfall 里的 `callId` 对不上，卡片会误判成"谁也答不了"。
        public var callId: String?
        public var toolName: String
        public var reason: String
        /// 宿主给的结构化选项（`options`），认不出就退回"批准一次 / 拒绝"。
        public var options: [Option]
        public var decision: Decision?
        public var decidedAt: Date?

        public init(
            approvalId: String,
            callId: String? = nil,
            toolName: String,
            reason: String,
            options: [Option] = [],
            decision: Decision? = nil,
            decidedAt: Date? = nil
        ) {
            self.approvalId = approvalId
            self.callId = callId
            self.toolName = toolName
            self.reason = reason
            self.options = options
            self.decision = decision
            self.decidedAt = decidedAt
        }

        public struct Option: Sendable, Hashable, Identifiable, Codable {
            public var id: String { kind }
            public var kind: String
            public var label: String
            public var isPrimary: Bool
        }

        public enum Decision: Sendable, Hashable, Codable {
            case approvedOnce
            case approvedAlways
            case denied
            case cancelled
            case other(String)

            public init(raw: String?) {
                switch raw {
                case "allowed-once", "allow", "approve", "approved", "once", "allow-once": self = .approvedOnce
                case "allow-always", "always": self = .approvedAlways
                case "deny", "denied", "reject", "rejected": self = .denied
                case "cancel", "cancelled": self = .cancelled
                case let other?: self = .other(other)
                case nil: self = .cancelled
                }
            }
        }

        public var isPending: Bool { decision == nil }
    }

    public struct Compaction: Sendable, Hashable, Codable {
        public var phase: Phase
        public var summary: String

        public init(phase: Phase, summary: String = "") {
            self.phase = phase
            self.summary = summary
        }

        public enum Phase: Sendable, Hashable, Codable { case start, summary, end, prune }
    }

    public struct Goal: Sendable, Hashable, Codable {
        public var objective: String?
        public var status: String?

        public init(objective: String? = nil, status: String? = nil) {
            self.objective = objective
            self.status = status
        }
    }

    public struct PlanMode: Sendable, Hashable, Codable {
        public var isActive: Bool
        public var isPending: Bool

        public init(isActive: Bool, isPending: Bool) {
            self.isActive = isActive
            self.isPending = isPending
        }
    }

    public struct Deliverable: Sendable, Hashable, Identifiable, Codable {
        public var id: String { path ?? title }
        public var title: String
        public var path: String?
        public var description: String?

        public init(title: String, path: String? = nil, description: String? = nil) {
            self.title = title
            self.path = path
            self.description = description
        }
    }

    /// 说明行。`tone` 决定符号与颜色语义（不靠色相单独传达）。
    public struct Note: Sendable, Hashable, Codable {
        public var text: String
        public var symbolName: String
        public var tone: Tone
        public var sourceEventType: String
        /// 默认是否展开（模型切换之类默认折叠）。
        public var isProminent: Bool

        public init(text: String, symbolName: String, tone: Tone, sourceEventType: String, isProminent: Bool = false) {
            self.text = text
            self.symbolName = symbolName
            self.tone = tone
            self.sourceEventType = sourceEventType
            self.isProminent = isProminent
        }

        public enum Tone: Sendable, Hashable, Codable { case neutral, info, success, warning, failure }
    }

    public struct ImageRef: Sendable, Hashable, Identifiable, Codable {
        public var id: String { attachmentId }
        public var attachmentId: String
        public var name: String?
        public var mediaType: String
        public var width: Int?
        public var height: Int?
        /// 已在日志里出现过（用于 `session/attachment` 鉴权）。
        public var sessionId: String?

        public init(attachmentId: String, name: String? = nil, mediaType: String = "image/png", width: Int? = nil, height: Int? = nil, sessionId: String? = nil) {
            self.attachmentId = attachmentId
            self.name = name
            self.mediaType = mediaType
            self.width = width
            self.height = height
            self.sessionId = sessionId
        }
    }

    public struct FileRef: Sendable, Hashable, Identifiable, Codable {
        public var id: String { attachmentId }
        public var attachmentId: String
        public var name: String?
        public var byteSize: Int?

        public init(attachmentId: String, name: String? = nil, byteSize: Int? = nil) {
            self.attachmentId = attachmentId
            self.name = name
            self.byteSize = byteSize
        }
    }

    /// `turn/end` 的 reason。
    public enum TurnEndReason: Sendable, Hashable, Codable {
        case completed
        case interrupted
        case failed(String)
        case other(String)

        public init(json: JSONValue?) {
            let kind = json?.string("kind") ?? "unknown"
            switch kind {
            case "completed": self = .completed
            case "interrupted", "cancelled", "canceled": self = .interrupted
            case "failed", "error": self = .failed(json?.string("message") ?? "")
            default: self = .other(kind)
            }
        }

        public var isFailure: Bool { if case .failed = self { return true }; return false }
    }
}

// MARK: - 增量

/// 一次 `apply` 产生的变化。UI 按它做**增量**更新，而不是整体重建。
public struct TimelineDelta: Sendable {
    public var inserted: [TimelineItem] = []
    public var updated: [TimelineItem] = []
    public var removedIds: [String] = []
    public var shadowedIds: [String] = []
    /// 这些变化是否要求 UI 贴底滚一次。
    public var shouldFollowScroll: Bool = false

    public var isEmpty: Bool {
        inserted.isEmpty && updated.isEmpty && removedIds.isEmpty && shadowedIds.isEmpty
    }

    public static let none = TimelineDelta()

    public mutating func merge(_ other: TimelineDelta) {
        inserted.append(contentsOf: other.inserted)
        updated.append(contentsOf: other.updated)
        removedIds.append(contentsOf: other.removedIds)
        shadowedIds.append(contentsOf: other.shadowedIds)
        shouldFollowScroll = shouldFollowScroll || other.shouldFollowScroll
    }
}
