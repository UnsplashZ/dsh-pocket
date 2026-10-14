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

/// 连接方式。
///
/// **不在设置页里暴露** —— 产品上默认且只用 iroh（`.remote`）：它公网可用、
/// 打洞成功时不经第三方、回退中转只见密文，已经覆盖了全部真实场景。
///
/// 另外两种是**开发者模式**，只在 DEBUG 构建里通过 `UserDefaults` 打开：
/// ```bash
/// xcrun simctl spawn booted defaults write cc.unsplashz.dshpocket settings.transportMode -string devDirect
/// ```
/// - `.devDirect`：打本机回环上的直连网关，模拟器里开发界面/协议时不需要真机与配对；
/// - `.directGateway`：打一个带令牌的直连网关（Tailscale / 局域网 / 反代后面）。
///   **实测过 iroh 本身就能走 Tailscale**（它的 netdev 会枚举所有网卡，
///   tailnet 地址也是候选地址之一），所以这条现在只是"iroh 走不通时的备用路"。
public enum TransportMode: String, CaseIterable, Identifiable, Sendable {
    /// 走 iroh P2P：公网可用，打洞成功时不经第三方，失败回退中转（只见密文）。
    case remote
    /// 直连网关（DEV-DIRECT）：模拟器开发用，打本机回环。
    case devDirect
    /// 直连网关（Tailscale / 局域网 / 反向代理）：填一个手机能路由到的地址 + 令牌。
    case directGateway

    public var id: String { rawValue }

    public var label: LocalizedStringKey {
        switch self {
        case .remote: return "远端连接（iroh）"
        case .devDirect: return "开发直连（本机）"
        case .directGateway: return "直连网关（Tailscale / 局域网）"
        }
    }

    public var symbol: String {
        switch self {
        case .remote: return "point.3.connected.trianglepath.dotted"
        case .devDirect: return "laptopcomputer"
        case .directGateway: return "network"
        }
    }

    /// 已解析的字符串。
    ///
    /// `label` 是 `LocalizedStringKey`，**不能**再插进另一个 `LocalizedStringKey` 里 ——
    /// 那样插进去的是它的 `description`（会原样显示成
    /// `LocalizedStringKey(key: "开发直连（本机）", …)`）。需要拼接时用这个。
    public var resolvedLabel: String {
        switch self {
        case .remote: return String(localized: "远端连接（iroh）")
        case .devDirect: return String(localized: "开发直连（本机）")
        case .directGateway: return String(localized: "直连网关（Tailscale / 局域网）")
        }
    }
}

/// 应用设置。`UserDefaults` 是唯一存储 —— 这里没有需要 Keychain 的东西
/// （设备密钥由 TetherKit 自己管，见 `TetherSecretStore`）。
@MainActor
/// 会话内容的字号档位。
public enum FontScale: String, CaseIterable, Sendable {
    case small
    case standard
    case large
    case larger

    public var label: LocalizedStringKey {
        switch self {
        case .small: return "小"
        case .standard: return "标准"
        case .large: return "大"
        case .larger: return "特大"
        }
    }

    public var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .small: return .small
        case .standard: return .large
        case .large: return .xLarge
        case .larger: return .xxLarge
        }
    }
}

@Observable
public final class AppSettings {
    private enum Key {
        static let appearance = "settings.appearance"
        static let displayName = "settings.displayName"
        static let notifyApprovals = "settings.notify.approvals"
        static let notifyQuestions = "settings.notify.questions"
        static let notifyCompletions = "settings.notify.completions"
        static let showRawEvents = "settings.showRawEvents"
        static let expandReasoning = "settings.expandReasoning"
        static let devDirect = "settings.devDirect"
        static let transportMode = "settings.transportMode"
        static let gatewayURL = "settings.gatewayURL"
        static let gatewayToken = "settings.gatewayToken"
        static let devDirectURL = "settings.devDirectURL"
        static let activeHost = "settings.activeHost"
        static let hasOnboarded = "settings.hasOnboarded"
        static let fontScale = "settings.fontScale"
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

    /// 会话内容的字号。
    ///
    /// 跟桌面端一样**只影响会话内容** —— 导航栏、设置页保持系统字号，
    /// 否则调大之后设置页会挤成一团。
    public var fontScale: FontScale {
        didSet { defaults.set(fontScale.rawValue, forKey: Key.fontScale) }
    }

    /// 会话菜单里的"显示模型可见的原始事件"（系统提示、request/header…）。
    public var showRawEvents: Bool {
        didSet { defaults.set(showRawEvents, forKey: Key.showRawEvents) }
    }

    /// 思考过程默认展开。
    ///
    /// 默认**关**：推理过程通常很长，默认摊开会把对话本身挤下去。
    /// 想看细节的人可以在设置里打开，或者单条点开。
    public var expandReasoningByDefault: Bool {
        didSet { defaults.set(expandReasoningByDefault, forKey: Key.expandReasoning) }
    }

    /// DEV-DIRECT：跳过 iroh，直接打 Mac 上的注入 cookie 的 dev 代理（ADR-0009）。
    public var devDirectEnabled: Bool {
        didSet { defaults.set(devDirectEnabled, forKey: Key.devDirect) }
    }

    /// 连接方式。默认走 iroh；非 `.remote` 只在 DEBUG 里由开发者打开。
    public var transportMode: TransportMode {
        didSet { defaults.set(transportMode.rawValue, forKey: Key.transportMode) }
    }

    /// 直连网关地址，例如 `http://100.64.0.1:8788`。
    public var gatewayURL: String {
        didSet { defaults.set(gatewayURL, forKey: Key.gatewayURL) }
    }

    /// 直连网关的共享令牌。绑非回环地址时网关会要求它。
    public var gatewayToken: String {
        didSet { defaults.set(gatewayToken, forKey: Key.gatewayToken) }
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
        self.fontScale = FontScale(rawValue: defaults.string(forKey: Key.fontScale) ?? "") ?? .standard
        self.expandReasoningByDefault = defaults.bool(forKey: Key.expandReasoning)
        self.devDirectEnabled = defaults.bool(forKey: Key.devDirect)
        // 迁移：老版本只有 devDirectEnabled 这个开关。
        if let raw = defaults.string(forKey: Key.transportMode), let mode = TransportMode(rawValue: raw) {
            self.transportMode = mode
        } else {
            self.transportMode = defaults.bool(forKey: Key.devDirect) ? .devDirect : .remote
        }
        self.gatewayURL = defaults.string(forKey: Key.gatewayURL) ?? ""
        self.gatewayToken = defaults.string(forKey: Key.gatewayToken) ?? ""
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
