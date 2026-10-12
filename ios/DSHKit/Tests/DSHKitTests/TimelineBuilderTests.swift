import XCTest

@testable import DSHKit

/// 时间线折叠：协议理解的正确性全靠这里。
final class TimelineBuilderTests: XCTestCase {
    // MARK: 快照折叠

    func testSnapshotFoldsTurnUserAssistantTool() throws {
        var builder = TimelineBuilder()
        let snapshot = try Fixture.snapshot([
            Fixture.turnStart(1, seq: 1),
            Fixture.stepStart(turn: 1, step: 1, seq: 2),
            Fixture.userMessage("帮我看看这个仓库", seq: 3),
            Fixture.assistantMessage(text: "先列一下目录", reasoning: "先看看结构", toolCall: ("call_a", "bash", "{\"command\":\"ls\"}"), seq: 4),
            Fixture.toolCall("call_a", seq: 5),
            Fixture.toolResult("call_a", output: "README.md\ndocs", seq: 6),
            Fixture.stepEnd(turn: 1, step: 1, seq: 7),
            Fixture.turnEnd(1, seq: 8),
        ])
        _ = builder.apply(snapshot: snapshot)

        let items = builder.conversationalItems
        XCTAssertEqual(items.count, 5, "turn 分隔 + 用户 + 助手 + 工具 + turn 结束")

        // 用户消息
        guard case .userMessage(let user) = items[1].kind else { return XCTFail("第 2 条应是用户消息") }
        XCTAssertEqual(user.text, "帮我看看这个仓库")
        XCTAssertEqual(user.rpcId, "rpc-1")
        XCTAssertFalse(user.isPending)

        // 助手消息：reasoning + text 两块，tool-call 块不单独渲染
        guard case .assistantMessage(let assistant) = items[2].kind else { return XCTFail("第 3 条应是助手消息") }
        XCTAssertEqual(assistant.blocks.count, 3, "reasoning + text + tool-call 三块都要保住")
        XCTAssertEqual(assistant.plainText, "先列一下目录")
        XCTAssertEqual(assistant.toolCallIds, ["call_a"])
        XCTAssertEqual(assistant.renderableBlocks.count, 2, "气泡里只画 reasoning 与 text，工具走单独一行")
        XCTAssertFalse(assistant.isStreaming)

        // 工具调用：**只有一条**（tool/call 与 tool/result 合并，且没被助手块重复算一次）
        let toolItems = items.filter { if case .toolCall = $0.kind { return true }; return false }
        XCTAssertEqual(toolItems.count, 1)
        guard case .toolCall(let tool) = toolItems[0].kind else { return XCTFail() }
        XCTAssertEqual(tool.callId, "call_a")
        XCTAssertEqual(tool.name, "bash")
        XCTAssertEqual(tool.status, .success)
        XCTAssertEqual(tool.output, "README.md\ndocs")
        XCTAssertEqual(tool.endedAt, Date(timeIntervalSince1970: 1_791_777_000.9))
        // startedAt 取"助手声明这次调用"的时刻（消息时间 .2s），result 在 .9s → 0.7s
        XCTAssertEqual(tool.endedAt.map { $0.timeIntervalSince(tool.startedAt) } ?? 0, 0.7, accuracy: 0.001)

        // turn 结束原因
        guard case .turnEnd(1, let reason) = items[4].kind else { return XCTFail("最后一条应是 turn 结束") }
        XCTAssertEqual(reason, .completed)
    }

    func testItemsAreOrderedBySeq() throws {
        var builder = TimelineBuilder()
        _ = builder.apply(snapshot: try Fixture.snapshot([
            Fixture.turnStart(1, seq: 1),
            Fixture.userMessage("a", seq: 3),
            Fixture.assistantMessage(text: "b", seq: 4),
            Fixture.turnEnd(1, seq: 9),
        ]))
        let seqs = builder.items.map(\.seq)
        XCTAssertEqual(seqs, seqs.sorted())
    }

    func testDuplicateEventIsUpdatedNotInserted() throws {
        var builder = TimelineBuilder()
        let event = try Fixture.event(Fixture.userMessage("你好", seq: 3))
        _ = builder.apply(event)
        _ = builder.apply(event)
        XCTAssertEqual(builder.items.count, 1, "同 seq 幂等")
    }

