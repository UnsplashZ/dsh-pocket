import DSHKit
import SwiftUI

/// 会话的长期目标。
///
/// 桌面端有个完整面板。手机上的价值在于：**目标跑偏了要能马上叫停** ——
/// 之前只有一行「目标已更新」，暂停/恢复/清除都做不了。
///
/// 写操作全部走 `/goal` 命令 —— 目标没有独立的写接口（实测）。
struct GoalSheet: View {
    let session: SessionModel

    @Environment(\.dismiss) private var dismiss

    @State private var isEditing = false
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            List {
                if let goal = session.goal, !goal.phase.isEmpty {
                    Section {
                        HStack {
                            Text(goal.phaseLabel)
                            Spacer()
                            StatusBadge(
                                goal.isActive ? "运行中" : goal.phaseLabel,
                                symbol: goal.isActive ? "circle.dotted" : "pause.circle",
                                tone: goal.isActive ? .info : .neutral
                            )
                        }
                    }

                    if let objective = goal.objective, !objective.isEmpty {
                        Section("目标内容") {
                            Text(objective)
                                .font(.footnote)
                                .textSelection(.enabled)
                        }
                    }

                    Section {
                        if goal.isActive {
                            Button {
                                Task { await session.updateGoal("pause"); dismiss() }
                            } label: {
                                Label("暂停目标", systemImage: "pause.circle")
                            }
                        } else {
                            Button {
                                Task { await session.updateGoal("resume"); dismiss() }
                            } label: {
                                Label("恢复目标", systemImage: "play.circle")
                            }
                        }
                        Button {
                            draft = goal.objective ?? ""
                            isEditing = true
                        } label: {
                            Label("编辑目标", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            Task { await session.updateGoal("clear"); dismiss() }
                        } label: {
                            Label("清除目标", systemImage: "trash")
                        }
                    }
                } else {
                    Section {
                        ContentUnavailableView(
                            "这个会话没有目标",
                            systemImage: "target",
                            description: Text("目标是「让智能体持续做下去」的长期任务。设一个之后，它会自己接着跑。")
                        )
                        Button {
                            draft = ""
                            isEditing = true
                        } label: {
                            Label("设一个目标", systemImage: "plus.circle")
                        }
                    }
                }
            }
            .navigationTitle("目标")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await session.refreshGoal() }
            .alert("目标内容", isPresented: $isEditing) {
                TextField("描述你要它持续做什么", text: $draft, axis: .vertical)
                Button("保存") {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    Task { await session.updateGoal(text) }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("保存之后智能体会持续执行，直到你说停。")
            }
        }
    }
}

/// 上下文明细。
///
/// 三个数而已 —— 用户真正想知道的只有"是不是历史太长了"。
struct ContextBreakdownView: View {
    let breakdown: ContextBreakdown
    let pressure: ContextPressure?

    var body: some View {
        VStack(alignment: .leading, spacing: Token.Spacing.compact) {
            Text("上下文占用")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(breakdown.parts, id: \.label) { part in
                HStack {
                    Text(part.label).font(.footnote)
                    Spacer(minLength: Token.Spacing.gutter)
                    Text(Format.tokens(part.tokens) ?? "0")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack {
                Text("合计").font(.footnote.weight(.medium))
                Spacer(minLength: Token.Spacing.gutter)
                Text(Format.tokens(breakdown.total) ?? "0")
                    .font(.footnote.monospacedDigit().weight(.medium))
            }

            if let pressure, pressure.contextWindow > 0 {
                let ratio = min(1, Double(pressure.pressureTokens) / Double(pressure.contextWindow))
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: ratio)
                        .tint(ratio > 0.85 ? .orange : .accentColor)
                    Text(String(
                        format: String(localized: "占窗口 %lld%% · %@ / %@"),
                        Int(ratio * 100),
                        Format.tokens(pressure.pressureTokens) ?? "0",
                        Format.tokens(pressure.contextWindow) ?? "0"
                    ))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(Token.Spacing.gutter)
        .frame(width: 280)
    }
}
