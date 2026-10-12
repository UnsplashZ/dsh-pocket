import Foundation

/// 会话类别。列表页据此分流。
public enum SessionCategory: Sendable, Hashable {
    /// 你在电脑上开的普通会话。
    case session
    /// 子代理会话（`origin == "subagent"`）。**默认不进主列表** ——
    /// 官方工作区 UI 也是这么过滤的；它们由父会话的时间线里那张卡承载。
    case subagent
    /// IM 桥接出来的频道会话（feishu / weixin / …）。单独一类。
    case channel(String)

    public var isSubagent: Bool { if case .subagent = self { return true }; return false }
    public var isChannel: Bool { if case .channel = self { return true }; return false }

    /// 频道的展示名。
    public var channelLabel: String? {
        switch self {
        case .channel(let name): return name.capitalized
        default: return nil
        }
    }
}

/// 列表页的显示范围。
public enum SessionScope: String, CaseIterable, Identifiable, Sendable {
    /// 普通会话（不含子代理、不含频道）。
    case sessions
    /// 频道会话。
    case channels

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .sessions: return String(localized: "会话")
        case .channels: return String(localized: "频道")
        }
    }

    public func matches(_ category: SessionCategory) -> Bool {
        switch self {
        case .sessions: return category == .session
        case .channels: return category.isChannel
        }
    }
}
