import Foundation

/// 界面上的连接状态。
///
/// 为什么它是个**纯值类型 + 单向迁移规则**，而不是散在 `AppModel` 里的一堆赋值：
///
/// 这里的坑全是时序坑。传输层（TetherKit）会在自己的 actor 里把状态切到
/// `.connected` 并广播，而 `AppModel.connect()` 是另一条会写这块状态的路径。
/// 两者交错时，一条**迟到的、过时的**写入会把已经正确的状态打回去 ——
/// 真机复现过两次（F7、以及 2026-10-19「明明已经连接上了却一直显示连接中」）：
///
///   · `connect()` 无条件写 `.connecting`，而 `.connected` 只广播一次；
///   · 广播那一次恰好落在写入之前，于是就再也没有事件把界面救回来。
///
/// 所以写入统一走 `advanced(to:)`：**只允许朝"更连接"的方向走**，
/// 迟到的 `.connecting` 打不回 `.connected`。规则本身是纯函数，可单测。
public enum ConnectionPhase: Equatable, Sendable {
    case idle
    case connecting(hostId: String)
    case connected(mode: String)
    case failed(String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    /// 是否处于"正在建立连接"。
    public var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }

    /// 按"单向推进"的规则接受新状态。
    ///
    /// 唯一被忽略的是**迟到的 `.connecting`**：它打不回已经连上的状态。
    /// 其它一律接受 —— 真实掉线由传输层的 `.failed` 报到，那时 `link` 已被
    /// `teardown()` 置空，状态不可能是 `.connected`；若为了防迟到回调而忽略
    /// `.failed`，真正掉线就再也降不下来了。
    public func advanced(to next: ConnectionPhase) -> ConnectionPhase {
        if next == self { return self }
        if case .connecting = next, isConnected { return self }
        return next
    }
}
