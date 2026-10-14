import Foundation

/// `surfaceOp` —— 会话日志里的"表面"操作。
///
/// 读自 `dsh-session/lib/types/surface.js`：
/// `surfaceOp` 要么是**字符串** `"append"`，要么是对象 `{op:'replace', startSeq, endSeq}`。
/// 前者表示事件追加到表面尾部；后者表示该事件**取代**区间 `[startSeq, endSeq]`
/// 内的表面节点（压缩、tool/result 重写、系统提示重写都会这么做）。
///
/// 本项目对"人看的对话"的取舍（写进 docs/DESIGN.md §4.4）：
/// **append 起源的事件才是用户的对话记录**；replace 事件是模型可见层的副本，
/// 拿它渲染会让用户已经看过的内容凭空消失。所以：
///   · 渲染 = 全部 append 起源事件 + 全部非表面事件；
///   · replace 事件只用来更新表面索引，并让被它遮住的事件标记为 `isShadowed`
///     （UI 收进"已被压缩取代"的折叠区，保留可回溯性）。
public enum SurfaceOp: Sendable, Hashable {
    case append
    case replace(startSeq: Int, endSeq: Int)

    public static func decode(_ value: JSONValue?) -> SurfaceOp? {
        guard let value else { return nil }
        if value.stringValue == "append" { return .append }
        guard let object = value.objectValue,
              object["op"]?.stringValue == "replace",
              let start = object["startSeq"]?.intValue,
              let end = object["endSeq"]?.intValue
        else { return nil }
        return .replace(startSeq: start, endSeq: end)
    }

    public var isAppend: Bool { if case .append = self { return true }; return false }
}

/// 一条会话事件（持久日志）。
///
/// **信封严格、负载宽松**：`type/seq/time/data/surfaceOp/sourceEventSeqs/ignorable`
/// 之外出现未知字段就整条拒绝——因为宿主明确写了"unexpected field"会抛；
/// 但 `data` 内部是 owner-defined JSON，我们不解析、原样带着。
public struct SessionEvent: Sendable, Identifiable, Hashable {
    public let type: String
    public let seq: Double
    public let time: Date
    public let data: JSONValue
    public let surfaceOp: SurfaceOp?
    public let sourceEventSeqs: [Int]?
    public let ignorable: Bool

    public var id: Double { seq }

    /// 持久事件的 seq 一定是非负安全整数。真实帧里用它做字典键更省。
    public var durableSeq: Int? {
        guard seq >= 0, seq.rounded() == seq, seq < 9_007_199_254_740_992 else { return nil }
        return Int(seq)
    }

    public init(
        type: String,
        seq: Double,
        time: Date,
        data: JSONValue,
        surfaceOp: SurfaceOp? = nil,
        sourceEventSeqs: [Int]? = nil,
        ignorable: Bool = false
    ) {
        self.type = type
        self.seq = seq
        self.time = time
        self.data = data
        self.surfaceOp = surfaceOp
        self.sourceEventSeqs = sourceEventSeqs
        self.ignorable = ignorable
    }

    /// 从 wire JSON 解码。失败时抛 `DSHTransportError.malformedResponse`。
    public static func decode(_ value: JSONValue) throws -> SessionEvent {
        guard let type = value.string("type") else {
            throw DSHTransportError.malformedResponse(String(localized: "会话事件缺少 type"))
        }
        guard let rawSeq = value["seq"]?.doubleValue else {
            throw DSHTransportError.malformedResponse(String(localized: "会话事件 \(type) 缺少 seq"))
        }
        guard let rawTime = value["time"]?.doubleValue else {
            throw DSHTransportError.malformedResponse(String(localized: "会话事件 \(type) 缺少 time"))
        }
        return SessionEvent(
            type: type,
            seq: rawSeq,
            time: Date(timeIntervalSince1970: rawTime / 1000),
            data: value["data"] ?? .null,
            surfaceOp: SurfaceOp.decode(value["surfaceOp"]),
            sourceEventSeqs: value["sourceEventSeqs"]?.arrayValue?.compactMap(\.intValue),
            ignorable: value.bool("ignorable") ?? false
        )
    }
}

/// `session/follow` 快照。
public struct SessionSnapshot: Sendable {
    public let header: SessionHeader
    /// 快照覆盖到哪个 seq；`session/page` 的 `throughSeq` 要的就是它。
    public let cursor: Int
    public let events: [SessionEvent]
    public let hasMore: Bool
    public let projections: JSONValue
    public let assistantStream: JSONValue

    public static func decode(_ value: JSONValue) throws -> SessionSnapshot {
        guard value.string("type") == "snapshot" else {
            throw DSHTransportError.malformedResponse(String(localized: "首个 follow 帧不是 snapshot"))
        }
        let records = value.array("records") ?? []
        var events: [SessionEvent] = []
        events.reserveCapacity(records.count)
        for record in records {
            // 目前只有 'event' 一种记录；未来若有别的种类，跳过而不是整帧失败。
            guard record.string("type") == "event", let payload = record["event"] else { continue }
            events.append(try SessionEvent.decode(payload))
        }
        return SessionSnapshot(
            header: SessionHeader(json: value["header"] ?? .object([:])),
            cursor: value.int("cursor") ?? -1,
            events: events,
            hasMore: value.bool("hasMore") ?? false,
            projections: value["projections"] ?? .object([:]),
            assistantStream: value["assistantStream"] ?? .object([:])
        )
    }
}

/// 会话头（`session-<uuid>`、cwd、agentPreset…）。
public struct SessionHeader: Sendable, Hashable, Codable {
    public let id: String
    public let createdAt: Date
    public let cwd: String?
    public let isSeeded: Bool
    public let delegationDepth: Int
    public let agentPreset: String?

