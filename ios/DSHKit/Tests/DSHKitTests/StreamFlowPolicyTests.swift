import XCTest

@testable import DSHKit

/// `StreamFlowPolicy` 的决策表全覆盖（T1：流帧处置从 App 层抽成纯函数后钉住）。
final class StreamFlowPolicyTests: XCTestCase {
    private func frame(_ json: String) -> AssistantStreamFrame {
        AssistantStreamFrame.decode(Fixture.json(json))
    }

    private let start = #"{"type":"start","attemptId":"a1","startedAfterSeq":3,"turn":1,"step":1}"#
    private let chunk = #"{"type":"chunk","attemptId":"a1","index":0,"time":1791777000000,"chunk":{"type":"text-delta","index":0,"text":"你"}}"#
    private let end = #"{"type":"end","attemptId":"a1","index":1,"outcome":{"type":"completed"}}"#
    private let unknown = #"{"type":"mystery-frame","attemptId":"a1"}"#

    // MARK: start —— 无条件亮灯，但空 delta 不发布

    func testStartLightsStreamingEvenWithEmptyDelta() {
        let decision = StreamFlowPolicy.decide(frame: frame(start), isStreaming: false, deltaIsEmpty: true)
        XCTAssertTrue(decision.isStreaming)
        XCTAssertEqual(decision.publish, .none)
    }

    func testStartWithContentPublishesCoalesced() {
        let decision = StreamFlowPolicy.decide(frame: frame(start), isStreaming: false, deltaIsEmpty: false)
        XCTAssertTrue(decision.isStreaming)
        XCTAssertEqual(decision.publish, .coalesced)
    }

    // MARK: chunk —— 只在真的产生内容时亮灯、才发布

    func testChunkWithEmptyDeltaDoesNothing() {
        // 没内容时不亮灯（避免"流式中"的假阳性）
        let idle = StreamFlowPolicy.decide(frame: frame(chunk), isStreaming: false, deltaIsEmpty: true)
        XCTAssertFalse(idle.isStreaming)
        XCTAssertEqual(idle.publish, .none)
        // 已经在流式中的也别把灯碰灭
        let live = StreamFlowPolicy.decide(frame: frame(chunk), isStreaming: true, deltaIsEmpty: true)
        XCTAssertTrue(live.isStreaming)
        XCTAssertEqual(live.publish, .none)
    }

    func testChunkWithContentLightsAndCoalesces() {
        let decision = StreamFlowPolicy.decide(frame: frame(chunk), isStreaming: false, deltaIsEmpty: false)
        XCTAssertTrue(decision.isStreaming)
        XCTAssertEqual(decision.publish, .coalesced)
    }

    // MARK: end —— 无条件灭灯；有内容必须立刻落屏

    func testEndWithContentPublishesImmediately() {
        let decision = StreamFlowPolicy.decide(frame: frame(end), isStreaming: true, deltaIsEmpty: false)
        XCTAssertFalse(decision.isStreaming)
        XCTAssertEqual(decision.publish, .immediate,
                       "收尾必须立刻发布，否则最后一段文字会晚一帧")
    }

    func testEndWithEmptyDeltaJustStopsStreaming() {
        let decision = StreamFlowPolicy.decide(frame: frame(end), isStreaming: true, deltaIsEmpty: true)
        XCTAssertFalse(decision.isStreaming)
        XCTAssertEqual(decision.publish, .none,
                       "空收尾不触发发布，也不该取消挂在窗口里的待发任务")
    }

    // MARK: unknown —— 不动流式标志，有内容就合帧（诊断页要看）

    func testUnknownFrameKeepsStreamingFlag() {
        XCTAssertTrue(StreamFlowPolicy.decide(frame: frame(unknown), isStreaming: true, deltaIsEmpty: true).isStreaming)
        XCTAssertFalse(StreamFlowPolicy.decide(frame: frame(unknown), isStreaming: false, deltaIsEmpty: true).isStreaming)
    }

    func testUnknownFrameWithContentCoalesces() {
        let decision = StreamFlowPolicy.decide(frame: frame(unknown), isStreaming: true, deltaIsEmpty: false)
        XCTAssertEqual(decision.publish, .coalesced)
    }
}
