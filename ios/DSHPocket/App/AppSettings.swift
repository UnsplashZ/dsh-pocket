import Foundation
import Observation
import SwiftUI

/// 用户可见的外观偏好。跟随系统是默认，也是 HIG 建议的默认。
public enum AppearancePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    public var label: LocalizedStringKey {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    public var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
}

/// 通知开关。**三项都默认关**：按 HIG，权限只在用户打开对应开关时才请求。
public struct NotificationPreferences: Sendable, Equatable {
    public var approvals = false
    public var questions = false
    public var completions = false

    public init() {}

    public var anyEnabled: Bool { approvals || questions || completions }
}

/// 应用设置。`UserDefaults` 是唯一存储 —— 这里没有需要 Keychain 的东西
/// （设备密钥由 TetherKit 自己管，见 `TetherSecretStore`）。
@MainActor
@Observable
public final class AppSettings {
    private enum Key {
        static let appearance = "settings.appearance"
        static let displayName = "settings.displayName"
        static let notifyApprovals = "settings.notify.approvals"
        static let notifyQuestions = "settings.notify.questions"
        static let notifyCompletions = "settings.notify.completions"
        static let showRawEvents = "settings.showRawEvents"
        static let devDirect = "settings.devDirect"
        static let devDirectURL = "settings.devDirectURL"
        static let activeHost = "settings.activeHost"
        static let hasOnboarded = "settings.hasOnboarded"
    }

    private let defaults: UserDefaults

    public var appearance: AppearancePreference {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    /// 配准时登记给电脑看的设备名。
    public var displayName: String {
        didSet { defaults.set(displayName, forKey: Key.displayName) }
    }

    public var notifications: NotificationPreferences {
        didSet {
            defaults.set(notifications.approvals, forKey: Key.notifyApprovals)
            defaults.set(notifications.questions, forKey: Key.notifyQuestions)
            defaults.set(notifications.completions, forKey: Key.notifyCompletions)
        }
    }

    /// 会话菜单里的"显示模型可见的原始事件"（系统提示、request/header…）。
    public var showRawEvents: Bool {
        didSet { defaults.set(showRawEvents, forKey: Key.showRawEvents) }
    }

    /// DEV-DIRECT：跳过 iroh，直接打 Mac 上的注入 cookie 的 dev 代理（ADR-0009）。
    public var devDirectEnabled: Bool {
        didSet { defaults.set(devDirectEnabled, forKey: Key.devDirect) }
    }

    public var devDirectBaseURL: String {
        didSet { defaults.set(devDirectBaseURL, forKey: Key.devDirectURL) }
    }

    public var activeHostId: String? {
        didSet { defaults.set(activeHostId, forKey: Key.activeHost) }
    }

    public var hasOnboarded: Bool {
        didSet { defaults.set(hasOnboarded, forKey: Key.hasOnboarded) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.appearance = AppearancePreference(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        self.displayName = defaults.string(forKey: Key.displayName)
            ?? UIDevice.current.name
        var prefs = NotificationPreferences()
        prefs.approvals = defaults.bool(forKey: Key.notifyApprovals)
        prefs.questions = defaults.bool(forKey: Key.notifyQuestions)
        prefs.completions = defaults.bool(forKey: Key.notifyCompletions)
        self.notifications = prefs
        self.showRawEvents = defaults.bool(forKey: Key.showRawEvents)
        self.devDirectEnabled = defaults.bool(forKey: Key.devDirect)
        self.devDirectBaseURL = defaults.string(forKey: Key.devDirectURL) ?? "http://127.0.0.1:8788"
        self.activeHostId = defaults.string(forKey: Key.activeHost)
        self.hasOnboarded = defaults.bool(forKey: Key.hasOnboarded)
    }

    /// 设备名要短：未配对连接的首行硬上限是 512 字节（电脑端 `MAX_UNPAIRED_LINE`）。
    public var sanitizedDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "iPhone" }
        return String(trimmed.prefix(40))
    }
}
