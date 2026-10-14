import DSHKit
import Foundation
import SwiftUI

/// 设计令牌（docs/IOS-DESIGN.md §5）。
///
/// 全部是**语义**的：字体只用语义字体、颜色只用语义色、间距走 8pt 网格。
/// 这里刻意不提供任何 `Color(hex:)` 之类的入口 —— 硬编码颜色是明确的反模式。
public enum Token {
    // MARK: 间距（8pt 网格）

    public enum Spacing {
        /// 4pt：图标与紧邻文字之间。
        public static let hairline: CGFloat = 4
        /// 8pt：同一块内容里的元素间距。
        public static let tight: CGFloat = 8
        /// 12pt：卡片内边距。
        public static let compact: CGFloat = 12
        /// 16pt：紧凑宽度下的屏幕水平边距。
        public static let gutter: CGFloat = 16
        /// 20pt：常规宽度下的屏幕水平边距。
        public static let regularGutter: CGFloat = 20
        /// 24pt：区块之间。
        public static let section: CGFloat = 24
    }

    public enum Radius {
        /// 卡片、分组容器。
        public static let card: CGFloat = 12
        /// 气泡。
        public static let bubble: CGFloat = 18
        /// 小徽标、缩略图。
        public static let chip: CGFloat = 8
    }

    /// 触摸目标下限。任何可点元素都要 ≥ 这个值（含 `contentShape`）。
    public static let minimumHitTarget: CGFloat = 44

    /// 圆形控件（输入区的附件/发送、行尾的动作按钮）。
    ///
    /// 放在这里是为了让**并排的按钮由同一个数字产出** —— 样式手抄两遍必然漂移，
    /// 实测漂移过一次：一个 20pt 字形配 44pt 圆底，另一个是 30pt 的实心圆符号，
    /// 并排看就是"图标大小不一致"。
    public enum Control {
        /// 圆的直径。
        public static let diameter: CGFloat = 36
        /// 圆里字形的字号。
        public static let glyph: CGFloat = 17
    }

    /// 时间线自动滚动的"贴底"判定容差。
    public static let stickToBottomTolerance: CGFloat = 48
}

// MARK: - 状态语义

/// 状态不只是颜色：每个状态同时给出符号与文案，`Increase Contrast` 下也读得出来。
public enum StatusTone: Sendable {
    case neutral
    case info
    case success
    case warning
    case failure

    public var color: Color {
        switch self {
        case .neutral: return .secondary
        case .info: return .accentColor
        case .success: return .green
        case .warning: return .orange
        case .failure: return .red
        }
    }
}

// MARK: - 格式化

/// 所有格式化都走这里，保证跟随 Locale。
public enum Format {
    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static let absolute: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    /// 列表页的相对时间："3 分钟前"。
    ///
    /// 语言由 App 自己的本地化决定（`Bundle.main` 的 preferredLocalizations），
    /// 这里**不**提供 locale 参数：`String(localized:locale:)` 的 `locale` 只影响
    /// 文案内部的数字/日期格式，挑不了 `.lproj` —— 传 `zh-Hans` 在 en 设备上仍然出英文
    /// （CI 上实测过），留着这个参数只会让人以为它能换语言。
    public static func relativeTime(_ date: Date, now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 60 { return String(localized: "刚刚") }
        if interval < 86_400 * 7 {
            return relative.localizedString(for: date, relativeTo: now)
        }
        return absolute.string(from: date)
    }

    /// 时间线里的时刻。
    public static func time(_ date: Date) -> String { clock.string(from: date) }

    /// 带日期的时刻（提醒用）。
    public static func absoluteTime(_ date: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate(calendar.isDateInToday(date) ? "Hm" : "MMMdHm")
        return formatter.string(from: date)
    }

