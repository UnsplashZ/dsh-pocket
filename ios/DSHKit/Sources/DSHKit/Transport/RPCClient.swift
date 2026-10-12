import Foundation

/// Unary RPC：`POST /api/<method>`。
///
/// 三条必须记住的事实（见 docs/PROTOCOL-NOTES.md §4.1）：
///   1. **业务错误也是 HTTP 200** —— 必须判响应体里的 `result.ok`，不能看状态码；
///   2. 只有"路由不认识"才是 404，正文是纯文本 `not found`；
///   3. 参数是具名对象 `{"args":{…}}`，且描述符校验**双向严格**（多余字段会被拒）。
public actor RPCClient {
    private let provider: any DSHHostProvider
    private let session: URLSession
    private let retry: RetryPolicy
    private let logger: any DSHLogSink?

    /// rpcId 由客户端生成并回显；用它把响应与请求配对。
    private var inflight: [String: Task<JSONValue, any Error>] = [:]

    public init(
        provider: any DSHHostProvider,
        session: URLSession = .dshShared,
        retry: RetryPolicy = .default,
        logger: any DSHLogSink? = nil
    ) {
        self.provider = provider
        self.session = session
        self.retry = retry
        self.logger = logger
    }

    /// 调一个 unary 端点。`args` 直接作为 `payload.args` 发出。
    /// - Parameter args: 具名参数对象。无参端点传 `[:]`（DSH 的 `_request` 家法见下）。
    public func call(
        _ method: String,
        args: [String: JSONValue] = [:]
    ) async throws -> JSONValue {
        try await call(method: method, payload: ["args": .object(args)])
    }

    /// 调一个 unary 端点，自己给整个 payload（用于 `{"_request":{}}` 这类位置参数家法）。
    public func call(method: String, payload: [String: JSONValue]) async throws -> JSONValue {
        try await withRetry(retry, logger: logger) { [self] in
            try await perform(method: method, payload: payload)
        }
    }

    private func perform(method: String, payload: [String: JSONValue]) async throws -> JSONValue {
        let base = try await provider.baseURL()
        var request = URLRequest(url: DSHAPI.url(base: base, method: method))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 原生客户端不发 Origin：trust 栅栏要求 Origin 与 Host 同源，
        // 而我们的 authority 是 127.0.0.1:<派生端口>，索性不发（见 PROTOCOL-NOTES §1.2）。
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let rpcId = RpcId.make()
        let envelope: JSONValue = .object([
            "type": .string("client-request"),
            "rpcId": .string(rpcId),
            "method": .string(method),
            "payload": .object(payload),
        ])
        request.httpBody = try JSONEncoder.dshCompact.encode(envelope)

        logger?.log(.debug, "rpc → \(method) \(rpcId)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw DSHClientError.transport(.cancelled)
        } catch {
            logger?.log(.warning, "rpc ✗ \(method)：\(error.localizedDescription)")
            throw DSHClientError.transport(.underlying(error.localizedDescription))
        }

        guard let http = response as? HTTPURLResponse else {
            throw DSHClientError.transport(.malformedResponse("不是 HTTP 响应"))
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            logger?.log(.warning, "rpc ✗ \(method) HTTP \(http.statusCode)")
            throw DSHClientError.transport(.http(status: http.statusCode, body: body))
        }

        let decoded: JSONValue
        do {
            decoded = try JSONDecoder.dsh.decode(JSONValue.self, from: data)
        } catch {
            // 200 但不是 JSON：DSH 的 SPA 回退或代理层故障。
            throw DSHClientError.transport(
                .malformedResponse("响应不是 JSON：\(String(data: data.prefix(120), encoding: .utf8) ?? "")")
            )
        }

        // 信封校验：type 必须是 server-response，rpcId 必须回显。
        guard decoded.string("type") == "server-response" else {
            throw DSHClientError.transport(.malformedResponse("信封 type 不是 server-response"))
        }
        guard let result = decoded["result"]?.objectValue else {
            throw DSHClientError.transport(.malformedResponse("信封缺少 result"))
        }
        guard let ok = result["ok"]?.boolValue else {
            throw DSHClientError.transport(.malformedResponse("result 缺少 ok"))
        }
        if ok {
            logger?.log(.debug, "rpc ✓ \(method) \(rpcId)")
            return result["value"] ?? .null
        }
        let error = result["error"] ?? .null
        let remote = DSHError(
            code: error.string("code") ?? "unknown",
            message: error.string("message") ?? "宿主返回了一个未说明的错误",
            details: error["details"] ?? .object([:])
        )
        logger?.log(.warning, "rpc ✗ \(method)：\(remote.code) \(remote.message)")
        throw DSHClientError.remote(remote)
    }
}

/// RPC 相关的小工具。
public enum RpcId {
    /// `rpc-<时间基36>-<8位随机>`：可排序、够唯一、便于日志里 grep。
    public static func make() -> String {
        let stamp = String(UInt64(Date().timeIntervalSince1970 * 1000), radix: 36)
        let random = String(UInt64.random(in: 0..<UInt64.max), radix: 36).prefix(8)
        return "rpc-\(stamp)-\(random)"
    }
}

extension URLSession {
    /// 移动端网络：给较短的资源超时、允许蜂窝、连接复用交给系统。
    public static let dshShared: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()
}
