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
        case remote(hostId: String)

        public var label: String {
            switch self {
            case .devDirect: return String(localized: "开发直连")
            case .remote: return String(localized: "远端连接")
            }
        }
    }

    public var mode: Mode {
        if settings.devDirectEnabled, let url = URL(string: settings.devDirectBaseURL) {
            return .devDirect(url.absoluteString)
        }
        return .remote(hostId: settings.activeHostId ?? "")
    }

    func setRemoteBaseURL(_ url: URL?) {
        remoteBaseURL = url
    }

    var currentRemoteBaseURL: URL? { remoteBaseURL }

    // MARK: DSHHostProvider

    public nonisolated func baseURL() async throws -> URL {
        try await MainActor.run {
            if settings.devDirectEnabled, let url = URL(string: settings.devDirectBaseURL) {
                return url
            }
            guard let remoteBaseURL else { throw DSHTransportError.notConnected }
            return remoteBaseURL
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
            if settings.devDirectEnabled { return true }
            return remoteBaseURL != nil
        }
    }
}
