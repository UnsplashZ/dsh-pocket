import DSHKit
import SwiftUI

/// 会话列表的一行。
///
/// 主标题 = 会话标题（1 行截断）；副标题 = 最后一轮助手回复摘要（≤2 行）；
/// 尾部 = 相对时间 + 状态。设计上刻意不显示 sessionId（那是"复制 ID"菜单的事）。
/// 一个会话现在处于什么状态。
///
/// 用户："最好在主页能看出来不同会话的状态…现在这个小绿灯容易让我以为是
/// 这个会话完成了。最好是绿灯表示会话完成，红灯报错，黄灯等待批准或回复，
/// 还有一个转圈的动画表示任务执行中。"
///
/// 之前的做法是"跑着就亮**绿**灯" —— 正好跟直觉相反。
enum SessionStatus {
    /// 电脑在干活 —— 转圈。
    case running
    /// 等用户回答（宿主的 `userQuestions.active`）。
    case waiting
    /// 电脑不可用 / 连不上。
    case error
    /// 空闲（上一轮已经结束）。
    case idle

    init(_ summary: SessionSummary, awaitingApproval: Bool = false) {
        if !summary.agentAvailable {
            self = .error
        } else if awaitingApproval {
            // 审批是**连接级**的瞬时状态，不在会话投影里 —— 由 AppModel 记着。
            self = .waiting
        } else if !summary.projections.userQuestions.active.isEmpty {
            // 宿主的 `userQuestions` 投影里有未决问题 —— 它正等着人回答。
            self = .waiting
        } else if summary.isRunning {
            self = .running
        } else {
            self = .idle
        }
    }

    var label: String {
        switch self {
        case .running: return String(localized: "执行中")
        case .waiting: return String(localized: "等待回复")
        case .error: return String(localized: "不可用")
        case .idle: return String(localized: "已完成")
        }
    }
}

/// 会话状态徽标：**转圈 = 执行中**、黄 = 等待、红 = 不可用、绿 = 已完成。
struct SessionStatusBadge: View {
    let status: SessionStatus

    var body: some View {
        switch status {
        case .running:
            // 转圈动画 —— 一眼看出"在动"。
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel(Text(status.label))
        case .waiting:
            StatusDot(tone: .warning, label: status.label)
        case .error:
            StatusDot(tone: .failure, label: status.label)
        case .idle:
            StatusDot(tone: .success, label: status.label)
        }
    }
}

struct SessionRow: View {
    let summary: SessionSummary
    var isPinned = false
    /// 审批是连接级的瞬时状态 —— 从环境里取，别让列表页去拼一个复杂表达式
    ///（那会让编译器放弃）。
    @Environment(AppModel.self) private var model
    private var awaitingApproval: Bool { model.sessionsAwaitingApproval.contains(summary.sessionId) }
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .top, spacing: Token.Spacing.compact) {
            VStack(alignment: .leading, spacing: Token.Spacing.hairline) {
                HStack(spacing: Token.Spacing.hairline) {
                    Text(summary.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    SessionStatusBadge(status: SessionStatus(summary, awaitingApproval: awaitingApproval))
                }

                if !summary.subtitle.isEmpty {
                    Text(summary.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        // AX3 以上只给一行，别让行高失控
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 1 : 2)
                }

                HStack(spacing: Token.Spacing.tight) {
                    Text(summary.workspaceName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if let pressure = Format.contextPressure(summary.projections.contextPressure) {
                        Text(pressure)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer(minLength: Token.Spacing.tight)

            VStack(alignment: .trailing, spacing: Token.Spacing.hairline) {
                Text(Format.relativeTime(summary.updatedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                // 只留真正可操作的信号：置顶。子会话/冷会话那些标记对列表没帮助，
                // 反而让人猜（上一版的 moon.zzz 就被问"那是什么意思"）。
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel(Text("已置顶"))
                }
            }
        }
        .padding(.vertical, Token.Spacing.hairline)
        .contentShape(Rectangle())
        .accessibleRow(label: accessibilityLabel, hint: String(localized: "打开这个会话"))
    }

    private var accessibilityLabel: String {
        var parts: [String] = [summary.title]
        parts.append(SessionStatus(summary, awaitingApproval: awaitingApproval).label)
        if !summary.subtitle.isEmpty { parts.append(summary.subtitle) }
        parts.append(summary.workspaceName)
        parts.append(Format.relativeTime(summary.updatedAt))
        return parts.joined(separator: "，")
    }
}
