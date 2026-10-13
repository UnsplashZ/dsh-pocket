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
    /// `origin`。官方 UI 用它把子代理会话从主列表里排除
    /// （`dsh-client-ui-workspace/lib/client.js`: `if (session.origin === "subagent") return false`）。
    public let origin: String?
    /// 投影覆盖到哪个 seq（`projections.asOfSeq`）。
    public let asOfSeq: Int
    public let projections: SessionProjections

    public var id: String { sessionId }

    public var title: String {
        if let title = projections.title, !title.isEmpty { return title }
        // **不要退回会话 id。**
        //
        // 新建的会话还没有标题（宿主是拿第一句话去生成标题的，要等一拍），
        // 之前这里显示 `session-4eaabdbf-af1e` 这样的原始 id ——
        // 用户："新对话默认的标题叫'新对话'，不要直接展示原始的 sessionid"。
        return String(localized: "新对话")
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

    /// 会话的类别。
    ///
    /// 判据全部来自线上字段，不猜：
    ///   · `origin == "subagent"`（或带 `parentSessionId`）→ 子代理会话。官方 UI 也不在主列表显示它；
    ///   · `sessionId` 以 `im:` 开头 → IM 桥接出来的频道会话（形如
    ///     `im:feishu_<id>:dm:<ts>:<peer>` / `im:weixin_<id>:dm:<ts>:<peer>`），
    ///     它们是"和某个外部聊天对象的一条线"，和你在电脑上开的会话不是一类东西；
    ///   · 其余 → 普通会话。
    public var category: SessionCategory {
        if origin == "subagent" || parentSessionId != nil { return .subagent }
        if let channel = Self.channelName(from: sessionId) { return .channel(channel) }
        return .session
    }

    /// 从 `im:<channel>_<id>:<kind>:<ts>:<peer>` 里取出渠道名（feishu / weixin / …）。
    public static func channelName(from sessionId: String) -> String? {
        guard sessionId.hasPrefix("im:") else { return nil }
        let rest = sessionId.dropFirst(3)
        guard let firstSegment = rest.split(separator: ":").first else { return "im" }
        // `feishu_ab12cd34ef56` → `feishu`
        let channel = firstSegment.split(separator: "_").first.map(String.init) ?? String(firstSegment)
        return channel.isEmpty ? "im" : channel
    }

    /// 造一个"刚建出来、列表还没刷到"的占位。
    ///
    /// 用途：新建会话之后用户期望**立刻**进去。宿主的 `session/list` 有传播延迟，
    /// 干等或者静默失败都不好 —— 不如用一个标题待定的占位先把会话页打开，
    /// 等真正的投影到了自然会替换掉标题。
    public static func placeholder(sessionId: String, cwd: String?) -> SessionSummary {
        SessionSummary(
            sessionId: sessionId,
            updatedAt: Date(),
            cwd: cwd,
            isRunning: false,
            agentAvailable: true,
            isBlank: true,
            parentSessionId: nil,
            origin: nil,
            asOfSeq: -1,
            projections: .empty
        )
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
            origin: value.string("origin"),
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
    public let sessionStats: SessionStats
    public let contextPressure: ContextPressure?
    public let turnOutline: [TurnOutlineEntry]
    public let agentPreset: String?
    /// **子代理会话**对自己的一句描述（`{mode, label, seq}`）。
    ///
    /// 只有子代理会话有；父会话的 `subagentCatalog` 才是"我派出了哪些子代理"。
    public let subagent: SubagentInfo?
    /// 父会话派出的子代理清单（`[{mode, label, id, createdAt}]`）。
    public let subagentCatalog: [SubagentInfo]
    public let todos: [TimelineItem.TodoEntry]
    public let modelSelection: ModelSelection?
    public let permissions: PermissionState?
    public let plan: PlanState?
    public let userQuestions: UserQuestionsState
    /// 排队中的消息。见 `InboxState` 的说明 —— 队列**不在会话日志里**。
    public let inbox: InboxState
    public let subagents: [SubagentEntry]
    public let container: JSONValue

    public init(json: JSONValue) {
        let values = json["values"] ?? .object([:])
        self.kind = json.string("kind") ?? "sequenced"
        self.asOfSeq = json.int("asOfSeq") ?? -1
        self.title = values.string("title")
        self.goal = values["goal"]
        self.tokenUsage = TokenUsage(json: values["tokenUsage"] ?? .object([:]))
        self.sessionStats = SessionStats(json: values["sessionStats"] ?? .object([:]))
        self.contextPressure = values["contextPressure"].map(ContextPressure.init(json:))
        self.turnOutline = (values.array("turnOutline") ?? []).map(TurnOutlineEntry.init(json:))
        self.agentPreset = values.string("agentPreset")
        self.subagent = values["subagent"].map(SubagentInfo.init(json:))
        self.subagentCatalog = (values.array("subagentCatalog") ?? []).map(SubagentInfo.init(json:))
        self.todos = (values.array("todos") ?? []).map {
            TimelineItem.TodoEntry(
                text: $0.string("content") ?? $0.string("text") ?? "",
                status: .init(raw: $0.string("status"))
            )
        }
        // `modelSelection` 是**嵌套**的 `{lastUsed: {...}, next: {...}}`，
        // 不是扁平的 `{provider, model}`。当成扁平读会得到空的 provider/model ——
        // 表现是会话页的模型标签空白，以及 selectModel 拿空值去选（`session/model-unavailable`）。
        self.modelSelection = values["modelSelection"].flatMap { raw in
            let chosen = raw["next"] ?? raw["lastUsed"] ?? raw
            let selection = ModelSelection(json: chosen)
            return selection.provider.isEmpty && selection.model.isEmpty ? nil : selection
        }
        self.permissions = values["permissions"].map(PermissionState.init(json:))
        self.plan = values["plan"].map(PlanState.init(json:))
        self.userQuestions = UserQuestionsState(json: values["userQuestions"] ?? .object([:]))
        self.inbox = InboxState(json: values["inbox"] ?? .object([:]))
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

    /// 缓存命中率。输入框下面那个 `缓存 99%` 就是它。
    ///
    /// 分母是**提示词总量**（未命中 + 命中），不是 total —— `total` 还把输出算进去了，
    /// 那样算出来的比例会被输出长度稀释，跟桌面端对不上。
    public var cacheHitRate: Double? {
        let promptTokens = uncachedInputTokens + cacheReadTokens
        guard promptTokens > 0 else { return nil }
        return Double(cacheReadTokens) / Double(promptTokens)
    }
}

/// **单条**助手消息的用量（`assistant/message` 的 `data.usage`）。
///
/// 与 `TokenUsage`（会话级投影）**字段名不一样**，别混：
/// 那边是 `uncachedInputTokens`，这边是 `inputTokens`。
public struct MessageUsage: Sendable, Hashable, Codable {
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var totalTokens: Int = 0
    public var cacheReadTokens: Int = 0
    public var reasoningTokens: Int = 0

    public init(json: JSONValue) {
        inputTokens = json.int("inputTokens") ?? 0
        outputTokens = json.int("outputTokens") ?? 0
        totalTokens = json.int("totalTokens") ?? 0
        cacheReadTokens = json.int("cacheReadTokens") ?? 0
        reasoningTokens = json.int("reasoningTokens") ?? 0
    }

    /// 缓存命中率。桌面端输入框下面那个 `Cache 99%` 就是它。
    public var cacheHitRate: Double? {
        let prompt = inputTokens + cacheReadTokens
        guard prompt > 0 else { return nil }
        return Double(cacheReadTokens) / Double(prompt)
    }
}

/// 会话累计统计（`projections.sessionStats`）。
///
/// 实测形状：`{turns, steps, llmMs, toolMs, ttftMs, ttftSteps, decodeMs, decodeTokens}`。
public struct SessionStats: Sendable, Hashable {
    public var turns: Int = 0
    public var steps: Int = 0
    public var llmMs: Double = 0
    public var toolMs: Double = 0
    /// **累计**首字延迟与步数 —— 要相除才是平均 TTFT。
    public var ttftMs: Double = 0
    public var ttftSteps: Int = 0
    public var decodeMs: Double = 0
    public var decodeTokens: Int = 0

    public init(json: JSONValue) {
        turns = json.int("turns") ?? 0
        steps = json.int("steps") ?? 0
        llmMs = json.double("llmMs") ?? 0
        toolMs = json.double("toolMs") ?? 0
        ttftMs = json.double("ttftMs") ?? 0
        ttftSteps = json.int("ttftSteps") ?? 0
        decodeMs = json.double("decodeMs") ?? 0
        decodeTokens = json.int("decodeTokens") ?? 0
    }

    public var isEmpty: Bool { turns == 0 && steps == 0 }

    /// 平均首字延迟。
    public var averageTimeToFirstToken: TimeInterval? {
        guard ttftSteps > 0 else { return nil }
        return (ttftMs / Double(ttftSteps)) / 1000
    }

    /// 解码速度（tok/s）。
    public var tokensPerSecond: Double? {
        guard decodeMs > 0 else { return nil }
        return Double(decodeTokens) / (decodeMs / 1000)
    }
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

    public init(provider: String, model: String, reasoningEffort: String? = nil) {
        self.provider = provider
        self.model = model
        self.reasoningEffort = reasoningEffort
    }

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

/// 一条子代理信息。
///
/// 两个方向共用这个类型：
///   · 父会话的 `subagentCatalog` —— `{mode, label, id, createdAt}`（`id` 是子代理会话 id）；
///   · 子代理会话自己的 `subagent` —— `{mode, label, seq}`（没有 `id`）。
///
/// **这是唯一能把"父会话里的那次工具调用"和"子代理会话"对上的东西**：
/// `tool/result` 里只有子代理的输出文本，没有会话 id；
/// 只能拿工具调用参数里的 `description` 去匹配 `label`。
public struct SubagentInfo: Sendable, Hashable, Identifiable, Codable {
    /// 子代理会话 id。子代理**自己**的那份投影里没有，会是空串。
    public var id: String
    public var mode: String
    public var label: String
    public var createdAt: Date?

    public init(json: JSONValue) {
        self.id = json.string("id") ?? ""
        self.mode = json.string("mode") ?? ""
        self.label = json.string("label") ?? ""
        if let ms = json.double("createdAt") { self.createdAt = Date(timeIntervalSince1970: ms / 1000) }
        else { self.createdAt = nil }
    }

    public var modeLabel: String {
        switch mode {
        case "one-shot": return String(localized: "一次性")
        case "persistent": return String(localized: "常驻")
        case "": return String(localized: "子代理")
        default: return mode
        }
    }
}

extension Array where Element == SubagentInfo {
    /// 找出某次子代理调用对应的**子代理会话 id**。
    ///
    /// 这是唯一可行的关联方式：`tool/result` 里只有子代理的**输出文本**，
    /// 没有会话 id；而父会话的 `subagentCatalog` 里有 `{label, id, createdAt}`，
    /// 工具调用参数里有 `description` —— 两者是同一个字符串。
    ///
    /// 同名时（同一个 label 被派了两次）取 `createdAt` **最接近**那次调用的，
    /// 而不是随手拿第一个 —— 否则点进去可能看到另一个子代理。
    public func subagentSessionId(label: String, at time: Date) -> String? {
        let candidates = filter { $0.label == label && !$0.id.isEmpty }
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 { return candidates[0].id }
        return candidates.min { lhs, rhs in
            abs((lhs.createdAt ?? .distantPast).timeIntervalSince(time))
                < abs((rhs.createdAt ?? .distantPast).timeIntervalSince(time))
        }?.id
    }
}

/// 会话的收件箱 —— **排队中的消息就在这里**。
///
/// 线上形状（实测）：`{"next-turn":[…],"next-step":[]}`。
///
/// 这一点很反直觉但很关键：**排队中的消息不在会话日志里**，没有对应的
/// `user/message` 事件。实测：轮次跑着的时候发一条，日志里一条 `user/message` 都没有，
/// 它只出现在这个投影里（`next-turn`），等下一轮真正开始时才落到日志。
/// 所以想显示"排队中"，唯一的数据来源是它。
public struct InboxState: Sendable, Hashable {
    /// 排给下一轮的消息（`mode: 'queue'`）。
    public var nextTurn: [QueuedMessage]
    /// 插进当前这一步的消息（`mode: 'steer'`）。
    public var nextStep: [QueuedMessage]

    public var isEmpty: Bool { nextTurn.isEmpty && nextStep.isEmpty }
    public var total: Int { nextTurn.count + nextStep.count }

    public init(nextTurn: [QueuedMessage] = [], nextStep: [QueuedMessage] = []) {
        self.nextTurn = nextTurn
        self.nextStep = nextStep
    }

    public init(json: JSONValue) {
        self.nextTurn = (json.array("next-turn") ?? []).map(QueuedMessage.init(json:))
        self.nextStep = (json.array("next-step") ?? []).map(QueuedMessage.init(json:))
    }
}

/// 一条排队中的用户消息。
public struct QueuedMessage: Sendable, Hashable, Identifiable {
    public var id: String
    public var text: String
    /// 客户端发出去时用的 `rpcId` —— 用它跟乐观插入的那条对上，避免同一句话显示两遍。
    public var rpcId: String?
    /// 附件**只留数量**：图片在线上是内联 base64，为了显示"排队中"去解它不值当。
    public var imageCount: Int
    public var fileCount: Int

    public init(id: String, text: String, rpcId: String?, imageCount: Int, fileCount: Int) {
        self.id = id
        self.text = text
        self.rpcId = rpcId
        self.imageCount = imageCount
        self.fileCount = fileCount
    }

    public init(json: JSONValue) {
        self.id = json.string("id") ?? UUID().uuidString
        let content = json.array("content") ?? []
        var text = ""
        var images = 0
        var files = 0
        for part in content {
            switch part.string("type") {
            case "text": text += part.string("text") ?? ""
            case "image": images += 1
            case "file": files += 1
            default: break
            }
        }
        self.text = text
        self.imageCount = images
        self.fileCount = files
        self.rpcId = json.string("source.rpcId")
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


extension Array where Element == QueuedMessage {
    /// 把一条 `agent/inbox/spliced` **增量地**应用到队列上。
    ///
    /// 线上形状是 `{start, removedCount, inserted}` —— 一次 splice：
    /// 从第 `start` 条起删掉 `removedCount` 条，再把 `inserted` 插进去。
    ///
    /// **为什么必须做成"在基准上增量"而不是"换成日志推导的那份"**：
    /// 投影（`projections.inbox`）是权威且全量的，但只在快照时更新；
    /// 日志事件是增量的，但**有界快照会把旧事件切在窗口外** ——
    /// 两者当成二选一的话，就会出现"重进看不到"或"发新消息后只剩一条"。
    /// 这个函数被抽出来就是为了能脱离网络测（之前那三个 bug 全在这儿）。
    public func applyingInboxSplice(
        start: Int,
        removedCount: Int,
        inserted: [JSONValue]
    ) -> [QueuedMessage] {
        var list = self
        if removedCount > 0, start >= 0, start < list.count {
            list.removeSubrange(start..<Swift.min(start + removedCount, list.count))
        }
        for item in inserted {
            list.append(QueuedMessage(json: item))
        }
        return list
    }
}
