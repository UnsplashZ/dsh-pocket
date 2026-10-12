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

    @Environment(AppModel.self) private var model
    @State private var isWorking = false
    @State private var feedback = 0

    private var request: WaterfallRequest? {
        model.pendingApprovals.first { $0.eventId == approval.approvalId }
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

                Text(approval.reason.isEmpty ? String(localized: "电脑上有一个操作在等你批准。") : approval.reason)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                Label(approval.toolName, systemImage: "wrench.and.screwdriver")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if approval.isPending {
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
                    .disabled(request == nil || isWorking)

                    Button("稍后处理") { model.deferApproval(request ?? WaterfallPlaceholder.value) }
                        .font(.footnote)
                        .disabled(request == nil)
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

/// 「稍后处理」的占位：拿不到对应请求时不要假装能操作。
enum WaterfallPlaceholder {
    static let value = WaterfallRequest(json: .object([:]))
}

/// 把"等待审批"提升为模态（用户偏好路径）。点通知回到前台时用它。
struct ApprovalSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

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
                            Label(request.approvalToolName, systemImage: "wrench.and.screwdriver")
                                .font(.caption)
                                .foregroundStyle(.secondary)

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
                    }
                }

                ForEach(model.pendingQuestions, id: \.eventId) { request in
                    Section {
                        UserQuestionForm(request: request) {
                            Task { await model.decline(question: request) }
                        }
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