    // MARK: surfaceOp

    func testSurfaceReplaceShadowsRange() throws {
        var builder = TimelineBuilder()
        _ = builder.apply(snapshot: try Fixture.snapshot([
            Fixture.turnStart(1, seq: 1),
            Fixture.userMessage("第一轮", seq: 2),
            Fixture.assistantMessage(text: "回答一", seq: 3),
            Fixture.userMessage("第二轮", seq: 4),
            Fixture.assistantMessage(text: "回答二", seq: 5),
        ]))
        XCTAssertEqual(builder.conversationalItems.count, 5)

        // 压缩取代 seq 2…4
        let delta = builder.apply(try Fixture.event(Fixture.compactionSummary(seq: 6, startSeq: 2, endSeq: 4)))

        let shadowed = Set(delta.shadowedIds)
        XCTAssertTrue(shadowed.contains("e2"))
        XCTAssertTrue(shadowed.contains("e3"))
        XCTAssertTrue(shadowed.contains("e4"))
        XCTAssertFalse(shadowed.contains("e5"), "区间外的不能被误遮")

        // 被遮住的仍在时间线里（可回溯），压缩事件自己也要渲染
        XCTAssertEqual(builder.items.count, 6)
        XCTAssertTrue(builder.items.first { $0.id == "e3" }?.isShadowed ?? false)
        XCTAssertTrue(builder.items.contains { if case .compaction = $0.kind { return true }; return false })
    }

    func testReplaceEventItselfIsNotRenderedAsConversation() throws {
        var builder = TimelineBuilder()
        _ = builder.apply(snapshot: try Fixture.snapshot([
            Fixture.turnStart(1, seq: 1),
            Fixture.systemMessageReplaced(seq: 2, startSeq: 1, endSeq: 1),
        ]))
        // system/message 属于 raw（模型管道），不进对话视图
        XCTAssertFalse(builder.conversationalItems.contains { $0.seq == 2 })
    }

    func testShadowedIdsSurviveLaterAppends() throws {
        var builder = TimelineBuilder()
        _ = builder.apply(snapshot: try Fixture.snapshot([
            Fixture.turnStart(1, seq: 1),
            Fixture.userMessage("早的", seq: 2),
        ]))
        _ = builder.apply(try Fixture.event(Fixture.compactionSummary(seq: 3, startSeq: 2, endSeq: 2)))
        _ = builder.apply(try Fixture.event(Fixture.userMessage("晚的", seq: 4)))
        XCTAssertTrue(builder.items.first { $0.id == "e2" }?.isShadowed ?? false)
        XCTAssertFalse(builder.items.first { $0.id == "e4" }?.isShadowed ?? true)
    }

    // MARK: 注入上下文 vs 真人消息

    /// `user/message` 事件里**只有** `source.kind == "user"` 是人打的字。
    ///
    /// 别的是机器注入的上下文（实测见过的 kind：runtime-context、skill-catalog、
    /// time-context、memory-manager-catalog、mcp-manager-catalog…）。把它们画成
    /// 蓝色用户气泡的后果是：一整个 `<system-reminder>…</available_skills>` 看起来
    /// 像用户自己粘贴的提示词。
    func testInjectedContextIsNotRenderedAsAUserBubble() throws {
        var builder = TimelineBuilder()
        _ = builder.apply(try Fixture.event(Fixture.injectedContext("Time sampled while preparing turn 1", kind: "time-context", seq: 1)))
        _ = builder.apply(try Fixture.event(Fixture.injectedContext("<system-reminder>A skill is…", kind: "skill-catalog", seq: 2)))
        _ = builder.apply(try Fixture.event(Fixture.injectedContext("Current runtime context.", kind: "runtime-context", seq: 3)))
        _ = builder.apply(try Fixture.event(Fixture.userMessage("你能接入 codegraph 吗？", seq: 4)))

        let bubbles = builder.items.compactMap { item -> String? in
            guard case .userMessage(let message) = item.kind else { return nil }
            return message.text
        }
        XCTAssertEqual(bubbles, ["你能接入 codegraph 吗？"], "只有真人消息能变成用户气泡")

        // 注入的上下文不能丢，但要落到 raw（默认隐藏）
        let rawKinds = builder.items.compactMap { item -> String? in
            guard case .raw(let type, _) = item.kind else { return nil }
            return type
        }
        XCTAssertEqual(rawKinds.count, 3)
        XCTAssertTrue(rawKinds.contains("user/message · skill-catalog"))
        XCTAssertFalse(builder.conversationalItems.contains { item in
            if case .raw = item.kind { return true }
            return false
        }, "raw 不进默认视图")
    }

