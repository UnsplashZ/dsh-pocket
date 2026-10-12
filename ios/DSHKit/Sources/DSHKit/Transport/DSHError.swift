import Foundation

/// DSH 协议错误。`code` 是宿主给的稳定标识（`RemoteError.code`），
/// 客户端**按 code 分支**，永远不要按 message 分支。
public struct DSHError: Error, Sendable, Equatable {
    public let code: String
    public let message: String
    public let details: JSONValue

    public init(code: String, message: String, details: JSONValue = .object([:])) {
        self.code = code
        self.message = message
        self.details = details
    }

    /// 事件应答被宿主拒绝时的形状（`parseRemoteEventRejection`）。
    public init(rejection: JSONValue) {
        self.code = rejection.string("code") ?? rejection.string("name") ?? "remote/rejected"
        self.message = rejection.string("message") ?? "远端拒绝了这次应答"
        self.details = rejection["details"] ?? .object([:])
    }

    public var localizedDescription: String { message }
}

extension DSHError: LocalizedError {
    public var errorDescription: String? { message }
}

/// 客户端本地的传输/解析失败（与宿主业务错误区分开：这类错误通常可重试）。
public enum DSHTransportError: Error, Sendable, Equatable {
    /// HTTP 状态码非 200（路由不认识、未认证、被栅栏拒绝）。
    case http(status: Int, body: String)
    /// 响应不是合法 JSON，或信封不符合 `server-response`。
    case malformedResponse(String)
    /// 连接未就绪（还没配对 / 代理没起来 / 正在重连）。
    case notConnected
    /// WebSocket 断开。
    case socketClosed(reason: String)
    /// 流被宿主以 `error` 帧终止。
    case streamFailed(DSHError)
    /// 请求被取消。
    case cancelled
    /// 其它（超时、DNS、TLS…）。
    case underlying(String)
}

extension DSHTransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .http(let status, let body):
            return "宿主返回 HTTP \(status)\(body.isEmpty ? "" : "：\(body.prefix(200))")"
        case .malformedResponse(let detail):
            return "宿主响应无法解析：\(detail)"
        case .notConnected:
            return "尚未连接到电脑"
        case .socketClosed(let reason):
            return "连接已断开：\(reason)"
        case .streamFailed(let error):
            return "流出错：\(error.message)"
        case .cancelled:
            return "请求已取消"
        case .underlying(let detail):
            return detail
        }
    }
}

/// 统一的失败包装：调用方只需要 catch 一种。
public enum DSHClientError: Error, Sendable {
    case remote(DSHError)
    case transport(DSHTransportError)

    /// 给 UI 直接展示的一句话。
    public var displayMessage: String {
        switch self {
        case .remote(let error): return error.message
        case .transport(let error): return error.errorDescription ?? "未知错误"
        }
    }

    /// 给 UI 用的稳定分类，避免把 message 当逻辑用。
    public var kind: Kind {
        switch self {
        case .remote(let error):
            if error.code.contains("unauthorized") || error.code.contains("auth") { return .unauthorized }
            if error.code.contains("not-found") || error.code.contains("unknown") { return .notFound }
            if error.code.contains("conflict") { return .conflict }
            return .remote
        case .transport(let error):
            switch error {
            case .notConnected, .socketClosed: return .disconnected
            case .http(let status, _) where status == 401 || status == 403: return .unauthorized
            case .cancelled: return .cancelled
            default: return .transport
            }
        }
    }

    public enum Kind: Sendable {
        case unauthorized
        case notFound
        case conflict
        case remote
        case disconnected
        case cancelled
        case transport
    }
}

extension DSHClientError: LocalizedError {
    public var errorDescription: String? { displayMessage }
}