    /// 字节数："1.2 MB"。用 `ByteCountFormatter` 而不是自己拼。
    public static func bytes(_ count: Int?) -> String? {
        guard let count, count >= 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    /// 耗时："1.2 秒" / "45 毫秒"。语言同理由 App 本地化决定，不接受 locale 参数。
    public static func duration(_ seconds: TimeInterval?) -> String? {
        guard let seconds, seconds >= 0 else { return nil }
        // 用 String(format:) + 纯格式串而不是插值：String Catalog 的 key 才会是
        // 明确的 `%lld` / `%.1f`，不会出现 `\(x, specifier:)` 那种边角写法。
        if seconds < 1 {
            return String(format: String(localized: "%lld 毫秒"), Int((seconds * 1000).rounded()))
        }
        if seconds < 60 {
            return String(format: String(localized: "%.1f 秒"), seconds)
        }
        let minutes = Int(seconds / 60)
        let remainder = Int(seconds.truncatingRemainder(dividingBy: 60))
        return String(format: String(localized: "%lld 分 %lld 秒"), minutes, remainder)
    }

    /// 令牌数："12.3k"。
    public static func tokens(_ count: Int?) -> String? {
        guard let count else { return nil }
        if count < 1000 { return "\(count)" }
        if count < 1_000_000 { return String(format: "%.1fk", Double(count) / 1000) }
        return String(format: "%.1fM", Double(count) / 1_000_000)
    }

    /// 上下文占用："62% · 62.2k / 1.0M"。
    public static func contextPressure(_ pressure: ContextPressure?) -> String? {
        guard let pressure, pressure.contextWindow > 0 else { return nil }
        let fraction = Double(pressure.projectedTokens) / Double(pressure.contextWindow)
        let percent = Int((fraction * 100).rounded())
        let used = tokens(pressure.projectedTokens) ?? "?"
        let total = tokens(pressure.contextWindow) ?? "?"
        return "\(percent)% · \(used) / \(total)"
    }
}

// MARK: - 可复用视图

/// 卡片容器：圆角连续、分组背景色，与系统卡片观感一致。
public struct Card<Content: View>: View {
    private let content: Content
    private let padding: CGFloat

    public init(padding: CGFloat = Token.Spacing.compact, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Token.Radius.card, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
    }
}

/// 状态徽标：符号 + 文案，颜色只是辅助。
public struct StatusBadge: View {
    private let text: String
    private let symbol: String
    private let tone: StatusTone

    public init(_ text: String, symbol: String, tone: StatusTone) {
        self.text = text
        self.symbol = symbol
        self.tone = tone
    }

    public var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol)
                .symbolVariant(.fill)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tone.color)
        .padding(.horizontal, Token.Spacing.tight)
        .padding(.vertical, Token.Spacing.hairline)
        .background(
            Capsule(style: .continuous).fill(tone.color.opacity(0.12))
        )
        .accessibilityElement(children: .combine)
    }
}

/// 小圆点：running / 等审批这类"一眼可见"的指示。
/// 有 `accessibilityLabel`，不靠颜色单独传达。
public struct StatusDot: View {
    private let tone: StatusTone
    private let label: String

    public init(tone: StatusTone, label: String) {
        self.tone = tone
        self.label = label
    }

    public var body: some View {
        Circle()
            .fill(tone.color)
            .frame(width: 8, height: 8)
            .overlay(Circle().strokeBorder(Color(.separator), lineWidth: 0.5))
            .accessibilityLabel(label)
    }
}

/// 统一的分节标题。
public struct SectionHeader: View {
    private let title: String

    public init(_ title: String) { self.title = title }

    public var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
    }
}

/// 等宽、可横向滚动、可复制的代码/输出块。
public struct MonoBlock: View {
    private let text: String
    private let lineLimit: Int?

    public init(_ text: String, lineLimit: Int? = nil) {
        self.text = text
        self.lineLimit = lineLimit
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .padding(Token.Spacing.tight)
                .lineLimit(lineLimit)
        }
        .background(
            RoundedRectangle(cornerRadius: Token.Radius.chip, style: .continuous)
                .fill(Color(.tertiarySystemFill))
        )
    }
}

/// 触感反馈的语义化用法（`.sensoryFeedback` 需要 Equatable 触发器）。
public enum Haptic {
    public struct Trigger: Equatable {
        public var id: UUID = UUID()
        public init() {}
    }
}

// MARK: - 无障碍辅助

extension View {
    /// 让一个自定义行在 VoiceOver 下读成一句话，而不是一堆碎片。
    public func accessibleRow(label: String, hint: String? = nil) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(label))
            .accessibilityHint(Text(hint ?? ""))
    }

    /// 保证 44pt 触摸目标（图标按钮最容易踩这条）。
    public func minimumHitTarget() -> some View {
        contentShape(Rectangle())
            .frame(minWidth: Token.minimumHitTarget, minHeight: Token.minimumHitTarget)
    }

    /// 尊重"降低动态效果"的条件动画。
    @ViewBuilder
    public func animatedWhenAllowed(_ animation: Animation = .default, value: some Equatable) -> some View {
        if UIAccessibility.isReduceMotionEnabled {
            self
        } else {
            self.animation(animation, value: value)
        }
    }
}

// MARK: - 模型语义色 → 界面语义色

extension TimelineItem.Note.Tone {
    /// DSHKit 不认识 `Color`（协议层不该依赖 SwiftUI），所以映射放在这里。
    var statusTone: StatusTone {
        switch self {
        case .neutral: return .neutral
        case .info: return .info
        case .success: return .success
        case .warning: return .warning
        case .failure: return .failure
        }
    }
}