    func testUserMessageWithRpcSourceIsStillAUserBubble() throws {
        // 官方客户端发出来的真人消息 source 是 `{kind:'user', rpcId:…}` —— 一样要画成气泡。
        var builder = TimelineBuilder()
        _ = builder.apply(try Fixture.event(Fixture.userMessage("你好", seq: 1, rpcId: "rpc-9")))
        XCTAssertEqual(builder.conversationalItems.count, 1)
        guard case .userMessage(let message) = builder.conversationalItems[0].kind else { return XCTFail() }
        XCTAssertEqual(message.text, "你好")
        XCTAssertEqual(message.rpcId, "rpc-9")
    }

    // MARK: 实时流

    func testAssistantStreamGrowsTextThenDurableTakesOverSameId() throws {
        var builder = TimelineBuilder()
        _ = builder.apply(snapshot: try Fixture.snapshot([Fixture.turnStart(1, seq: 1)]))

        let attempt = "attempt-1"
        _ = builder.apply(assistantStream: .decode(Fixture.streamStart(attemptId: attempt)))
        _ = builder.apply(assistantStream: .decode(Fixture.streamReasoning("先想一下。", attemptId: attempt, index: 0)))
        var delta = builder.apply(assistantStream: .decode(Fixture.streamText("你", attemptId: attempt, index: 1)))
        delta = builder.apply(assistantStream: .decode(Fixture.streamText("好", attemptId: attempt, index: 2)))

        let live = builder.items.first { $0.id == "live-\(attempt)" }
        XCTAssertNotNil(live, "实时项应已建立")
        guard case .assistantMessage(let streaming)? = live?.kind else { return XCTFail() }
        XCTAssertTrue(streaming.isStreaming)
        XCTAssertEqual(streaming.plainText, "你好")
        XCTAssertEqual(streaming.blocks.first, .reasoning("先想一下。"))

        // 持久事件到达：**必须接管同一个 id**，否则 UI 会闪一下重建。
        let durable = try Fixture.event(Fixture.assistantMessage(text: "你好，我在。", reasoning: "先想一下。", seq: 5))
        _ = builder.apply(durable)

        XCTAssertNil(builder.items.first { $0.id == "live-\(attempt)" }, "实时项应已退休")
        let settled = builder.items.first { $0.id == "e5" }
        XCTAssertNotNil(settled)
        guard case .assistantMessage(let final)? = settled?.kind else { return XCTFail() }
        XCTAssertFalse(final.isStreaming)
        XCTAssertTrue(final.isSettled)
        XCTAssertEqual(final.plainText, "你好，我在。")
        XCTAssertEqual(builder.items.filter { if case .assistantMessage = $0.kind { return true }; return false }.count, 1, "实时与持久不能并存两条")
    }

    func testAssistantStreamAbandonedRetiresLiveItem() throws {
        var builder = TimelineBuilder()
        _ = builder.apply(snapshot: try Fixture.snapshot([Fixture.turnStart(1, seq: 1)]))
        _ = builder.apply(assistantStream: .decode(Fixture.streamStart(attemptId: "a2")))
        _ = builder.apply(assistantStream: .decode(Fixture.streamText("半句话", attemptId: "a2", index: 0)))
        _ = builder.apply(assistantStream: .decode(Fixture.streamEnd(attemptId: "a2", index: 1, kind: "abandoned")))

        guard let item = builder.items.first(where: { $0.id == "live-a2" }) else { return XCTFail() }
        guard case .assistantMessage(let message) = item.kind else { return XCTFail() }
        XCTAssertFalse(message.isStreaming, "放弃后光标要收掉")
        XCTAssertFalse(message.isSettled)
    }

