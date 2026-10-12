import Foundation

/// 协议层唯一需要知道的"电脑在哪"。
///
/// DSHKit 刻意不认识 iroh：DEV-DIRECT 模式给一个固定的 `http://127.0.0.1:8788`
/// （Mac 上的注入 cookie 的 dev 代理），真机模式给 TetherKit 派生出的本地代理端口。
/// 两种模式在协议层看来完全一样。
public protocol DSHHostProvider: Sendable {
    /// 当前可用的 HTTP 基址。未就绪时抛 `DSHTransportError.notConnected`。
    func baseURL() async throws -> URL
    /// 当前可用的 WS 基址（`ws://` 或 `wss://`）。
    func webSocketURL() async throws -> URL
    /// 主机是否处于"已连接、可以发请求"的状态。
    func isReady() async -> Bool

    /// 每个请求（含 WebSocket 升级）都要带上的额外头。
    ///
    /// 给"直连网关"用：网关会把请求转发给 DSH 并注入会话 cookie，
    /// 它自己用 `Authorization: Bearer <token>` 做第二道门。
    /// 默认没有额外头 —— iroh 路径靠端到端加密与配对白名单，不需要令牌。
    func requestHeaders() async -> [String: String]
}

extension DSHHostProvider {
    public func requestHeaders() async -> [String: String] { [:] }
}

/// URL 拼接小工具。放在具名命名空间里，这样 `(any DSHHostProvider).Type`
/// 也可以用（存在类型的静态成员是调不到的）。
public enum DSHAPI {
    /// 把一个 base URL 拼成 `<base>/api/<method>`。
    ///
    /// `api` 前缀是硬要求：DSH 的 `/api` 才是 RPC 面，`/session/list` 会落到 SPA 的
    /// 回退路由上，返回一段 HTML 而不是 JSON。
    public static func url(base: URL, method: String) -> URL {
        var url = rawURL(base: base, path: "api")
        for segment in method.split(separator: "/") {
            url.appendPathComponent(String(segment))
        }
        return url
    }

    /// 所有逻辑流共用的那一条 WebSocket 路由。
    public static let remoteMuxPath = "api/remote.mux"

    /// `/api/session/uploadFileBinary` 这类非 RPC 路由。
    public static func remoteMux(base: URL) -> URL {
        rawURL(base: base, path: remoteMuxPath)
    }

    public static func rawURL(base: URL, path: String) -> URL {
        var url = base
        for segment in path.split(separator: "/") {
            url.appendPathComponent(String(segment))
        }
        return url
    }
}

/// 固定基址：DEV-DIRECT 与单元测试用。
public struct StaticHostProvider: DSHHostProvider {
    private let base: URL
    private let socket: URL
    private let ready: Bool

    public init(base: URL, ready: Bool = true) {
        self.base = base
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.scheme = (base.scheme == "https") ? "wss" : "ws"
        self.socket = components.url ?? base
        self.ready = ready
    }

    public func baseURL() async throws -> URL {
        guard ready else { throw DSHTransportError.notConnected }
        return base
    }

    public func webSocketURL() async throws -> URL {
        guard ready else { throw DSHTransportError.notConnected }
        return socket
    }

    public func isReady() async -> Bool { ready }
}
