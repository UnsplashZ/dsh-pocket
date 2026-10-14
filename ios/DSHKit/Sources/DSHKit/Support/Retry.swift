import Foundation

/// 重试策略：与 DSH 官方客户端一致 —— 指数退避 500ms 起、10s 封顶、带抖动。
///
/// **只重试"看来还会变好"的失败**：连接类错误、5xx、超时。业务错误
/// （`DSHClientError.remote`）与 4xx 一律不重试 —— 重试一个被描述符拒绝的
/// 参数只会得到同样的拒绝。
public struct RetryPolicy: Sendable {
    public var maxAttempts: Int
    public var baseDelay: Duration
    public var maxDelay: Duration
    public var jitter: Double

    public init(
        maxAttempts: Int = 4,
        baseDelay: Duration = .milliseconds(500),
        maxDelay: Duration = .seconds(10),
        jitter: Double = 0.25
    ) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.jitter = jitter
    }

    public static let `default` = RetryPolicy()

    /// 不重试：给"用户手动点的动作"用（他自己的重试比自动重试更符合预期）。
    public static let none = RetryPolicy(maxAttempts: 1)

    /// 计算第 `attempt` 次失败后应等待的时长（attempt 从 1 开始）。
    public func delay(afterAttempt attempt: Int) -> Duration {
        let exponent = max(0, attempt - 1)
        let raw = baseDelay.seconds * pow(2, Double(exponent))
        let capped = min(raw, maxDelay.seconds)
        let factor = 1 + Double.random(in: -jitter...jitter)
        return .seconds(max(0.1, capped * factor))
    }

    /// 这次失败值得重试吗？
    public func shouldRetry(_ error: any Error) -> Bool {
        guard let error = error as? DSHClientError else { return false }
        switch error {
        case .remote:
            return false
        case .transport(let transport):
            switch transport {
            case .notConnected, .socketClosed, .cancelled:
                return false
            case .http(let status, _):
                return status >= 500
            case .malformedResponse, .underlying:
                return true
            case .streamFailed:
                return false
            }
        }
    }
}

/// 跑一个可重试的操作。
public func withRetry<T>(
    _ policy: RetryPolicy,
    logger: (any DSHLogSink)? = nil,
    operation: () async throws -> T
) async throws -> T {
    var attempt = 1
    while true {
        do {
            return try await operation()
        } catch {
            guard attempt < policy.maxAttempts, policy.shouldRetry(error) else { throw error }
            let wait = policy.delay(afterAttempt: attempt)
            logger?.log(.info, "重试第 \(attempt + 1) 次，等待 \(wait.formatted)")
            try await Task.sleep(for: wait)
            attempt += 1
        }
    }
}

extension Duration {
    /// `Duration` → 秒（Double）。
    public var seconds: Double {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    /// 人读格式，日志用。
    public var formatted: String {
        let value = seconds
        if value < 1 { return "\(Int((value * 1000).rounded()))ms" }
        return String(format: "%.1fs", value)
    }
}
