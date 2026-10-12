import DSHKit
import SwiftUI

/// S4 审批。
///
/// 两条呈现路径：**时间线内卡片**（默认、主路径）与**本地通知**（点通知回到卡片位置）。
/// 规则：**永远不由 App 自动决策**；决策走 DSH 原生 `$events/result`（ADR-0007）；
/// 提供「稍后」把卡片收起到会话顶部的待处理条。
struct ApprovalCard: View {
    let approval: TimelineItem.Approval
    let item: TimelineItem
    /// 这次要执行的东西。工参不在审批请求里，但**时间线里有** ——
    /// 按 `callId` 找到那条 `tool/call` 就能拿出来。
    /// 由调用方传进来，因为只有它手里有完整时间线。
    var pendingArguments: String?

    @Environment(AppModel.self) private var model
    @State private var isWorking = false
    @State private var feedback = 0
    @State private var showFullArguments = false

    /// **权威的**待批来源是挂着的 waterfall，不是时间线。
    ///
    /// 时间线里的 `approval/asked` 可能已经过期（连接中断过、宿主重放过），
    /// 也可能还没被 `approval/decided` 追上。按钮能不能用只看这条。
    /// 关联靠 **`callId`**：waterfall 带的是 `callId`，而 `approval/asked` 里的 `id`
    /// 是审批自身的 UUID，两者不是一回事。按 `id` 找永远找不到。
    private var request: WaterfallRequest? {
        if let callId = approval.callId, !callId.isEmpty {
            return model.pendingApprovals.first { $0.approvalCallId == callId }
        }
        return model.pendingApprovals.first { $0.approvalCallId == approval.approvalId }
    }

