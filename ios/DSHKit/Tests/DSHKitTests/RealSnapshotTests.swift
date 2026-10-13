import XCTest
@testable import DSHKit

/// 用**真实抓下来的会话快照**跑分组。
///
/// 手写的 fixture 很容易漏掉真实事件序列里的东西（`agent/inbox/spliced`、
/// `system/message`、`surfaceOp`…），而 bug 恰恰藏在那些地方。
/// 样本在 `docs/artifacts/samples/`，是 M0 阶段真机抓的。
final class RealSnapshotTests: XCTestCase {
    private func loadSnapshot(_ name: String) throws -> SessionSnapshot {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DSHKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // DSHKit
            .deletingLastPathComponent()   // ios
            .deletingLastPathComponent()   // repo
        let url = root.appendingPathComponent("docs/artifacts/samples/\(name).follow.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("样本不在：\(url.path)")
        }
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONDecoder().decode(JSONValue.self, from: data),
                  object.string("type") == "item",
                  object["value"]?.string("type") == "snapshot"
            else { continue }
            // 复用**生产路径**的解析，别在测试里另写一套 —— 那样测的就不是真代码了。
            return try SessionSnapshot.decode(object["value"] ?? .object([:]))
        }
        throw XCTSkip("样本里没有快照帧")
    }

    /// 真机抓的一段会话：**消息先进队列、队列被消费、真正的 `user/message`
    /// 再接管那条队列项**。这个交接过程踩过两个坑（都在这里钉住）：
    ///   1. 接管时继承了队列项的 `isShadowed = true` → 用户的提示词整条消失；
    ///   2. 接管时只就地改了 `seq` 没重新入位 → 条目还留在 `turn/start` 之前，
    ///      轮次分组把它当轮次外的条目，摘要上面出不来。
    func testQueuedTakeoverKeepsThePromptVisibleAndInsideItsTurn() throws {
        let snapshot = try loadSnapshot("session-57d6a0d5-queued-takeover")
        var builder = TimelineBuilder()
        _ = builder.apply(snapshot: snapshot)

        let durable = builder.items.filter { item in
            guard case .userMessage(let message) = item.kind else { return false }
            return !message.isPending
        }
        XCTAssertFalse(durable.isEmpty, "样本里应当有真人消息")
        XCTAssertTrue(durable.allSatisfy { !$0.isShadowed }, "一条都不该被标成已隐藏")
        XCTAssertTrue(durable.allSatisfy(\.isConversational), "而且都要能渲染出来")

        let turns = builder.timelineBlocks().compactMap { block -> TimelineTurn? in
            guard case .turn(let turn) = block else { return nil }
            return turn
        }
        XCTAssertFalse(turns.isEmpty, "样本里应当有轮次")
        let pinnedTotal = turns.reduce(0) { $0 + $1.pinned.count }
        XCTAssertEqual(pinnedTotal, durable.count,
                       "每条真人消息都要落在某个轮次的 pinned 里（否则摘要上面看不到自己的话）")
    }

    func testRealSnapshotKeepsUserPromptsOutOfTheFold() throws {
        let snapshot = try loadSnapshot("session-5a689d90-2dff-4f42-810f-f10ea25939a5")
        var builder = TimelineBuilder()
        _ = builder.apply(snapshot: snapshot)

        let userTexts = builder.items.compactMap { item -> String? in
            guard case .userMessage(let message) = item.kind else { return nil }
            return message.text
        }
        XCTAssertFalse(userTexts.isEmpty, "样本里应当有真人消息")

        let blocks = builder.timelineBlocks()
        let pinnedTexts = blocks.flatMap { block -> [String] in
            guard case .turn(let turn) = block else { return [] }
            return turn.pinned.compactMap { item in
                guard case .userMessage(let message) = item.kind else { return nil }
                return message.text
            }
        }
        let collapsedTexts = blocks.flatMap { block -> [String] in
            guard case .turn(let turn) = block else { return [] }
            return turn.collapsible.compactMap { item in
                guard case .userMessage(let message) = item.kind else { return nil }
                return message.text
            }
        }

        print("真人消息共 \(userTexts.count) 条；进轮次的 pinned = \(pinnedTexts.count)；被折进 collapsible 的 = \(collapsedTexts.count)")
        XCTAssertTrue(collapsedTexts.isEmpty, "真人消息一条都不该被折进去，实际折了：\(collapsedTexts)")

        // 落在轮次里的那些必须能在 pinned 里找到
        let inTurn = blocks.compactMap { block -> TimelineTurn? in
            guard case .turn(let turn) = block else { return nil }
            return turn
        }
        for turn in inTurn {
            let folded = turn.items.compactMap { item -> String? in
                guard case .userMessage(let message) = item.kind else { return nil }
                return message.text
            }
            XCTAssertEqual(
                Set(turn.pinned.compactMap { item -> String? in
                    guard case .userMessage(let message) = item.kind else { return nil }
                    return message.text
                }),
                Set(folded),
                "轮次里的每条真人消息都必须进 pinned"
            )
        }
    }
}
