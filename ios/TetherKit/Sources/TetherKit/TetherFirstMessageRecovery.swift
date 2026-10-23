import Foundation

/// 首行策略（`hello` / `pair`）的自愈。
///
/// 电脑端对**已配对**设备只接受 `hello`、对**未配对**设备只接受 `pair` —— 严格二选一，
/// 选错就是 `close(1, "protocol")`。而手机侧"是否已配对"的记录（`hosts.json`，在 App
/// 容器里）与电脑端白名单会不一致，最常见的形状：
///
///   · **重装 App** → `hosts.json` 没了、Keychain 里的 iroh 身份还在 →
///     电脑端仍认识这台手机，手机却以为"没配对"，于是发 `pair` → 协议错误
///     （真机日志：`ConnectionLost(ApplicationClosed(error_code: 1, reason: "protocol"))`）；
///   · 反过来：电脑端清过配对数据，手机却还记着"已配对" → 发 `hello` → 协议错误。
///
/// 处理：收到协议错误就把首行**取反重试一次**。只一次 —— 两边都判错时来回翻会一直撞
/// 同一个错误，而且电脑端对失败有次数限制。
///
/// 为什么单独抽成一个纯类型：这段决策不需要 iroh 就能测（见 `TetherKitTests` 与
/// `DSHPocketTests.UplinkTests` 里的 `testFirstMessage…`），而真机复现要装两台设备。
public enum TetherFirstMessageRecovery {
    /// 日志里怎么称呼这两种首行。**绝不能把配对码打出去**。
    public static func label(_ message: TetherFirstMessage) -> String {
        switch message {
        case .hello: return "hello"
        case .pair: return "pair"
        }
    }

    /// 这个错误是不是"首行选错了"。
    ///
    /// iroh 的关闭原因只能从错误文案里读（FFI 生成的错误类型没有可判别字段），
    /// 实测长这样：`ConnectionLost(ApplicationClosed(error_code: 1, reason: "protocol"))`。
    /// 所以按特征串判 —— 和 `No addressing information available` 那条是同样的取舍：
    /// 宁可多认一种写法，也不要因为 iroh 换了个包装就丢掉自愈能力。
    public static func isProtocolMismatch(_ error: Error) -> Bool {
        let text: String
        if let tetherError = error as? TetherError, case .transport(let detail) = tetherError {
            text = detail
        } else {
            text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        let lowered = text.lowercased()
        guard lowered.contains("protocol") else { return false }
        return lowered.contains("error_code: 1")
            || lowered.contains("error_code:1")
            || lowered.contains("applicationclosed")
            || lowered.contains("application closed")
    }

    /// 取反后的首行；不该翻时返回 nil。
    public static func flipped(
        _ message: TetherFirstMessage,
        pairingCode: String?
    ) -> TetherFirstMessage? {
        switch message {
        case .hello:
            // 电脑端不认识我们（它那边有配对窗口）。只有手上有码才能翻成 pair。
            guard let code = pairingCode, !code.isEmpty else { return nil }
            return .pair(code: code)
        case .pair:
            // 电脑端已经认识我们了 —— 我们自己的"已配对"记录丢了。
            return .hello
        }
    }

    /// 跑一次；遇到协议错误就取反重试一次，返回最终的值与实际用过的首行。
    public static func run<T>(
        first: TetherFirstMessage,
        pairingCode: String?,
        attempt: (TetherFirstMessage) async throws -> T
    ) async throws -> (value: T, used: TetherFirstMessage) {
        do {
            return (try await attempt(first), first)
        } catch {
            guard isProtocolMismatch(error) else { throw error }
            guard let next = flipped(first, pairingCode: pairingCode) else {
                // 没有码可翻：如实告诉上层"需要配对码"，而不是把一句 iroh 的协议错误
                // 抛上去（上层据此决定要不要去要码 / 提示重新生成配对串）。
                throw TetherError.notPaired
            }
            return (try await attempt(next), next)
        }
    }
}
