import XCTest

@testable import DSHKit

/// `present` 交付的产物（`deliverables/presented`）。
///
/// 这条链路曾经整条是坏的，两个独立的坑叠在一起：
///   1. **解析读错了键**：客户端读 `deliverables` / `items`，而活宿主发的是
///      `files` —— 两个键都不存在，产物卡永远只有一行「产物」标题、下面什么都没有；
///   2. **产物卡跟着轮次一起被折叠**：一轮跑完会收拢成「摘要 + 结论」，
///      产物卡被收进去，时间线上就更看不见了。
/// 用户看到的就是一句话："交付的文件看不到"。
///
/// 这里的形状**逐字段照抄活宿主**（`~/.dsh/sessions/**/session.v4.jsonl.zstd`），
/// 不是拍脑袋编的 —— 协议漂移时这些测试会先红。
final class DeliverablesTests: XCTestCase {
    private func deliverablesItems(in builder: TimelineBuilder) -> [TimelineItem] {
        builder.items.filter { if case .deliverables = $0.kind { return true }; return false }
    }

    private func isDeliverable(_ item: TimelineItem) -> Bool {
        if case .deliverables = item.kind { return true }
        return false
    }

    /// 真实形状：键是 `files`，每项只有 `path` + `description`，**没有 `title`**。
    func testRealFilesShapeIsParsedAndTitleFallsBackToTheFileName() throws {
        var builder = TimelineBuilder()
        _ = builder.apply(try Fixture.event(Fixture.deliverables([
            ("tools/tether-status.mjs", "命令行查看 dsh-plugin-tether 的配对码与连接状态"),
        ], seq: 193)))

        let items = deliverablesItems(in: builder)
        XCTAssertEqual(items.count, 1, "真实形状必须能解析出来（修复前这里是 0 条）")
        guard case .deliverables(let list) = try XCTUnwrap(items.first).kind else { return XCTFail() }
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].title, "tether-status.mjs", "宿主不给 title，用文件名兜底")
        XCTAssertEqual(list[0].path, "tools/tether-status.mjs")
        XCTAssertEqual(list[0].description, "命令行查看 dsh-plugin-tether 的配对码与连接状态")
    }

    /// 多份产物（日报那类场景）+ 绝对路径。
    func testMultipleDeliverablesKeepTheirOrder() throws {
        var builder = TimelineBuilder()
        _ = builder.apply(try Fixture.event(Fixture.deliverables([
            ("/Users/example/out/tech-20261011-am.png", "科技 · 数码日报"),
            ("/Users/example/out/politics-20261011-am.png", "时政要闻日报"),
        ], turn: 2, seq: 292)))

        guard case .deliverables(let list) = try XCTUnwrap(deliverablesItems(in: builder).first).kind else {
            return XCTFail()
        }
        XCTAssertEqual(list.map(\.title), ["tech-20261011-am.png", "politics-20261011-am.png"])
        XCTAssertEqual(list.map(\.description), ["科技 · 数码日报", "时政要闻日报"])
    }

    /// 形状认不出来时**不能丢**：退成一条原始事件（打开"显示模型可见的原始事件"
    /// 能看到完整负载），而不是画一张只有标题的空卡。
    func testUnknownDeliverableShapeFallsBackToRawInsteadOfAnEmptyCard() throws {
        var builder = TimelineBuilder()
        _ = builder.apply(try Fixture.event("""
        {"type":"deliverables/presented","seq":7,"time":1791777001000,"data":{"turn":1,"weird":[{"whatever":1}]}}
        """))

        XCTAssertTrue(deliverablesItems(in: builder).isEmpty, "不该画一张空产物卡")
        let raw = builder.items.first { if case .raw = $0.kind { return true }; return false }
        XCTAssertNotNil(raw, "事件本身要留着，不能悄悄吞掉")
        XCTAssertEqual(raw?.kindName, "deliverables/presented")
        XCTAssertFalse(raw?.isConversational ?? true, "原始事件默认不显示，靠设置页那个开关看")
    }

    /// **交付的产物不能跟着轮次一起收进折叠区。**
    ///
    /// 一轮跑完收拢成「摘要 + 结论」之后，产物卡必须仍然在明面上，
    /// 而且排在结论**后面**：先说"做完了什么"，再说"交付了什么"。
    func testDeliverablesStayVisibleWhenTheTurnCollapses() throws {
        var builder = TimelineBuilder()
        _ = builder.apply(try Fixture.event(Fixture.turnStart(1, seq: 1)))
        _ = builder.apply(try Fixture.event(Fixture.userMessage("帮我做份日报", seq: 2)))
        _ = builder.apply(try Fixture.event(Fixture.assistantMessage(text: "先跑数据", seq: 3)))
        _ = builder.apply(try Fixture.event(Fixture.deliverables([
            ("out/report.md", "今天的完整报告"),
        ], seq: 4)))
        _ = builder.apply(try Fixture.event(Fixture.assistantMessage(text: "做完了，见产物", seq: 5)))
        _ = builder.apply(try Fixture.event(Fixture.turnEnd(1, seq: 6)))

        guard case .turn(let turn) = builder.timelineBlocks().first else { return XCTFail("应当是一个轮次") }
        XCTAssertTrue(turn.isComplete)
        XCTAssertEqual(turn.deliverables.count, 1, "产物要单独挑出来")
        XCTAssertEqual(
            turn.collapsedItems.map(\.kindName),
            ["assistant/message", "deliverables/presented"],
            "收起状态下渲染的应当是：结论 + 产物卡"
        )
        XCTAssertTrue(turn.collapsedItems.contains(where: isDeliverable))
        // 产物**不算**进摘要的「N 步」—— 它没被折叠，只是不参与折叠。
        XCTAssertEqual(turn.collapsedCount, 1, "折叠区里只有那句过场话")
        // 展开之后回到原始时序，产物仍在它本来的位置上。
        XCTAssertEqual(
            turn.expandedItems.map(\.kindName),
            ["assistant/message", "deliverables/presented", "assistant/message"]
        )
        // 用户消息依旧在摘要行上面单独渲染，不被卷进来。
        XCTAssertEqual(turn.pinned.map(\.kindName), ["user/message"])
    }
}