    func testChunksWithoutStartFrameAreIgnored() throws {
        var builder = TimelineBuilder()
        _ = builder.apply(snapshot: try Fixture.snapshot([Fixture.turnStart(1, seq: 1)]))
        _ = builder.apply(assistantStream: .decode(Fixture.streamText("孤儿", attemptId: "ghost", index: 0)))
        XCTAssertTrue(builder.items.filter { if case .assistantMessage = $0.kind { return true }; return false }.isEmpty)
    }

    func testNegativeStreamInterruptsAttemptWithoutDroppingTransientText() throws {
        var builder = TimelineBuilder()
        _ = builder.apply(snapshot: try Fixture.snapshot([Fixture.turnStart(1, seq: 1)]))
        _ = builder.apply(assistantStream: .decode(Fixture.streamStart(attemptId: "a3")))
        _ = builder.apply(assistantStream: .decode(Fixture.streamText("被", attemptId: "a3", index: 0)))
        _ = builder.apply(assistantStream: .decode(Fixture.streamText("打", attemptId: "a3", index: 1)))
        _ = builder.apply(try Fixture.event(Fixture.stepEnd(turn: 1, step: 1, seq: 5)))

        guard let item = builder.items.first(where: { $0.id == "live-a3" }) else { return XCTFail() }
        guard case .assistantMessage(let message) = item.kind else { return XCTFail() }
        XCTAssertEqual(message.plainText, "被打")
        XCTAssertFalse(message.isStreaming)
    }

    // MARK: 乐观插入与去重

    func testOptimisticUserMessageIsReplacedByDurableEvent() throws {
        var builder = TimelineBuilder()
        _ = builder.apply(snapshot: try Fixture.snapshot([Fixture.turnStart(1, seq: 1)]))

        _ = builder.insertOptimisticUserMessage(text: "新消息", rpcId: "rpc-77")
        XCTAssertEqual(builder.items.filter { if case .userMessage = $0.kind { return true }; return false }.count, 1)
        guard case .userMessage(let pending)? = builder.items.first(where: { if case .userMessage = $0.kind { return true }; return false })?.kind else { return XCTFail() }
        XCTAssertTrue(pending.isPending)

        _ = builder.apply(try Fixture.event(Fixture.userMessage("新消息", seq: 5, rpcId: "rpc-77")))
        let users = builder.items.filter { if case .userMessage = $0.kind { return true }; return false }
        XCTAssertEqual(users.count, 1, "乐观项与持久项必须合并成一条")
        XCTAssertEqual(users[0].id, "e5")
        guard case .userMessage(let settled) = users[0].kind else { return XCTFail() }
        XCTAssertFalse(settled.isPending)
    }

    func testInboxSplicedQueuesThenDedupes() throws {
        var builder = TimelineBuilder()
        _ = builder.apply(snapshot: try Fixture.snapshot([Fixture.turnStart(1, seq: 1)]))
        let spliced = try Fixture.event(Fixture.inboxSpliced("排队中的消息", rpcId: "rpc-queued", seq: 2))
        _ = builder.apply(spliced)
        guard case .userMessage(let queued)? = builder.items.first(where: { $0.id == "inbox-rpc-queued" })?.kind else {
            return XCTFail("排队消息应作为待发送项出现")
        }
        XCTAssertTrue(queued.isPending)

        _ = builder.apply(try Fixture.event(Fixture.userMessage("排队中的消息", seq: 6, rpcId: "rpc-queued")))
        let users = builder.items.filter { if case .userMessage = $0.kind { return true }; return false }
        XCTAssertEqual(users.count, 1)
        XCTAssertEqual(users[0].id, "e6")
    }

    // MARK: 审批

    func testApprovalAskedThenDecided() throws {
        var builder = TimelineBuilder()
        _ = builder.apply(try Fixture.event(Fixture.approvalAsked(id: "ap-1", seq: 10)))
        guard case .approval(let approval)? = builder.items.first?.kind else { return XCTFail() }
        XCTAssertTrue(approval.isPending)
        XCTAssertEqual(approval.toolName, "bash")
        XCTAssertEqual(approval.reason, "要跑一条写文件的命令")

        _ = builder.apply(try Fixture.event(Fixture.approvalDecided(id: "ap-1", outcome: "allowed-once", seq: 11)))
        guard case .approval(let decided)? = builder.items.first?.kind else { return XCTFail() }
        XCTAssertFalse(decided.isPending)
        XCTAssertEqual(decided.decision, .approvedOnce)
        XCTAssertNotNil(decided.decidedAt)
    }

