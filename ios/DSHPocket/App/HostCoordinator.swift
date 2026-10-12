import DSHKit
import Foundation
import TetherKit

/// 给 DSHKit 用的"电脑在哪"。
///
/// 两种模式在协议层看来完全一样（ADR-0009）：
///   · **DEV-DIRECT**（DEBUG）：直连 Mac 上注入 cookie 的 dev 代理，固定基址；
///   · **REL-REMOTE**：TetherKit 连上电脑后派生的本地代理端口。
///
/// 这个类型是唯一知道"现在是哪种模式"的地方 —— 协议层与界面都不需要知道。
@MainActor
public final class HostCoordinator: DSHHostProvider, @unchecked Sendable {
    private let settings: AppSettings
    private let session: TetherSession

    /// 由 `AppModel` 在连接成功后写入。
    private var remoteBaseURL: URL?

    public init(settings: AppSettings, session: TetherSession) {
        self.settings = settings
        self.session = session
    }

    /// 当前模式的人类可读名字，诊断页与顶栏状态用。
    public enum Mode: Sendable, Equatable {
        case devDirect(String)
        case directGateway(String)
        case remote(hostId: String)

        public var label: String {
            switch self {
            case .devDirect: return String(localized: "开发直连")
            case .directGateway: return String(localized: "直连网关")
            case .remote: return String(localized: "远端连接")
            }
        }
    }

    public var mode: Mode {
        switch settings.transportMode {
        case .devDirect:
            return .devDirect(settings.devDirectBaseURL)
        case .directGateway:
            return .directGateway(settings.gatewayURL)
        case .remote:
            return .remote(hostId: settings.activeHostId ?? "")
        }
    }

    /// 直连网关（DEV-DIRECT 与 Tailscale/局域网共用）的基址。
    private var gatewayBaseURL: URL? {
        let raw = settings.transportMode == .devDirect ? settings.devDirectBaseURL : settings.gatewayURL
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // 容忍用户只填了 `100.64.0.1:8788`（没写 scheme）——默认 http。
        if trimmed.contains("://") { return URL(string: trimmed) }
        return URL(string: "http://\(trimmed)")
    }

    func setRemoteBaseURL(_ url: URL?) {
        remoteBaseURL = url
    }

    var currentRemoteBaseURL: URL? { remoteBaseURL }

    // MARK: DSHHostProvider

    public nonisolated func baseURL() async throws -> URL {
        try await MainActor.run {
            switch settings.transportMode {
            case .devDirect, .directGateway:
                guard let url = gatewayBaseURL else { throw DSHTransportError.notConnected }
                return url
            case .remote:
                guard let remoteBaseURL else { throw DSHTransportError.notConnected }
                return remoteBaseURL
            }
        }
    }

    public nonisolated func requestHeaders() async -> [String: String] {
        await MainActor.run {
            guard settings.transportMode == .directGateway else { return [:] }
            let token = settings.gatewayToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return [:] }
            return ["Authorization": "Bearer \(token)"]
        }
    }

    public nonisolated func webSocketURL() async throws -> URL {
        let base = try await baseURL()
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.scheme = (base.scheme == "https") ? "wss" : "ws"
        components.path = ""
        components.query = nil
        guard let socket = components.url else { throw DSHTransportError.notConnected }
        return socket
    }

    public nonisolated func isReady() async -> Bool {
        await MainActor.run {
            switch settings.transportMode {
            case .devDirect, .directGateway:
                return gatewayBaseURL != nil
            case .remote:
                return remoteBaseURL != nil
            }
        }
    }
}
