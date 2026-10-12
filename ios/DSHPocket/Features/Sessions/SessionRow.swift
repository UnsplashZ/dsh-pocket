import DSHKit
import SwiftUI

/// 会话列表的一行。
///
/// 主标题 = 会话标题（1 行截断）；副标题 = 最后一轮助手回复摘要（≤2 行）；
/// 尾部 = 相对时间 + 状态。设计上刻意不显示 sessionId（那是"复制 ID"菜单的事）。
struct SessionRow: View {
    let summary: SessionSummary
    var isPinned = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .top, spacing: Token.Spacing.compact) {
            VStack(alignment: .leading, spacing: Token.Spacing.hairline) {
                HStack(spacing: Token.Spacing.hairline) {
                    Text(summary.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if summary.isRunning {
                        StatusDot(tone: .success, label: String(localized: "正在运行"))
                    }
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
        if summary.isRunning { parts.append(String(localized: "正在运行")) }
        if !summary.subtitle.isEmpty { parts.append(summary.subtitle) }
        parts.append(summary.workspaceName)
        parts.append(Format.relativeTime(summary.updatedAt))
        return parts.joined(separator: "，")
    }
}