    public init(json: JSONValue) {
        self.id = json.string("id") ?? ""
        self.createdAt = Date(timeIntervalSince1970: (json.double("createdAt") ?? 0) / 1000)
        self.cwd = json.string("cwd")
        self.isSeeded = json.bool("isSeeded") ?? false
        self.delegationDepth = json.int("delegationDepth") ?? 0
        self.agentPreset = json.string("agentPreset")
    }
}

/// `session/follow` 的一帧：快照、增量事件，或客户端的实时流帧。
public enum SessionFollowFrame: Sendable {
    case snapshot(SessionSnapshot)
    case event(SessionEvent)
    case assistantStream(AssistantStreamFrame)
}

/// `assistant-stream` 实时帧。
///
/// 读自 `dsh-api-session-controller/lib/types/client/sessions/assistant-stream.js`：
/// 三种帧 `start` / `chunk` / `end`，都带 `attemptId`。
/// 渲染层只消费 `chunk`（按 `index` 单调，`index` 跳号即要求重基准）。
public enum AssistantStreamFrame: Sendable {
    case start(attemptId: String, startedAfterSeq: Int, turn: Int, step: Int)
    case chunk(AttemptChunk)
    case end(attemptId: String, index: Int, outcome: AssistantStreamOutcome)
    /// 认不出的帧（宿主加了新种类）；保留原始值便于诊断页展示。
    case unknown(JSONValue)

    public var attemptId: String? {
        switch self {
        case .start(let id, _, _, _): return id
        case .chunk(let chunk): return chunk.attemptId
        case .end(let id, _, _): return id
        case .unknown(let value): return value.string("attemptId")
        }
    }

    public static func decode(_ value: JSONValue) -> AssistantStreamFrame {
        switch value.string("type") {
        case "start":
            return .start(
                attemptId: value.string("attemptId") ?? "",
                startedAfterSeq: value.int("startedAfterSeq") ?? -1,
                turn: value.int("turn") ?? 0,
                step: value.int("step") ?? 0
            )
        case "chunk":
            return .chunk(AttemptChunk(json: value))
        case "end":
            let outcome = value["outcome"] ?? .object([:])
            return .end(
                attemptId: value.string("attemptId") ?? "",
                index: value.int("index") ?? -1,
                outcome: AssistantStreamOutcome(json: outcome)
            )
        default:
            return .unknown(value)
        }
    }
}

/// 一个实时块。
public struct AttemptChunk: Sendable, Hashable {
    public let attemptId: String
    public let index: Int
    public let time: Date
    public let chunk: ModelChunk

    public init(json: JSONValue) {
        self.attemptId = json.string("attemptId") ?? ""
        self.index = json.int("index") ?? -1
        self.time = Date(timeIntervalSince1970: (json.double("time") ?? 0) / 1000)
        self.chunk = ModelChunk(json: json["chunk"] ?? .object([:]))
    }
}

/// 模型流块。种类读自 `dsh-llm/lib/types/assistant-stream.js` 的 `push`：
/// `text-delta` / `reasoning-delta` / `tool-call-delta` / `block-start` / `block-end` /
/// `usage` / `finish`。
public enum ModelChunk: Sendable, Hashable {
    case textDelta(index: Int, text: String)
    case reasoningDelta(index: Int, text: String)
    case toolCallDelta(index: Int, id: String, name: String?, argumentsDelta: String)
    case blockStart(index: Int, blockType: String)
    case blockEnd(index: Int)
    case usage(JSONValue)
    case finish(JSONValue)
    case other(type: String, json: JSONValue)

    public init(json: JSONValue) {
        let type = json.string("type") ?? "unknown"
        let index = json.int("index") ?? 0
        switch type {
        case "text-delta":
            self = .textDelta(index: index, text: json.string("text") ?? "")
        case "reasoning-delta":
            self = .reasoningDelta(index: index, text: json.string("text") ?? "")
        case "tool-call-delta":
            self = .toolCallDelta(
                index: index,
                id: json.string("id") ?? "",
                name: json.string("name"),
                argumentsDelta: json.string("argumentsDelta") ?? ""
            )
        case "block-start":
            self = .blockStart(index: index, blockType: json.string("blockType") ?? "text")
        case "block-end":
            self = .blockEnd(index: index)
        case "usage":
            self = .usage(json)
        case "finish":
            self = .finish(json)
        default:
            self = .other(type: type, json: json)
        }
    }
}

/// 一次尝试的收尾。
public struct AssistantStreamOutcome: Sendable, Hashable {
    public let kind: String
    public let seq: Int?
    public let eventType: String?

    public init(json: JSONValue) {
        self.kind = json.string("kind") ?? "unknown"
        self.seq = json.int("seq")
        self.eventType = json.string("eventType")
    }
}

// MARK: - 负载取值

extension SessionEvent {
    /// 有些渲染路径只想知道 turn；给一个容错取法。
    public var turnHint: Int? { int("turn") }

    /// 点分路径取值。`"data.turn"` 与 `"turn"` 等价 —— 负载永远是 `data` 里的东西，
    /// 写全 `data.` 只是为了让调用点读起来和原始事件对齐。
    public func resolve(_ path: String) -> JSONValue? {
        var keys = path.split(separator: ".").map(String.init)
        if keys.first == "data" { keys.removeFirst() }
        var current: JSONValue? = data
        for key in keys {
            current = current?[key]
            if current == nil { return nil }
        }
        return current
    }

    public func int(_ path: String) -> Int? { resolve(path)?.intValue }
    public func string(_ path: String) -> String? { resolve(path)?.stringValue }
    public func bool(_ path: String) -> Bool? { resolve(path)?.boolValue }
    public func array(_ path: String) -> [JSONValue]? { resolve(path)?.arrayValue }
}
