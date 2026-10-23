import Foundation

/// 降级到 iroh 时的**配对编排**。
///
/// 设计上只承认一件事：**一个 uplink 同时负责 lan / 虚拟组网 / iroh**。
/// 用户粘一次配对串就该全部搞定，不该再为 iroh 单独「添加电脑」。
///
/// 两条路，按"码从哪来"分：
///   1. **配对串里带的码**（`iroh.code` + `iroh.expiresAt`）—— 这是主路。
///      配对走 iroh 通道本身，**不需要任何 HTTP 请求**，所以 5G + 局域网不可达也能成。
///      这正是死锁的修法：iroh 是"所有网关档都不可达"时的兜底，它不能反过来依赖网关。
///   2. **`POST /uplink/iroh-pairing` 刷新**（要票）—— 只在"某个网关档可达、
///      但手上的码已经用过/过期"时才有意义。没有票就是做不到，如实报错。
///
/// 为什么把决策抽成一个只有两个闭包的纯编排：真机上"连一次 iroh"要几秒、还要一台
/// 真电脑；而这里最容易写错的是**决策**（什么时候再连一次、什么时候必须停手），
/// 决策完全可以离线测（见 `UplinkTests` 的 `testIrohFallback…`）。
@MainActor
public enum UplinkIrohFallback {
    /// 一次 `tether.connect` 的结果。
    public enum Attempt: Equatable, Sendable {
        case connected
        /// 这台电脑不认识我们（没有配对记录）—— 需要配对码。
        case needsPairing(String)
        /// 带了码但被拒（窗口过期 / 码不对 / 错太多次）—— **同一个码再试没用**。
        case codeRejected(String)
        /// 别的失败（超时、代理起不来、控制流断了……）—— 换码也没用。
        case failed(String)
    }

    /// 整个流程的结果。
    public enum Outcome: Equatable, Sendable {
        case connected
        /// 用一句话如实报告（调用方直接拿它当 `connection.failed` 的文案）。
        case failed(String)
        /// 配对串里的码已经过期、网关又不可达 —— 用户必须回电脑上重新生成配对串。
        case pairingCodeExpired
        /// 需要配对码，但手上没有可用票据（网关档全不可达）—— 刷新这条路走不通。
        case needsPairingWithoutTicket
        /// 电脑端没跑 iroh 档（503）。
        case unavailable
    }

    /// 跑一次兜底。
    ///
    /// - Parameters:
    ///   - endpointId: 配对串给的 endpointId（没有时才退回上次配对的身份）。
    ///   - pairingCode: 配对串里带的码；`nil` 表示没有（老配对串，或已用掉）。
    ///   - connect: 真正去连 `(hostId, pairingCode?)`。
    ///   - requestPairing: 用当前票据刷新一张配对窗口（只在网关可达时可用）。
    public static func run(
        endpointId: String,
        pairingCode: String?,
        connect: (String, String?) async -> Attempt,
        requestPairing: () async -> Result<UplinkIrohPairing, UplinkIrohPairingError>
    ) async -> Outcome {
        switch await connect(endpointId, pairingCode) {
        case .connected:
            return .connected
        case .failed(let message):
            // 网络类失败：换配对码也连不上，**别去骚扰电脑端**（它对失败有限流）。
            return .failed(message)
        case .needsPairing, .codeRejected:
            // 两条都归结成"手上这个码不能用 / 没有码"，走同一条补救逻辑。
            return await refresh(
                hadCode: pairingCode != nil,
                connect: connect,
                requestPairing: requestPairing
            )
        }
    }

    /// 没有可用的码时的补救：能刷新就刷新一次，不能刷新就如实说清楚。
    private static func refresh(
        hadCode: Bool,
        connect: (String, String?) async -> Attempt,
        requestPairing: () async -> Result<UplinkIrohPairing, UplinkIrohPairingError>
    ) async -> Outcome {
        switch await requestPairing() {
        case .success(let issued):
            switch await connect(issued.endpointId, issued.code) {
            case .connected:
                return .connected
            case .needsPairing(let message), .codeRejected(let message):
                // 刚换来的码还不认：再换只会撞上"错太多次"，停手。
                return .failed(message)
            case .failed(let message):
                return .failed(message)
            }
        case .failure(.unavailable):
            return .unavailable
        case .failure(.noTicket):
            // 关键分支：**串里带了码却被拒**说明那个码过期了，用户只能回电脑重配；
            // 从来没带过码（老配对串）才是"需要配对但没有票"。
            return hadCode ? .pairingCodeExpired : .needsPairingWithoutTicket
        case .failure(.failed(let message)):
            return .failed(message)
        }
    }
}

/// iroh 兜底在"网关探测结束之后"该怎么处理。
///
/// 这是 0.5.3 的产品决策，单独写成一个纯函数是因为它**最容易在改代码时被顺手改坏**：
///   · 网关有档可达 → **推迟**配对（手上有票，晚点要码也不迟），后台预热即可；
///   · 网关全不可达 → **立刻**用配对串里的码配（这是唯一不需要 HTTP 的路径，
///     也是当初修死锁的原因：iroh 不能反过来依赖网关）。
public enum UplinkIrohPlan: Equatable, Sendable {
    /// 网关通了：后台趁有票把兜底配好（用 `pairOnly`，不动当前传输）。
    case prewarm
    /// 网关全不通：立刻用配对串里的码配 + 连（`fallbackToIroh` 会做）。
    case pairNow
    /// 什么都不用做（已经配过 / 没有 endpoint / 没有码）。
    case none

    public static func resolve(
        gatewayReachable: Bool,
        irohAlreadyPaired: Bool,
        hasIrohEndpoint: Bool,
        hasPairingCode: Bool
    ) -> UplinkIrohPlan {
        guard hasIrohEndpoint, !irohAlreadyPaired else { return .none }
        if gatewayReachable { return .prewarm }
        return hasPairingCode ? .pairNow : .none
    }
}

/// 单飞：并发调用合并成一次。
///
/// 为什么需要：真机日志 `iroh 配对失败：上一次连接还在进行中` 就是两条路
/// （adopt / 回前台 / 降级）同时想配 iroh 撞出来的。合并之后，第二条直接复用
/// 第一条的结果，不会再打第二条 `connect`。
@MainActor
public final class SingleFlight<Value: Sendable> {
    private var task: Task<Value, Never>?

    public init() {}

    /// 正在跑就复用；否则用 `operation` 起一个新的。
    public func run(_ operation: @escaping @MainActor () async -> Value) async -> Value {
        if let task {
            return await task.value
        }
        let task = Task { @MainActor in await operation() }
        self.task = task
        let value = await task.value
        self.task = nil
        return value
    }

    /// 有没有正在跑的任务（调用方要"先等它落定再决定"时用）。
    public var isRunning: Bool { task != nil }

    /// 等正在跑的那次落定（没有就立刻返回）。
    public func drain() async {
        guard let task else { return }
        _ = await task.value
    }
}