    func testApprovalDecidedMapsEveryOutcome() {
        XCTAssertEqual(TimelineItem.Approval.Decision(raw: "allowed-once"), .approvedOnce)
        XCTAssertEqual(TimelineItem.Approval.Decision(raw: "rejected"), .denied)
        XCTAssertEqual(TimelineItem.Approval.Decision(raw: "cancelled"), .cancelled)
        XCTAssertEqual(TimelineItem.Approval.Decision(raw: "unavailable"), .other("unavailable"))
    }

    // MARK: 其它事件

    func testTodoWrite() throws {
        var builder = TimelineBuilder()
        _ = builder.apply(try Fixture.event(Fixture.todoWrite([("写测试", "in_progress"), ("跑构建", "pending"), ("提交", "completed")], seq: 4)))
        guard case .todo(let list)? = builder.items.first?.kind else { return XCTFail() }
        XCTAssertEqual(list.items.count, 3)
        XCTAssertEqual(list.items[0].status, .inProgress)
        XCTAssertEqual(list.items[2].status, .completed)
    }

    func testToolFailure() throws {
        var builder = TimelineBuilder()
        _ = builder.apply(try Fixture.event(Fixture.toolCall("call_x", seq: 1)))
        _ = builder.apply(try Fixture.event(Fixture.toolResult("call_x", output: "command not found", isError: true, seq: 2)))
        guard case .toolCall(let tool)? = builder.items.first?.kind else { return XCTFail() }
        XCTAssertEqual(tool.status, .failed)
        XCTAssertTrue(tool.isError)
    }

    func testToolResultWithoutCallStillRenders() throws {
        var builder = TimelineBuilder()
        _ = builder.apply(try Fixture.event(Fixture.toolResult("call_orphan", output: "只有结果", seq: 1)))
        guard case .toolCall(let tool)? = builder.items.first?.kind else { return XCTFail() }
        XCTAssertEqual(tool.callId, "call_orphan")
        XCTAssertEqual(tool.output, "只有结果")
    }

    func testUnknownEventIsKept() throws {
        var builder = TimelineBuilder()
        _ = builder.apply(try Fixture.event(Fixture.unknownEvent(type: "some-future/thing", seq: 1)))
        guard case .unknown(let type, _)? = builder.items.first?.kind else { return XCTFail() }
        XCTAssertEqual(type, "some-future/thing")
    }

    func testIgnorableUnknownEventIsSkipped() throws {
        var builder = TimelineBuilder()
        _ = builder.apply(try Fixture.event(Fixture.unknownEvent(type: "external/plugin-event", seq: 1, ignorable: true)))
        XCTAssertTrue(builder.items.isEmpty)
    }

    func testModelPlumbingEventsGoToRawBucket() throws {
        var builder = TimelineBuilder()
        _ = builder.apply(try Fixture.event(Fixture.requestHeader(seq: 1)))
        XCTAssertEqual(builder.items.count, 1)
        XCTAssertFalse(builder.conversationalItems.contains { $0.seq == 1 })
        guard case .raw(let type, _)? = builder.items.first?.kind else { return XCTFail() }
        XCTAssertEqual(type, "request/header")
    }

    // MARK: 审批

    /// `approval/asked` 里有两个 id：`id`（审批自身的 UUID）与 `callId`（被审批的工具调用）。
    ///
    /// 当初把 `id` 当成 callId 用过，两个后果都实测到了：
    /// ① 拿不到"要被审批的工具参数"（参数挂在 `tool/call` 上，按 callId 关联）；
    /// ② 跟 waterfall 里的 `callId` 对不上，卡片会误判成"这条已经不能回答了"。
    func testApprovalKeepsBothItsOwnIdAndTheToolCallId() throws {
        var builder = TimelineBuilder()
        let asked = """
        {"type":"approval/asked","seq":5,"time":1791777000000,"data":{"id":"81e8b850-f040-4349-a916-2af93eb3c974","toolName":"bash","callId":"call_00_T7rDK9OjMLkUZ2O9p3CG1129","reason":"escalate sandbox"},"surfaceOp":"append"}
        """
        _ = builder.apply(try Fixture.event(asked))

        let approval = try XCTUnwrap(builder.items.compactMap { item -> TimelineItem.Approval? in
            if case .approval(let value) = item.kind { return value }
            return nil
        }.first)

        XCTAssertEqual(approval.approvalId, "81e8b850-f040-4349-a916-2af93eb3c974")
        XCTAssertEqual(approval.callId, "call_00_T7rDK9OjMLkUZ2O9p3CG1129", "两个 id 都要留着")
        XCTAssertNotEqual(approval.approvalId, approval.callId, "它们确实不是一回事")
    }

