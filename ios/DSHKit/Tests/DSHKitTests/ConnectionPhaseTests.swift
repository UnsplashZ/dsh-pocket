import XCTest
@testable import DSHKit

/// 连接状态的**单向推进**规则。
///
/// 这块逻辑对应两个真机 bug（都是"传输层其实在线、界面永远连接中"）：
///   · F7：早前排队的自动重连迟醒，`connect()` 无条件写「连接中」；
///   · 2026-10-19：`.connected` 广播恰好落在 `connect()` 写「连接中」之前，
///     于是那次广播被后来的写入覆盖、再也不会有第二次。
///
/// 取舍说明：只有 `.connecting` 是"可以被安全忽略的迟到状态"。
/// `.failed` / `.idle` **一律接受** —— 真实掉线由 `TetherSession.noteLinkClosed`
/// 触发，那时 `link` 已被 `teardown()` 置空，状态不会是 `.connected`；
/// 反过来若为了防迟到回调而忽略 `.failed`，真正掉线就再也降不下来了。
final class ConnectionPhaseTests: XCTestCase {
    /// 核心断言：迟到的「连接中」打不回已经连上的状态。
    func testLateConnectingDoesNotDowngradeConnected() {
        let connected = ConnectionPhase.connected(mode: "远端连接")
        XCTAssertEqual(connected.advanced(to: .connecting(hostId: "host-a")), connected)
    }

    /// 正常前进路径不受影响。
    func testNormalForwardTransitions() {
        XCTAssertEqual(ConnectionPhase.idle.advanced(to: .connecting(hostId: "a")), .connecting(hostId: "a"))
        XCTAssertEqual(
            ConnectionPhase.connecting(hostId: "a").advanced(to: .connected(mode: "远端连接")),
            .connected(mode: "远端连接")
        )
    }

    /// 真实掉线必须能降下来 —— 否则界面会一直显示"已连接"。
    func testFailureAndIdleAreAlwaysAccepted() {
        let connected = ConnectionPhase.connected(mode: "远端连接")
        XCTAssertEqual(connected.advanced(to: .failed("连接断开")), .failed("连接断开"))
        XCTAssertEqual(connected.advanced(to: .idle), .idle)
    }

    /// 失败之后重连的「连接中」要能显示出来，不能卡在失败态。
    func testConnectingAfterFailureIsAccepted() {
        XCTAssertEqual(
            ConnectionPhase.failed("连不上").advanced(to: .connecting(hostId: "a")),
            .connecting(hostId: "a")
        )
    }

    func testPredicates() {
        XCTAssertTrue(ConnectionPhase.connected(mode: "x").isConnected)
        XCTAssertTrue(ConnectionPhase.connecting(hostId: "a").isConnecting)
        XCTAssertFalse(ConnectionPhase.failed("x").isConnected)
        XCTAssertFalse(ConnectionPhase.idle.isConnecting)
    }

    /// 同一状态重复写入是幂等空操作（避免无意义的重绘）。
    func testSameStateIsIdempotent() {
        let phase = ConnectionPhase.connected(mode: "远端连接")
        XCTAssertEqual(phase.advanced(to: phase), phase)
    }
}
