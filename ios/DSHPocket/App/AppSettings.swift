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
/// 默认仍然是 iroh（`.remote`）：它公网可用、打洞成功时不经第三方、
/// 回退中转只见密文，覆盖了全部真实场景。
///
/// `.uplink`（多路接入）是 0.5.0 起**给用户的第二个选项**：先并行探一遍
/// 电脑端给出的地址清单（局域网 / Tailscale / ZeroTier / 自建中转），
/// 谁先通就用谁；一条都不通才降级回 iroh。它不是"开发模式"，所以在设置页里可见。
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
    /// 多路接入：按配对串里的地址清单并行探测，走电脑端的 uplink 网关；
    /// 一条都不通时自动降级回 iroh。
    case uplink

    public var id: String { rawValue }

    public var label: LocalizedStringKey {
        switch self {
        case .remote: return "远端连接（iroh）"
        case .devDirect: return "开发直连（本机）"
        case .directGateway: return "直连网关（Tailscale / 局域网）"
        case .uplink: return "多路接入"
        }
    }

    public var symbol: String {
        switch self {
        case .remote: return "point.3.connected.trianglepath.dotted"
        case .devDirect: return "laptopcomputer"
        case .directGateway: return "network"
        case .uplink: return "arrow.triangle.branch"
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
        case .uplink: return String(localized: "多路接入")
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
        // 多路接入：用户允许用哪几档（kind 的 rawValue 集合）。
        static let uplinkEnabledTiers = "settings.uplink.enabledTiers"
        // 粘滞窗口：这段时间内重连优先回到上次通的档位（见 UplinkSession.stickyWindow）。
        static let uplinkStickyUntil = "settings.uplink.stickyUntil"
        static let uplinkLastGoodTier = "settings.uplink.lastGoodTier"
    }

    /// 注入的 `UserDefaults`。对子系统（`UplinkCredentialStore`）可见，
    /// 这样单测用独立 suite 时配对材料也跟着隔离 —— 但**写入口仍然只有这个类**。
    let defaults: UserDefaults

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

    /// 多路接入允许使用的档位（`UplinkTierKind.rawValue` 集合）。
    ///
    /// **空集合表示"还没设置过"，语义是"全开"** —— 新装用户不该看到一个
    /// 什么都没勾的界面，然后连不上又不知道为什么。
    public var uplinkEnabledTiers: Set<String> {
        didSet {
            defaults.set(uplinkEnabledTiers.sorted(), forKey: Key.uplinkEnabledTiers)
        }
    }

    /// 粘滞窗口的截止时间。在此之前重连优先回到 `uplinkLastGoodTier`。
    public var uplinkStickyUntil: Date? {
        didSet {
            if let uplinkStickyUntil {
                defaults.set(uplinkStickyUntil.timeIntervalSince1970, forKey: Key.uplinkStickyUntil)
            } else {
                defaults.removeObject(forKey: Key.uplinkStickyUntil)
            }
        }
    }

    /// 上一次连通的档位（kind 的 rawValue）。只用于粘滞与诊断。
    public var uplinkLastGoodTier: String? {
        didSet {
            if let uplinkLastGoodTier {
                defaults.set(uplinkLastGoodTier, forKey: Key.uplinkLastGoodTier)
            } else {
                defaults.removeObject(forKey: Key.uplinkLastGoodTier)
            }
        }
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
        } else if defaults.bool(forKey: Key.devDirect) {
            // 老版本只有 devDirectEnabled 这个开关：打开过就要迁移成 .devDirect
            self.transportMode = .devDirect
        } else if defaults.string(forKey: Key.activeHost) == nil {
            // **全新安装**（没存过连接方式、也没配过电脑）：默认「自动（多路接入）」。
            // 一个配对串就能同时配好局域网/虚拟组网与 iroh 兜底，比让用户先走
            // 只有 iroh 的老路更符合现在的玩法。
            self.transportMode = .uplink
        } else {
            // 已经配过电脑的老用户：**不能**改他的模式。他手里只有一个 iroh 配对，
            // 切成 uplink 会让他在粘新配对串之前彻底连不上 —— 那是回归，不是升级。
            self.transportMode = .remote
        }
        self.gatewayURL = defaults.string(forKey: Key.gatewayURL) ?? ""
        self.gatewayToken = defaults.string(forKey: Key.gatewayToken) ?? ""
        self.devDirectBaseURL = defaults.string(forKey: Key.devDirectURL) ?? "http://127.0.0.1:8788"
        self.uplinkEnabledTiers = Set(defaults.stringArray(forKey: Key.uplinkEnabledTiers) ?? [])
        // 0 = 没存过。`object(forKey:)` 而不是 `double(forKey:)`：
        // 后者对缺失的键返回 0，和"1970 年就过期了"分不开，语义上没错但会写出误导的代码。
        if let stamp = defaults.object(forKey: Key.uplinkStickyUntil) as? Double, stamp > 0 {
            self.uplinkStickyUntil = Date(timeIntervalSince1970: stamp)
        } else {
            self.uplinkStickyUntil = nil
        }
        self.uplinkLastGoodTier = defaults.string(forKey: Key.uplinkLastGoodTier)
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