    /// 时间线说还欠着，但 waterfall 已经不在了 —— 这条再也答不了。
    private var isOrphaned: Bool {
        approval.isPending && request == nil
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Token.Spacing.tight) {
                HStack(spacing: Token.Spacing.tight) {
                    Image(systemName: "exclamationmark.bubble.fill")
                        .foregroundStyle(approval.isPending ? Color.orange : Color.secondary)
                    Text("需要你决定")
                        .font(.headline)
                    Spacer()
                    if let decision = approval.decision {
                        StatusBadge(decision.localizedLabel, symbol: decisionSymbol(decision), tone: decisionTone(decision))
                    }
                }

                if let arguments = pendingArguments, !arguments.isEmpty, request != nil {
                    ToolArgumentsPreview(
                        toolName: approval.toolName,
                        arguments: arguments,
                        isExpanded: $showFullArguments
                    )
                } else {
                    Label(approval.toolName, systemImage: "wrench.and.screwdriver")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // 有活着的 waterfall 就用它的理由：那份是**给人看的**
                // （`displayReason`，已按 locale 选好），比时间线里的机器版更像人话。
                let reason = request?.approvalReason.isEmpty == false
                    ? request!.approvalReason
                    : approval.reason
                if !reason.isEmpty {
                    Text(reason)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if request != nil {
                    HStack(spacing: Token.Spacing.tight) {
                        Button {
                            decide(.rejected)
                        } label: {
                            Text("拒绝").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)

                        Button {
                            decide(.allowedOnce)
                        } label: {
                            Text("批准一次").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .disabled(isWorking)

                    Button("稍后处理") { model.deferApproval() }
                        .font(.footnote)
                        .disabled(isWorking)
                } else if isOrphaned {
                    // 不摆一对按不动的按钮 —— 那是骗人。
                    Label("这条已经不能在这里回答了（连接中断过，电脑会按默认方式继续）", systemImage: "wifi.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let decidedAt = approval.decidedAt {
                    Text(Format.time(decidedAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .sensoryFeedback(.warning, trigger: feedback)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(String(localized: "审批请求：\(approval.toolName)。\(approval.reason)")))
    }

    private func decide(_ decision: WaterfallRequest.ApprovalDecision) {
        guard let request else { return }
        isWorking = true
        feedback += 1
        Task {
            await model.decide(approval: request, decision: decision)
            isWorking = false
        }
    }

    private func decisionSymbol(_ decision: TimelineItem.Approval.Decision) -> String {
        switch decision {
        case .approvedOnce, .approvedAlways: return "checkmark.circle.fill"
        case .denied: return "xmark.octagon.fill"
        case .cancelled: return "slash.circle.fill"
        case .other: return "questionmark.circle"
        }
    }

    private func decisionTone(_ decision: TimelineItem.Approval.Decision) -> StatusTone {
        switch decision {
        case .approvedOnce, .approvedAlways: return .success
        case .denied: return .failure
        default: return .neutral
        }
    }
}

/// 这次要执行什么。
///
/// 审批的意义全在"看清楚再做决定"上。参数经常很长（一整条 shell 命令、
/// 一整份文件内容），所以默认折到 6 行、可以展开 —— 既不淹没卡片，
/// 也不让用户闭着眼睛点批准。
struct ToolArgumentsPreview: View {
    let toolName: String
    let arguments: String
    @Binding var isExpanded: Bool

    /// 折叠时只留 4 行：审批卡片下面紧跟着"批准/拒绝"，
    /// 让一堵 JSON 墙把按钮顶到屏幕外是本末倒置。要看全的可以展开。
    private static let collapsedLines = 4

    private var isLong: Bool { arguments.count > 160 || arguments.contains("\n") }

    var body: some View {
        VStack(alignment: .leading, spacing: Token.Spacing.hairline) {
            HStack {
                Label(toolName, systemImage: "wrench.and.screwdriver")
                    .font(.caption.weight(.semibold))
                Spacer()
                if isLong {
                    Button(isExpanded ? "收起" : "展开全部") {
                        withAnimation(.snappy) { isExpanded.toggle() }
                    }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
            }
            Text(verbatim: arguments)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(isExpanded ? nil : Self.collapsedLines)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Token.Spacing.tight)
                .background(
                    RoundedRectangle(cornerRadius: Token.Radius.chip, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(String(localized: "将要执行：\(toolName)")))
    }
}

/// 把"等待审批"提升为模态（用户偏好路径）。点通知回到前台时用它。
struct ApprovalSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// 这一条属于哪个会话。
    @ViewBuilder
    private func sessionHeader(for sessionId: String) -> some View {
        if let title = model.sessionTitle(for: sessionId) {
            Label(title, systemImage: "bubble.left.and.bubble.right")
                .lineLimit(1)
        } else {
            Text("别的会话")
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if model.pendingApprovals.isEmpty, model.pendingQuestions.isEmpty {
                    ContentUnavailableView(
                        "没有待处理的事",
                        systemImage: "checkmark.circle",
                        description: Text("电脑上有操作要你批准时会出现在这里。")
                    )
                }

                ForEach(model.pendingApprovals, id: \.eventId) { request in
                    Section {
                        VStack(alignment: .leading, spacing: Token.Spacing.tight) {
                            Text(request.approvalReason.isEmpty
                                 ? String(localized: "电脑上有一个操作在等你批准。")
                                 : request.approvalReason)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                            Label(request.approvalToolName, systemImage: "wrench.and.screwdriver")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            // 这里拿不到工参（那需要目标会话的时间线）。
                            // 与其假装，不如指个路 —— 会话里的那张卡片会显示完整参数。
                            if let title = model.sessionTitle(for: request.agentId) {
                                Text(String(localized: "完整参数在「\(title)」那张卡片上。"))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }

                            HStack(spacing: Token.Spacing.tight) {
                                Button("拒绝") {
                                    Task { await model.decide(approval: request, decision: .rejected) }
                                }
                                .buttonStyle(.bordered)
                                .tint(.red)

                                Button("批准一次") {
                                    Task { await model.decide(approval: request, decision: .allowedOnce) }
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    } header: {
                        sessionHeader(for: request.agentId)
                    }
                }

                ForEach(model.pendingQuestions, id: \.eventId) { request in
                    Section {
                        UserQuestionForm(request: request) {
                            Task { await model.decline(question: request) }
                        }
                    } header: {
                        sessionHeader(for: request.agentId)
                    }
                }
            }
            .navigationTitle("待处理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

/// `user-questions/request` 的作答表单：单选 / 多选 / 开放文本。
/// 回答 agent 的提问。
///
/// 三处是照 HIG 与协议约定改的（原版都能用，但"支持得不好"）：
///   · **多选用勾选行，不用开关**。HIG：开关是"立即生效的设置"，多选列表用勾选；
///     而且开关在一列里视觉噪音很大。
///   · **必须每题都有答案才能提交**。协议侧要求答案批"恰好一次地命名每个问题"，
///     允许空提交等于让 agent 收到一个空回答。
///   · **可以跳过**。用户不想答时得有条出路，而不是被逼着编一个答案。
struct UserQuestionForm: View {
    let request: WaterfallRequest
    /// 用户跳过时回调（调用方负责把 waterfall 按"拒绝"结掉）。
    var onSkip: (() -> Void)?

    @Environment(AppModel.self) private var model
    @State private var singleChoice: [String: String] = [:]
    @State private var multiChoices: [String: Set<String>] = [:]
    @State private var customText: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: Token.Spacing.section) {
            ForEach(Array(request.questions.enumerated()), id: \.element.id) { index, question in
                questionBlock(question, index: index)
            }

            VStack(spacing: Token.Spacing.tight) {
                Button {
                    submit()
                } label: {
                    Text("提交回答").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isComplete)

                if !isComplete {
                    Text(unansweredHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let onSkip {
                    // 说的是"这一整次提问"而不是"这个问题"：一批可能有好几个问题，
                    // 跳过是把整批都作罢，措辞不能让人以为只跳一个。
                    Button(request.questions.count > 1 ? "都不回答（结束这次提问）" : "跳过这个问题", role: .destructive) {
                        onSkip()
                    }
                    .font(.footnote)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private func questionBlock(_ question: WaterfallRequest.Question, index: Int) -> some View {
        VStack(alignment: .leading, spacing: Token.Spacing.tight) {
            HStack(alignment: .firstTextBaseline, spacing: Token.Spacing.hairline) {
                if request.questions.count > 1 {
                    // `verbatim`：这只是个序号，不该进本地化目录
                    // （写成 `Text("\(index + 1)")` 会生成一条 key 为 `%lld` 的条目）。
                    Text(verbatim: String(index + 1))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                if let header = question.header {
                    Text(header)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            if !question.question.isEmpty {
                // 问句里常有 `code`、列表、强调 —— 走同一套 Markdown 渲染。
                MarkdownBody(text: question.question)
            }
            if let detail = question.detail, !detail.isEmpty {
                MarkdownBody(text: detail)
                    .foregroundStyle(.secondary)
            }

            if question.options.isEmpty {
                TextField("你的回答", text: binding(for: question.id), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
            } else if question.isMultiSelect {
                VStack(spacing: 0) {
                    ForEach(question.options) { option in
                        Button {
                            toggle(questionId: question.id, label: option.label)
                        } label: {
                            optionRow(option, isSelected: multiChoices[question.id]?.contains(option.label) ?? false)
                        }
                        .buttonStyle(.plain)
                        if option.id != question.options.last?.id { Divider() }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: Token.Radius.chip, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                )
                TextField("补充说明（可选）", text: binding(for: question.id), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
            } else {
                VStack(spacing: 0) {
                    ForEach(question.options) { option in
                        Button {
                            singleChoice[question.id] = option.label
                        } label: {
                            optionRow(option, isSelected: singleChoice[question.id] == option.label)
                        }
                        .buttonStyle(.plain)
                        if option.id != question.options.last?.id { Divider() }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: Token.Radius.chip, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                )
                TextField("其它（可选）", text: binding(for: question.id), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func optionRow(_ option: WaterfallRequest.Question.Option, isSelected: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Token.Spacing.tight) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            VStack(alignment: .leading, spacing: 2) {
                // 选项标签也走 Markdown：agent 经常把 `**重点**` 写进 label。
                // 渲染只影响显示 —— 回给宿主的仍然是 `option.label` 原文。
                InlineMarkdown(option.label)
                    .foregroundStyle(.primary)
                if let description = option.description, !description.isEmpty {
                    Text(description).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Token.Spacing.tight)
        .padding(.vertical, Token.Spacing.hairline)
        .frame(minHeight: Token.minimumHitTarget)
        .contentShape(Rectangle())
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: 校验与提交

    /// 每个问题都要有答案：选了选项，或者写了自定义回答。
    private var isComplete: Bool {
        request.questions.allSatisfy(hasAnswer)
    }

    private func hasAnswer(_ question: WaterfallRequest.Question) -> Bool {
        let custom = customText[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard question.options.isEmpty else {
            if question.isMultiSelect {
                return !(multiChoices[question.id]?.isEmpty ?? true) || !custom.isEmpty
            }
            return (singleChoice[question.id]?.isEmpty == false) || !custom.isEmpty
        }
        return !custom.isEmpty
    }

    private var unansweredHint: String {
        let missing = request.questions.filter { !hasAnswer($0) }.count
        return missing == 1
            ? String(localized: "还有 1 个问题没回答")
            : String(format: String(localized: "还有 %lld 个问题没回答"), missing)
    }

    private func submit() {
        let answers: [(id: String, selected: [String], custom: String?)] = request.questions.map { question in
            let custom = customText[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedCustom = (custom?.isEmpty ?? true) ? nil : custom
            if question.options.isEmpty {
                return (question.id, [], trimmedCustom)
            }
            if question.isMultiSelect {
                return (question.id, Array(multiChoices[question.id] ?? []).sorted(), trimmedCustom)
            }
            let choice = singleChoice[question.id].map { $0.isEmpty ? [] : [$0] } ?? []
            return (question.id, choice, trimmedCustom)
        }
        Task { await model.answer(question: request, answers: answers) }
    }

    private func toggle(questionId: String, label: String) {
        var set = multiChoices[questionId] ?? []
        if set.contains(label) { set.remove(label) } else { set.insert(label) }
        multiChoices[questionId] = set
    }

    /// 开放文本/补充说明的绑定。
    private func binding(for id: String) -> Binding<String> {
        Binding(
            get: { customText[id] ?? "" },
            set: { customText[id] = $0 }
        )
    }
}

/// 会话顶部常驻的"待处理"条：有待审批时把重要性提升到前台（HIG 的 Depth 原则）。
struct PendingBanner: View {
    @Environment(AppModel.self) private var model
    /// 外部可以把 sheet 顶开（会话列表用它把待处理直接亮出来）。
    @Binding var isPresented: Bool

    init(isPresented: Binding<Bool> = .constant(false)) {
        self._isPresented = isPresented
    }

    var body: some View {
        if !model.pendingApprovals.isEmpty || !model.pendingQuestions.isEmpty {
            Button {
                isPresented = true
            } label: {
                HStack(spacing: Token.Spacing.tight) {
                    Image(systemName: "exclamationmark.bubble.fill")
                        .foregroundStyle(.orange)
                    Text(countLabel)
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, Token.Spacing.gutter)
                .padding(.vertical, Token.Spacing.tight)
                .background(.regularMaterial)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $isPresented) { ApprovalSheet() }
            .accessibilityLabel(Text(countLabel))
            .accessibilityHint(Text("打开待处理列表"))
        }
    }

    private var countLabel: String {
        var parts: [String] = []
        if !model.pendingApprovals.isEmpty {
            parts.append(String(format: String(localized: "%lld 个待批准"), model.pendingApprovals.count))
        }
        if !model.pendingQuestions.isEmpty {
            parts.append(String(format: String(localized: "%lld 个待回答"), model.pendingQuestions.count))
        }
        return parts.joined(separator: " · ")
    }
}