    // MARK: 落盘 / 续拉

    /// 折叠状态必须能**原样**往返 —— 恢复之后还能继续增量折叠，而不是只能画。
    func testStateRoundTripsAndKeepsFoldingIdentically() throws {
        let events = [
            Fixture.turnStart(1, seq: 1),
            Fixture.userMessage("第一句", seq: 2),
            Fixture.assistantMessage(text: "回答一", toolCall: ("call_a", "bash", "{}"), seq: 3),
            Fixture.toolCall("call_a", seq: 4),
        ]
        var original = TimelineBuilder()
        _ = original.apply(snapshot: try Fixture.snapshot(events))

        let encoded = try JSONEncoder.cacheForTests.encode(original.state)
        let decoded = try JSONDecoder.cacheForTests.decode(TimelineBuilder.State.self, from: encoded)
        var restored = try XCTUnwrap(TimelineBuilder(state: decoded))
        XCTAssertEqual(restored.items.count, original.items.count)

        // 关键：恢复之后 `tool/result` 还要能合并到那条 `tool/call` 上
        _ = restored.apply(try Fixture.event(Fixture.toolResult("call_a", output: "done", seq: 5)))
        _ = original.apply(try Fixture.event(Fixture.toolResult("call_a", output: "done", seq: 5)))

        let restoredTool = restored.items.compactMap { item -> TimelineItem.ToolCall? in
            if case .toolCall(let call) = item.kind { return call }
            return nil
        }.first
        let originalTool = original.items.compactMap { item -> TimelineItem.ToolCall? in
            if case .toolCall(let call) = item.kind { return call }
            return nil
        }.first
        XCTAssertEqual(restoredTool?.status, .success, "恢复后 tool/result 仍要合并到 tool/call")
        XCTAssertEqual(restoredTool?.output, originalTool?.output)
        XCTAssertEqual(restored.items.map(\.id), original.items.map(\.id), "两边折叠出的条目应当完全一致")
    }

    func testStateRejectsUnknownSchemaVersion() throws {
        let stale = TimelineBuilder.State(schemaVersion: 999)
        XCTAssertNil(TimelineBuilder(state: stale), "版本对不上要丢弃，不能猜着读")

        // 加字段（审批的 callId）时把版本从 1 提到 2 —— 旧缓存必须被丢掉，
        // 否则 `Approval.callId` 会是 nil，审批卡片又会认不出自己能答。
        XCTAssertEqual(TimelineBuilder.State.currentSchemaVersion, 2)
        XCTAssertNil(TimelineBuilder(state: TimelineBuilder.State(schemaVersion: 1)))
    }

    /// `resume` 是**合并**：老的条目留着，新的按 seq 补上。
    func testResumeMergesInsteadOfResetting() throws {
        var builder = TimelineBuilder()
        _ = builder.apply(snapshot: try Fixture.snapshot([
            Fixture.turnStart(1, seq: 1),
            Fixture.userMessage("很早的一句", seq: 2),
        ], cursor: 2))

        // 宿主的快照只带最近的消息 —— 更早的那条不在里面
        let fresh = try Fixture.snapshot([
            Fixture.userMessage("刚说的一句", seq: 9),
        ], cursor: 9)

        XCTAssertTrue(builder.resume(with: fresh))
        let texts = builder.items.compactMap { item -> String? in
            guard case .userMessage(let message) = item.kind else { return nil }
            return message.text
        }
        XCTAssertEqual(texts, ["很早的一句", "刚说的一句"], "续拉不能丢掉更早的历史")
        XCTAssertEqual(builder.cursor, 9)
    }

