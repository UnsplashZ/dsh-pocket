import Foundation

/// `session/list` 的一行。
///
/// 设计上刻意**只靠 projections**（不打开任何流）——省电省流（见 DESIGN.md §9）。
public struct SessionSummary: Sendable, Identifiable, Hashable {
    public let sessionId: String
    public let updatedAt: Date
    public let cwd: String?
    public let isRunning: Bool
    public let agentAvailable: Bool
    public let isBlank: Bool
    public let parentSessionId: String?
    /// 投影覆盖到哪个 seq（`projections.asOfSeq`）。
    public let asOfSeq: Int
    public let projections: SessionProjections

    public var id: String { sessionId }

    public var title: String {
        if let title = projections.title, !title.isEmpty { return title }
        return String(sessionId.prefix(18))
    }

    /// 最后一条摘要（列表页副标题）。
    public var subtitle: String {
        if let response = projections.turnOutline.last?.response, !response.isEmpty {
            return response.cleanedForListRow()
        }
        if let prompt = projections.turnOutline.last?.prompt, !prompt.isEmpty {
            return prompt.cleanedForListRow()
        }
        return ""
    }

    public var workspaceName: String {
        guard let cwd, !cwd.isEmpty else { return "其它" }
        return (cwd as NSString).lastPathComponent
    }

    public static func decode(_ value: JSONValue) -> SessionSummary? {
        guard let sessionId = value.string("sessionId") else { return nil }
        return SessionSummary(
            sessionId: sessionId,
            updatedAt: Date(timeIntervalSince1970: (value.double("updatedAt") ?? 0) / 1000),
            cwd: value.string("cwd"),
            isRunning: value.bool("running") ?? false,
            agentAvailable: value.bool("agentAvailable") ?? false,
            isBlank: value.bool("blank") ?? false,
            parentSessionId: value.string("parentSessionId"),
            asOfSeq: value.int("projections.asOfSeq") ?? -1,
            projections: SessionProjections(json: value["projections"] ?? .object([:]))
        )
    }
}

/// 会话投影（`projections.values`）。
///
/// DSH 的投影是「sequenced」的：带 `asOfSeq`，客户端可据此判断自己看到的是不是最新。
public struct SessionProjections: Sendable, Hashable {
    public let kind: String
    public let asOfSeq: Int
    public let title: String?
    public let goal: JSONValue?
    public let tokenUsage: TokenUsage
    public let contextPressure: ContextPressure?
    public let turnOutline: [TurnOutlineEntry]
    public let agentPreset: String?
    public let todos: [TimelineItem.TodoEntry]
    public let modelSelection: ModelSelection?
    public let permissions: PermissionState?
    public let plan: PlanState?
    public let userQuestions: UserQuestionsState
    public let subagents: [SubagentEntry]
    public let container: JSONValue

    public init(json: JSONValue) {
        let values = json["values"] ?? .object([:])
        self.kind = json.string("kind") ?? "sequenced"
        self.asOfSeq = json.int("asOfSeq") ?? -1
        self.title = values.string("title")
        self.goal = values["goal"]
        self.tokenUsage = TokenUsage(json: values["tokenUsage"] ?? .object([:]))
        self.contextPressure = values["contextPressure"].map(ContextPressure.init(json:))
        self.turnOutline = (values.array("turnOutline") ?? []).map(TurnOutlineEntry.init(json:))
        self.agentPreset = values.string("agentPreset")
        self.todos = (values.array("todos") ?? []).map {
            TimelineItem.TodoEntry(
                text: $0.string("content") ?? $0.string("text") ?? "",
                status: .init(raw: $0.string("status"))
            )
        }
        self.modelSelection = values["modelSelection"].map(ModelSelection.init(json:))
        self.permissions = values["permissions"].map(PermissionState.init(json:))
        self.plan = values["plan"].map(PlanState.init(json:))
        self.userQuestions = UserQuestionsState(json: values["userQuestions"] ?? .object([:]))
        self.subagents = (values.array("subagentCatalog") ?? []).map(SubagentEntry.init(json:))
        self.container = values
    }

    public static let empty = SessionProjections(json: .object([:]))

    /// 上下文用了多少（0…1）。用于列表页与诊断页。
    public var contextFraction: Double? {
        guard let pressure = contextPressure, pressure.contextWindow > 0 else { return nil }
        return min(1, Double(pressure.projectedTokens) / Double(pressure.contextWindow))
    }

