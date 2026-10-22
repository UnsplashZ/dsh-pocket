import DSHKit
import Foundation
import TetherKit

/// 给 DSHKit 用的"电脑在哪"。
///
/// 所有模式在协议层看来完全一样（ADR-0009）：**一个 baseURL + 一个鉴权头**。
///   · **DEV-DIRECT**（DEBUG）：直连 Mac 上注入 cookie 的 dev 代理，固定基址；
///   · **REL-REMOTE**：TetherKit 连上电脑后派生的本地代理端口；
///   · **UPLINK**（多路接入）：`UplinkSession` 探测选出的网关地址 + 票据。
///
/// 这个类型是唯一知道"现在是哪种模式"的地方 —— 协议层与界面都不需要知道。
/// 也正因为如此，加一个档位**不需要动 DSHKit / MuxClient / SessionModel 一行**。
@MainActor
public final class HostCoordinator: DSHHostProvider, @unchecked Sendable {
    private let settings: AppSettings
    private let session: TetherSession
    private let uplink: UplinkSession?

    /// 由 `AppModel` 在连接成功后写入（iroh 路径 / 多路接入降级后也用它）。
    private var remoteBaseURL: URL?
    /// 多路接入探测成功后写入。**单独一列**，因为降级到 iroh 时
    /// 它必须能被清掉 —— 否则票据会跟着 iroh 的本地代理一起发出去。
    private var uplinkBaseURL: URL?

    public init(settings: AppSettings, session: TetherSession, uplink: UplinkSession? = nil) {
        self.settings = settings
        self.session = session
        self.uplink = uplink
    }

    /// 当前模式的人类可读名字，诊断页与顶栏状态用。
    public enum Mode: Sendable, Equatable {
        case devDirect(String)
        case directGateway(String)
        /// 多路接入。`kind` 是当前档位（`lan` / `tailscale` / `zerotier` / `frp`），
        /// 空串表示还没探到（诊断页据此显示"未选档"）。
        case uplink(kind: String)
        case remote(hostId: String)

        public var label: String {
            switch self {
            case .devDirect: return String(localized: "开发直连")
            case .directGateway: return String(localized: "直连网关")
            case .uplink: return String(localized: "多路接入")
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
        case .uplink:
            return .uplink(kind: uplink?.currentTier?.kind.rawValue ?? "")
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

    /// 多路接入的基址。传 `nil` 表示"这一档不成立了"（降级到 iroh 或断开时）。
    func setUplinkBaseURL(_ url: URL?) {
        uplinkBaseURL = url
    }

    var currentRemoteBaseURL: URL? { remoteBaseURL }
    var currentUplinkBaseURL: URL? { uplinkBaseURL }

    /// 多路接入当前实际用的基址。**只认 AppModel 写的那份**。
    ///
    /// 不退回 `uplink.baseURL` 是有意的：那份是探测结果，降级到 iroh 时
    /// AppModel 会清掉 `uplinkBaseURL`，但会话里那份可能还留着 ——
    /// 两处都读，就等于给"降级之后还在往 uplink 地址发请求"留了个口子。
    private var uplinkURL: URL? { uplinkBaseURL }

    // MARK: DSHHostProvider

    public nonisolated func baseURL() async throws -> URL {
        try await MainActor.run {
            switch settings.transportMode {
            case .devDirect, .directGateway:
                guard let url = gatewayBaseURL else { throw DSHTransportError.notConnected }
                return url
            case .uplink:
                // 降级到 iroh 时 AppModel 会把 uplinkBaseURL 清掉、改写成 remoteBaseURL，
                // 所以这里"落到 remoteBaseURL"正好接上原来 `.remote` 的那条路。
                guard let url = uplinkURL ?? remoteBaseURL else {
                    throw DSHTransportError.notConnected
                }
                return url
            case .remote:
                guard let remoteBaseURL else { throw DSHTransportError.notConnected }
                return remoteBaseURL
            }
        }
    }

    public nonisolated func requestHeaders() async -> [String: String] {
        // 多路接入要 `await` 换票，塞不进 `MainActor.run` 的同步闭包，
        // 所以先把这个模式单独问一句，再回到主 actor 上取头。
        let isUplink = await MainActor.run { settings.transportMode == .uplink }
        if isUplink { return await uplinkHeaders() }
        return await MainActor.run {
            guard settings.transportMode == .directGateway else { return [:] }
            let token = settings.gatewayToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return [:] }
            return ["Authorization": "Bearer \(token)"]
        }
    }

    /// 多路接入的鉴权头。
    ///
    /// **只有"确实在用 uplink 网关"时才带票**：降级到 iroh 之后
    /// `uplinkBaseURL` 已经是 nil，这里返回空字典 ——
    /// 票据绝不能跟着 iroh 的本地代理一起发出去（那是另一条信任边界）。
    private func uplinkHeaders() async -> [String: String] {
        guard uplinkBaseURL != nil, let uplink else { return [:] }
        return await uplink.headersRefreshingIfNeeded()
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
            case .uplink:
                return uplinkURL != nil || remoteBaseURL != nil
            case .remote:
                return remoteBaseURL != nil
            }
        }
    }
}