    func testResumeRefusesWhenHostIsBehindTheCache() throws {
        var builder = TimelineBuilder()
        _ = builder.apply(snapshot: try Fixture.snapshot([Fixture.turnStart(1, seq: 40)], cursor: 40))
        // 宿主给的 cursor 比我们手里的还小 —— 说明日志被换过 / 缓存过旧
        let stale = try Fixture.snapshot([Fixture.turnStart(1, seq: 1)], cursor: 1)
        XCTAssertFalse(builder.resume(with: stale), "这种情况必须让调用方整体重建")
    }

    // MARK: 历史补页

    func testPrependPageKeepsOrderAndDedupes() throws {
        var builder = TimelineBuilder()
        _ = builder.apply(snapshot: try Fixture.snapshot([
            Fixture.turnStart(1, seq: 10),
            Fixture.userMessage("后半段", seq: 11),
        ], cursor: 11))

        let page = try [
            Fixture.event(Fixture.turnStart(1, seq: 1)),
            Fixture.event(Fixture.userMessage("前半段", seq: 2)),
            // 故意重复一条：不能出现两次
            Fixture.event(Fixture.userMessage("后半段", seq: 11)),
        ]
        _ = builder.prepend(page: page)

        let texts = builder.items.compactMap { item -> String? in
            guard case .userMessage(let message) = item.kind else { return nil }
            return message.text
        }
        XCTAssertEqual(texts, ["前半段", "后半段"])
        XCTAssertEqual(builder.items.map(\.seq), builder.items.map(\.seq).sorted())
    }

    // MARK: 原始快照（本机抓包，缺失时跳过）

    func testRealCapturedSnapshotsIfPresent() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DSHKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // DSHKit
            .deletingLastPathComponent()   // ios
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("docs/artifacts/samples")

        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "jsonl" } ?? []
        guard !files.isEmpty else {
            throw XCTSkip("没有本机抓包样本（docs/artifacts/samples 为空）；跑 tools/capture-session.mjs 生成")
        }

        for file in files {
            let content = try String(contentsOf: file, encoding: .utf8)
            var builder = TimelineBuilder()
            var sawSnapshot = false
            for line in content.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let frame = try? JSONDecoder.dsh.decode(JSONValue.self, from: data),
                      frame.string("type") == "item",
                      let value = frame["value"]
                else { continue }
                switch value.string("type") {
                case "snapshot":
                    _ = builder.apply(snapshot: try SessionSnapshot.decode(value))
                    sawSnapshot = true
                case "event":
                    guard let payload = value["event"], let event = try? SessionEvent.decode(payload) else { continue }
                    _ = builder.apply(event)
                case "assistant-stream":
                    _ = builder.apply(assistantStream: AssistantStreamFrame.decode(value))
                default:
                    break
                }
            }
            XCTAssertTrue(sawSnapshot, "\(file.lastPathComponent) 里应有 snapshot 帧")
            XCTAssertFalse(builder.items.isEmpty, "\(file.lastPathComponent) 折叠后不该是空的")
            // 真实样本必须能一条不丢地解析出事件，而不是大面积落进 unknown。
            let unknownCount = builder.items.filter { if case .unknown = $0.kind { return true }; return false }.count
            XCTAssertLessThanOrEqual(
                unknownCount, 2,
                "\(file.lastPathComponent)：\(unknownCount) 条事件落进 unknown，可能是协议漂移"
            )
            // content 解析必须真的解出东西：空 assistant/message 是合法的
            // （max-tokens 步只带 usage），所以看总体而不是逐条。
            var assistantWithBlocks = 0
            var totalText = 0
            for item in builder.items {
                guard case .assistantMessage(let message) = item.kind else { continue }
                if !message.blocks.isEmpty { assistantWithBlocks += 1 }
                totalText += message.plainText.count
            }
            XCTAssertGreaterThan(assistantWithBlocks, 0, "\(file.lastPathComponent)：一条助手消息的内容块都没解出来")
            XCTAssertGreaterThan(totalText, 200, "\(file.lastPathComponent)：助手正文总长度异常（\(totalText)）")

            // 工具调用必须合并成一条一条的，而不是 call/result 各来一条
            let toolIds = builder.items.compactMap { item -> String? in
                guard case .toolCall(let call) = item.kind else { return nil }
                return call.callId
            }
            XCTAssertEqual(Set(toolIds).count, toolIds.count, "\(file.lastPathComponent)：有工具调用被渲染了两次")
        }
    }
}
