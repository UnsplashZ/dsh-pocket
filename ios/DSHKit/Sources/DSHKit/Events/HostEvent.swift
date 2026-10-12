import Foundation

/// `$events` 上的一帧。
///
/// 转发事件是**固定允许清单**（`dsh-api-remotes/lib/types/remote-events.js`）：
/// 27 个事件里只有两个是 `waterfall`（`approval/request`、`user-questions/request`），
/// 其余都是 `emit`（通知，无需应答）。
///
/// **聊天内容不在这里** —— 那是 `session/follow` 的事。三条通道别混
/// （见 docs/PROTOCOL-NOTES.md §4.3）。
public enum HostEvent: Sendable {
    /// 首帧：绑定本次连接的**世代**。重连后旧 `clientId` 失效。
    case ready(clientId: String, host: JSONValue)
    /// 通知，无需应答。
    case emit(event: String, args: JSONValue)
    /// **必须应答**，否则宿主侧的操作会一直阻塞。
    case waterfall(WaterfallRequest)

    public static func decode(_ value: JSONValue) -> HostEvent {
        switch value.string("type") {
        case "ready":
            return .ready(clientId: value.string("clientId") ?? "", host: value["host"] ?? .object([:]))
        case "emit":
            return .emit(event: value.string("event") ?? "?", args: value["args"] ?? .null)
        default:
            return .waterfall(WaterfallRequest(json: value))
        }
    }
}

/// 一条等待应答的 waterfall。
public struct WaterfallRequest: Sendable, Identifiable {
    public let event: String
    public let eventId: String
    public let agentId: String
    public let request: JSONValue

    public var id: String { eventId }
    public var sessionId: String? { agentId.isEmpty ? nil : agentId }

    public init(json: JSONValue) {
        self.event = json.string("event") ?? "?"
        self.eventId = json.string("eventId") ?? ""
        self.agentId = json.string("agentId") ?? ""
        self.request = json["request"] ?? .object([:])
    }

    public var isApproval: Bool { event == "approval/request" }
    public var isUserQuestion: Bool { event == "user-questions/request" }

    // MARK: 审批

    public var approvalToolName: String { request.string("toolName") ?? "工具" }
    public var approvalReason: String { request.string("reason") ?? "" }
    public var approvalCallId: String? { request.string("callId") }

    // MARK: 提问

    public var questions: [Question] {
        (request.array("questions") ?? []).map(Question.init(json:))
    }

    /// 待答问题的 `callId`。
    ///
    /// 线上它在 `request.wait.callId`。但要注意：**网关转发给远端时会把 `wait` 整个剥掉**
    /// （实测确认），所以远端客户端永远拿不到它 —— 远端只能按 `eventId` 回 waterfall。
    /// 这里保留读取是为了本机/未来形态下仍然正确。
    public var questionCallId: String? {
        (request["wait"] ?? .null).string("callId") ?? request.string("callId")
    }

    public struct Question: Sendable, Hashable, Identifiable {
        public var id: String
        public var question: String
        public var detail: String?
        public var header: String?
        public var options: [Option]
        public var isMultiSelect: Bool

        public init(json: JSONValue) {
            id = json.string("id") ?? UUID().uuidString
            question = json.string("question") ?? ""
            detail = json.string("detail")
            header = json.string("header")
            isMultiSelect = json.bool("multiSelect") ?? false
            options = (json.array("options") ?? []).compactMap { entry in
                guard let label = entry.string("label") else { return nil }
                return Option(label: label, description: entry.string("description"))
            }
        }

        public struct Option: Sendable, Hashable, Identifiable {
            public var id: String { label }
            public var label: String
            public var description: String?
        }
    }
}

// MARK: - 应答构造

extension WaterfallRequest {
    /// 审批的一种决定。`allowed-once` 是**唯一**的授予；其余都是拒绝类。
    public enum ApprovalDecision: String, Sendable {
        case allowedOnce = "allowed-once"
        case rejected = "rejected"
        case cancelled = "cancelled"
        case unavailable = "unavailable"

        public var isGrant: Bool { self == .allowedOnce }
    }

    /// 审批应答。
    public static func approvalOutcome(_ decision: ApprovalDecision) -> JSONValue {
        .object([
            "kind": .string("result"),
            "value": .string(decision.rawValue),
        ])
    }

    /// 拒绝/作罢的结论。宿主会把 `error` 还原成一个异常抛给发起方 ——
    /// 用途是"用户明确表示不回答"，让 agent 立刻知道，而不是干等到超时。
    public static func rejectionOutcome(name: String, message: String) -> JSONValue {
        .object([
            "kind": .string("rejected"),
            "error": .object([
                "name": .string(name),
                "message": .string(message),
            ]),
        ])
    }

    /// 提问应答。批里必须**恰好一次**地命名每个问题的 `id`。
    public static func answersOutcome(_ answers: [(id: String, selected: [String], custom: String?)]) -> JSONValue {
        let payload: JSONValue = .object([
            "answers": .array(answers.map { answer in
                var object: [String: JSONValue] = [
                    "id": .string(answer.id),
                    "selected": .array(answer.selected.map { .string($0) }),
                ]
                if let custom = answer.custom, !custom.isEmpty {
                    object["custom"] = .string(custom)
                }
                return .object(object)
            })
        ])
        return .object([
            "kind": .string("result"),
            "value": payload,
        ])
    }

    /// "不是给我答的，交给下一个应答者"。**不要用它来逃避应答** ——
    /// 交不出去宿主会落到默认实现（审批 = unavailable，提问 = 报错）。
    public static let nextOutcome: JSONValue = .object(["kind": .string("next")])

    /// 明确拒绝这次应答（宿主侧会看到 rejected）。
    public static func rejectedOutcome(name: String, message: String, code: String? = nil) -> JSONValue {
        var error: [String: JSONValue] = [
            "name": .string(name),
            "message": .string(message),
        ]
        if let code { error["code"] = .string(code) }
        return .object([
            "kind": .string("rejected"),
            "error": .object(error),
        ])
    }
}