    public var pendingApprovalCount: Int {
        // 审批在事件流里，投影只给"提问"；审批数量由 follow 的实时状态补。
        userQuestions.active.count
    }
}

public struct TokenUsage: Sendable, Hashable {
    public var uncachedInputTokens: Int = 0
    public var outputTokens: Int = 0
    public var cacheReadTokens: Int = 0
    public var cacheWriteTokens: Int = 0

    public init(json: JSONValue) {
        uncachedInputTokens = json.int("uncachedInputTokens") ?? 0
        outputTokens = json.int("outputTokens") ?? 0
        cacheReadTokens = json.int("cacheReadTokens") ?? 0
        cacheWriteTokens = json.int("cacheWriteTokens") ?? 0
    }

    public var total: Int { uncachedInputTokens + outputTokens + cacheReadTokens + cacheWriteTokens }
}

public struct ContextPressure: Sendable, Hashable {
    public var pressureTokens: Int = 0
    public var projectedTokens: Int = 0
    public var contextWindow: Int = 0

    public init(json: JSONValue) {
        pressureTokens = json.int("pressureTokens") ?? 0
        projectedTokens = json.int("projectedTokens") ?? 0
        contextWindow = json.int("contextWindow") ?? 0
    }
}

public struct TurnOutlineEntry: Sendable, Hashable, Identifiable {
    public var id: Int { seq }
    public var turn: Int
    public var seq: Int
    public var prompt: String
    public var response: String

    public init(json: JSONValue) {
        turn = json.int("turn") ?? 0
        seq = json.int("seq") ?? 0
        prompt = json.string("prompt") ?? ""
        response = json.string("response") ?? ""
    }
}

public struct ModelSelection: Sendable, Hashable {
    public var provider: String
    public var model: String
    public var reasoningEffort: String?

    public init(json: JSONValue) {
        provider = json.string("provider") ?? ""
        model = json.string("model") ?? ""
        reasoningEffort = json.string("reasoningEffort")
    }
}

public struct PermissionState: Sendable, Hashable {
    public var current: String

    public init(json: JSONValue) {
        current = json.string("currentValue") ?? json.string("current") ?? ""
    }
}

public struct PlanState: Sendable, Hashable {
    public var isActive: Bool
    public var isPending: Bool

    public init(json: JSONValue) {
        isActive = json.bool("active") ?? false
        isPending = json.bool("pending") ?? false
    }
}

public struct UserQuestionsState: Sendable, Hashable {
    public var active: [UserQuestion]
    public var settled: [UserQuestion]

    public init(json: JSONValue) {
        active = (json.array("active") ?? []).map(UserQuestion.init(json:))
        settled = (json.array("settled") ?? []).map(UserQuestion.init(json:))
    }
}

public struct UserQuestion: Sendable, Hashable, Identifiable {
    public var id: String
    public var question: String
    public var header: String?
    public var options: [Option]
    public var multiSelect: Bool
    public var answer: String?

    public init(json: JSONValue) {
        id = json.string("id") ?? json.string("questionId") ?? UUID().uuidString
        question = json.string("question") ?? ""
        header = json.string("header")
        multiSelect = json.bool("multiSelect") ?? json.bool("multi_select") ?? false
        options = (json.array("options") ?? []).compactMap { entry in
            let label = entry.string("label") ?? entry.string("value")
            guard let label else { return nil }
            return Option(label: label, description: entry.string("description"), isRecommended: entry.bool("recommended") ?? false)
        }
        answer = json.string("answer")
    }

    public struct Option: Sendable, Hashable, Identifiable {
        public var id: String { label }
        public var label: String
        public var description: String?
        public var isRecommended: Bool
    }
}

public struct SubagentEntry: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var role: String?
    public var phase: String?

    public init(json: JSONValue) {
        id = json.string("sessionId") ?? json.string("id") ?? json.string("name") ?? UUID().uuidString
        name = json.string("name") ?? json.string("title") ?? id
        role = json.string("role")
        phase = json.string("phase")
    }
}

extension String {
    /// 列表行的摘要：压掉换行与 markdown 噪音，只留一句人能扫的。
    func cleanedForListRow(limit: Int = 160) -> String {
        var text = self
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        for token in ["```", "**", "##", "# ", "- [ ]", "- [x]"] {
            text = text.replacingOccurrences(of: token, with: token == "```" ? "" : " ")
        }
        text = text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}
