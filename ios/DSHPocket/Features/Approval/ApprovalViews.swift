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
                        UserQuestionForm(request: request)
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
struct UserQuestionForm: View {
    let request: WaterfallRequest

    @Environment(AppModel.self) private var model
    @State private var singleChoice: [String: String] = [:]
    @State private var multiChoices: [String: Set<String>] = [:]
    @State private var customText: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: Token.Spacing.compact) {
            ForEach(request.questions) { question in
                VStack(alignment: .leading, spacing: Token.Spacing.tight) {
                    if let header = question.header {
                        Text(header)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(question.question)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = question.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }

                    if question.options.isEmpty {
                        TextField("你的回答", text: binding(for: question.id))
                            .textFieldStyle(.roundedBorder)
                    } else if question.isMultiSelect {
                        ForEach(question.options) { option in
                            Toggle(isOn: multiBinding(questionId: question.id, label: option.label)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label)
                                    if let description = option.description {
                                        Text(description).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .toggleStyle(.switch)
                        }
                        TextField("补充说明（可选）", text: binding(for: question.id))
                            .textFieldStyle(.roundedBorder)
                    } else {
                        Picker("选择", selection: singleBinding(question.id)) {
                            Text("未选择").tag("")
                            ForEach(question.options) { option in
                                Text(option.label).tag(option.label)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                        TextField("其它（可选）", text: binding(for: question.id))
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(.vertical, Token.Spacing.hairline)
            }

            Button {
                submit()
            } label: {
                Text("提交回答").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func submit() {
        let answers: [(id: String, selected: [String], custom: String?)] = request.questions.map { question in
            if question.options.isEmpty {
                return (question.id, [], customText[question.id])
            }
            if question.isMultiSelect {
                return (question.id, Array(multiChoices[question.id] ?? []).sorted(), customText[question.id])
            }
            let choice = singleChoice[question.id].map { $0.isEmpty ? [] : [$0] } ?? []
            return (question.id, choice, customText[question.id])
        }
        Task { await model.answer(question: request, answers: answers) }
    }

    private func singleBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { singleChoice[id] ?? "" },
            set: { singleChoice[id] = $0 }
        )
    }

    private func multiBinding(questionId: String, label: String) -> Binding<Bool> {
        Binding(
            get: { multiChoices[questionId]?.contains(label) ?? false },
            set: { isOn in
                var set = multiChoices[questionId] ?? []
                if isOn { set.insert(label) } else { set.remove(label) }
                multiChoices[questionId] = set
            }
        )
    }

    /// 开放文本/补充说明的绑定。
    private func binding(for id: String, key: String = "custom") -> Binding<String> {
        Binding(
            get: { customText[id] ?? "" },
            set: { customText[id] = $0 }
        )
    }
}

/// 会话顶部常驻的"待处理"条：有待审批时把重要性提升到前台（HIG 的 Depth 原则）。
struct PendingBanner: View {
    @Environment(AppModel.self) private var model
    @State private var showSheet = false

    var body: some View {
        if !model.pendingApprovals.isEmpty || !model.pendingQuestions.isEmpty {
            Button {
                showSheet = true
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
            .sheet(isPresented: $showSheet) { ApprovalSheet() }
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
