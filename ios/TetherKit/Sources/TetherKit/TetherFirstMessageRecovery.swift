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
        let lowered = detailText(error).lowercased()
        guard lowered.contains("protocol") else { return false }
        return lowered.contains("error_code: 1")
            || lowered.contains("error_code:1")
            || lowered.contains("applicationclosed")
            || lowered.contains("application closed")
    }

    /// 瞬时错误：iroh 的 `ConnectionLost(Reset)`。
    ///
    /// 和 `protocol` **完全不是一回事**，日志与处理都必须分开：
    ///   · `protocol` = 我们"是否已配对"的判断错了 → 重试前必须**换首行**；
    ///   · `Reset`    = 对端刚重启 / 中继抖了一下 → 首行不变，等 500ms 再来一次。
    public static func isTransientReset(_ error: Error) -> Bool {
        let text = detailText(error).lowercased()
        guard text.contains("reset") else { return false }
        // `protocol` 优先：它是状态不一致，走取反那条路。
        return !text.contains("protocol")
    }

    /// 从错误里抠出可判别的文本。iroh 的 FFI 错误没有结构化字段，只能读文案。
    private static func detailText(_ error: Error) -> String {
        if let tetherError = error as? TetherError, case .transport(let detail) = tetherError {
            return detail
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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

    /// 跑一次，最多自愈两次（**每类各一次，互不叠加**）：
    ///
    ///   1. `protocol` → 取反首行重试（状态不一致）；
    ///   2. `Reset` → 等 500ms 用同一个首行重试（瞬时抖动）。
    ///
    /// 为什么是"各一次"而不是"各三次"：电脑端对失败有次数限制，而且
    /// 两台设备都判错时来回翻只会一直撞同一个错误。宁可如实报错让用户重配。
    public static func run<T>(
        first: TetherFirstMessage,
        pairingCode: String?,
        retryDelay: Duration = .milliseconds(500),
        attempt: (TetherFirstMessage) async throws -> T
    ) async throws -> (value: T, used: TetherFirstMessage) {
        var used = first
        var didFlip = false
        var didRetryTransient = false
        while true {
            do {
                return (try await attempt(used), used)
            } catch {
                if isProtocolMismatch(error), !didFlip {
                    guard let next = flipped(used, pairingCode: pairingCode) else {
                        // 没有码可翻：如实告诉上层"需要配对码"，而不是把一句 iroh 的
                        // 协议错误抛上去（上层据此决定要不要去要码 / 提示重新生成配对串）。
                        throw TetherError.notPaired
                    }
                    used = next
                    didFlip = true
                    continue
                }
                if isTransientReset(error), !didRetryTransient {
                    didRetryTransient = true
                    try? await Task.sleep(for: retryDelay)
                    continue
                }
                throw error
            }
        }
    }
}
