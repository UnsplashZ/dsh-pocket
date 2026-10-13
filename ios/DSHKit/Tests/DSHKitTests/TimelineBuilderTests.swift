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
        // 条目 id 用**服务端那条消息的 id**（fixture 里是 `m-<seq>`）——
        // `session/updateQueue` 的 `itemId` 要的就是它（编辑/删除/插队都按它定位）。
        guard case .userMessage(let queued)? = builder.items.first(where: { $0.id == "m-2" })?.kind else {
            return XCTFail("排队消息应作为待发送项出现，且条目 id 要用服务端的消息 id")
        }
        XCTAssertTrue(queued.isPending)
        XCTAssertTrue(queued.isQueued, "要能跟「乐观插入」区分开")

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

    // MARK: 轮次分组

    /// 造一个轮次。
    ///
    /// 注意事件顺序：宿主是 `turn/start` → `user/message` → … → `turn/end`，
    /// **提示词在轮次里面**。seq 也刻意错开 —— 同 seq 会被 `upsert` 覆盖掉。
    private func foldTurn(
        _ builder: inout TimelineBuilder,
        turn: Int,
        startSeq: Int,
        text: String,
        reasoning: String = "想一想",
        prompt: String? = nil
    ) throws {
        var events: [String] = [Fixture.turnStart(turn, seq: startSeq)]
        var cursor = startSeq
        if let prompt {
            cursor += 1
            events.append(Fixture.userMessage(prompt, seq: cursor))
        }
        cursor += 1
        events.append(Fixture.injectedContext("time", kind: "time-context", seq: cursor))
        cursor += 1
        events.append(Fixture.assistantMessage(text: text, reasoning: reasoning, seq: cursor))
        cursor += 1
        events.append(Fixture.toolCall("call_\(turn)", seq: cursor))
        cursor += 1
        events.append(Fixture.toolResult("call_\(turn)", output: "ok", seq: cursor))
        cursor += 1
        events.append(Fixture.assistantMessage(text: "最终结论 \(turn)", seq: cursor))
        cursor += 1
        events.append(Fixture.turnEnd(turn, seq: cursor))
        for raw in events { _ = builder.apply(try Fixture.event(raw)) }
    }

    /// 跑完的轮次要收拢成：一行摘要 + 最终结论，中间的进折叠区。
    func testCompletedTurnGroupsIntoSummaryPlusHeadline() throws {
        var builder = TimelineBuilder()
        _ = builder.apply(try Fixture.event(Fixture.userMessage("帮我看看", seq: 1)))
        try foldTurn(&builder, turn: 1, startSeq: 2, text: "我先看一下")

        let blocks = builder.timelineBlocks()
        XCTAssertEqual(blocks.count, 2, "一条用户消息 + 一个轮次")

        guard case .turn(let turn) = blocks[1] else { return XCTFail("第二块应当是轮次") }
        XCTAssertTrue(turn.isComplete)
        XCTAssertEqual(turn.turn, 1)
        XCTAssertNotNil(turn.duration, "时长用 turn/start 与 turn/end 的时间算")

        // 明面上留的是**最后**那条有正文的助手消息
        guard case .assistantMessage(let headline)? = turn.headline?.kind else { return XCTFail("应当有结论") }
        XCTAssertEqual(headline.plainText, "最终结论 1")

        // 折叠区里有：中间那句过场话、工具行、注入上下文
        let collapsedTexts = turn.collapsible.compactMap { item -> String? in
            if case .assistantMessage(let message) = item.kind { return message.plainText }
            return nil
        }
        XCTAssertTrue(collapsedTexts.contains("我先看一下"), "过场话应当被收起来")
        XCTAssertFalse(collapsedTexts.contains("最终结论 1"), "结论不该同时出现在折叠区")
        XCTAssertTrue(turn.collapsible.contains { if case .toolCall = $0.kind { return true }; return false })
        XCTAssertFalse(turn.collapsible.contains { if case .turnStart = $0.kind { return true }; return false },
                       "turn/start 自己就是摘要的一部分，不重复收进去")
    }

    /// **用户自己说的话永远不能被折叠。**
    ///
    /// 宿主的事件顺序是 `turn/start` → `user/message` → … → `turn/end`，
    /// 也就是说提示词**在轮次里面**。不特意挑出来的话它会被当成"轮内过程"
    /// 一起收进摘要 —— 用户会以为自己的话被吞了（实测踩过）。
    func testUserPromptInsideTheTurnIsNeverFolded() throws {
        var builder = TimelineBuilder()
        try foldTurn(&builder, turn: 1, startSeq: 2, text: "我先看一下", prompt: "帮我看一下这个仓库")

        guard case .turn(let turn) = builder.timelineBlocks().first else { return XCTFail() }
        XCTAssertEqual(turn.pinned.count, 1, "用户消息要单独挑出来")
        guard case .userMessage(let prompt)? = turn.pinned.first?.kind else { return XCTFail("挑不出来") }
        XCTAssertEqual(prompt.text, "帮我看一下这个仓库")

        XCTAssertFalse(
            turn.collapsible.contains { if case .userMessage = $0.kind { return true }; return false },
            "折叠区里不该有用户消息"
        )
        XCTAssertTrue(turn.collapsedItems.contains { if case .userMessage = $0.kind { return true }; return false } == false,
                      "收起时渲染的那批里也不该有 —— 它在摘要行上面单独渲染，重复放会画两遍")
    }

    /// 展开之后要回到**原始时序**：过程在结论前面，不是跑到结论下面去。
    func testExpandedTurnRestoresChronologicalOrder() throws {
        var builder = TimelineBuilder()
        try foldTurn(&builder, turn: 1, startSeq: 2, text: "我先看一下", prompt: "问题")
        guard case .turn(let turn) = builder.timelineBlocks().first else { return XCTFail() }

        let headlineSeq = try XCTUnwrap(turn.headline?.seq)
        let expanded = turn.expandedItems.map(\.seq)
        XCTAssertEqual(expanded, expanded.sorted(), "展开后必须按 seq 升序")
        XCTAssertEqual(expanded.last, headlineSeq, "结论应当在最后（时序上它本来就是最后）")

        // 收起时只剩结论
        XCTAssertEqual(turn.collapsedItems.map(\.id), [try XCTUnwrap(turn.headline?.id)])
    }

    /// **分组必须跟 `publish()` 用同一套过滤。**
    ///
    /// 这里曾经只过滤 shadowed，于是"只有工具调用"的助手消息
    /// （`isConversational == false`）照样进了轮次分组，渲染成一张
    /// **只有时间、没有任何文字的空白卡片**。在 `SessionView` 里直接渲染
    /// `items` 的时候看不到 —— 那批早就被过滤过了，是分组把它漏出来的。
    func testTurnGroupingDropsItemsTheDefaultViewWouldHide() throws {
        var builder = TimelineBuilder()
        _ = builder.apply(try Fixture.event(Fixture.turnStart(1, seq: 1)))
        // 只声明了一个工具调用的助手消息：条目本身要留着（工具行要用），
        // 但默认视图里不该出现。
        _ = builder.apply(try Fixture.event(
            Fixture.assistantMessage(text: "", toolCall: ("call_x", "bash", "{}"), seq: 2)
        ))
        _ = builder.apply(try Fixture.event(Fixture.assistantMessage(text: "有正文", seq: 3)))
        _ = builder.apply(try Fixture.event(Fixture.turnEnd(1, seq: 4)))

        let blocks = builder.timelineBlocks()
        guard case .turn(let turn) = blocks.first else { return XCTFail() }
        let kinds = turn.items.map { item -> String in
            if case .assistantMessage(let message) = item.kind {
                return message.hasRenderableContent ? "可渲染" : "空"
            }
            return "其它"
        }
        XCTAssertFalse(kinds.contains("空"), "空助手消息不该进分组，实际：\(kinds)")

        // 打开"显示原始事件"时要全给出来
        let raw = builder.timelineBlocks(showRawEvents: true)
        guard case .turn(let rawTurn) = raw.first else { return XCTFail() }
        XCTAssertGreaterThan(rawTurn.items.count, turn.items.count, "showRawEvents 下应当更全")
    }

    /// 派生集合改成"构造时算一次"之后，**改 `items` 也要跟着重算**。
    ///
    /// 这几个属性原来都是 computed property（每次 body 求值重扫一遍 `items`），
    /// 现在是存下来的。存下来就得保证写入路径也走重算，否则会拿着过期的一份渲染 ——
    /// 这种 bug 在界面上表现为"内容不动了"，很难往回追。
    func testTurnRecomputesDerivedCollectionsWhenItemsChange() throws {
        var builder = TimelineBuilder()
        _ = builder.apply(try Fixture.event(Fixture.turnStart(1, seq: 1)))
        _ = builder.apply(try Fixture.event(Fixture.userMessage("第一句", seq: 2)))
        _ = builder.apply(try Fixture.event(Fixture.assistantMessage(text: "结论一", seq: 3)))
        _ = builder.apply(try Fixture.event(Fixture.turnEnd(1, seq: 4)))

        guard case .turn(var turn) = builder.timelineBlocks().first else { return XCTFail() }
        XCTAssertEqual(turn.pinned.count, 1)
        guard case .assistantMessage(let first)? = turn.headline?.kind else { return XCTFail() }
        XCTAssertEqual(first.plainText, "结论一")

        // 追加一条更晚的助手正文：结论、折叠集合都要跟着更新
        var later = TimelineBuilder()
        _ = later.apply(try Fixture.event(Fixture.turnStart(1, seq: 1)))
        _ = later.apply(try Fixture.event(Fixture.userMessage("第一句", seq: 2)))
        _ = later.apply(try Fixture.event(Fixture.assistantMessage(text: "结论一", seq: 3)))
        _ = later.apply(try Fixture.event(Fixture.assistantMessage(text: "结论二", seq: 5)))
        _ = later.apply(try Fixture.event(Fixture.turnEnd(1, seq: 6)))
        guard case .turn(let updated) = later.timelineBlocks().first else { return XCTFail() }
        guard case .assistantMessage(let second)? = updated.headline?.kind else { return XCTFail() }
        XCTAssertEqual(second.plainText, "结论二", "结论要跟着 items 更新")
        XCTAssertFalse(
            updated.collapsible.contains { $0.id == updated.headline?.id },
            "新结论不该同时留在折叠区"
        )

        // 直接改 items 也要触发重算（didSet）
        turn.items = updated.items
        guard case .assistantMessage(let replaced)? = turn.headline?.kind else { return XCTFail() }
        XCTAssertEqual(replaced.plainText, "结论二", "`items` 变了派生集合必须重算")
    }

    /// 还在跑的轮次**不**收拢 —— 正在发生的事没有收拢的道理。
    func testRunningTurnIsNotCollapsed() throws {
        var builder = TimelineBuilder()
        _ = builder.apply(try Fixture.event(Fixture.turnStart(1, seq: 1)))
        _ = builder.apply(try Fixture.event(Fixture.assistantMessage(text: "正在做", seq: 2)))

        let blocks = builder.timelineBlocks()
        guard case .turn(let turn) = blocks.first else { return XCTFail("应当有轮次") }
        XCTAssertFalse(turn.isComplete)
        XCTAssertNil(turn.duration)
    }

    /// 轮次之外的条目（会话头、用户消息）不进组，照常显示。
    func testItemsOutsideTurnsStayStandalone() throws {
        var builder = TimelineBuilder()
        _ = builder.apply(try Fixture.event(Fixture.userMessage("第一句", seq: 1)))
        _ = builder.apply(try Fixture.event(Fixture.userMessage("第二句", seq: 2)))
        let blocks = builder.timelineBlocks()
        XCTAssertEqual(blocks.count, 2)
        for block in blocks {
            guard case .item = block else { return XCTFail("都应当是独立条目") }
        }
    }

    /// **只有工具调用的助手消息不该渲染成空白卡片。**
    ///
    /// 实测踩过：`hasRenderableContent` 把 `.toolCall` 也算作"有内容"，
    /// 但助手卡片对它是 `EmptyView`（工具走单独的 `ToolRow`）——
    /// 结果屏幕上多出一张只有时间、没有任何文字的空白卡片。
    func testAssistantMessageWithOnlyToolCallsIsNotRenderable() throws {
        var builder = TimelineBuilder()
        _ = builder.apply(try Fixture.event(
            Fixture.assistantMessage(text: "", toolCall: ("call_x", "bash", "{}"), seq: 1)
        ))
        let assistant = builder.items.first { if case .assistantMessage = $0.kind { return true }; return false }
        XCTAssertNotNil(assistant, "条目本身还在（工具行要用它）")
        XCTAssertFalse(assistant?.isConversational ?? true, "但不该出现在默认视图里")
    }

    /// **队列项被消费后，真正的 `user/message` 接管它不能继承"已隐藏"。**
    ///
    /// 完整链路（实测踩过）：
    ///   1. 消息进队列 → 建一条 `inbox-<rpcId>` 待发项；
    ///   2. 队列被消费 → `applyInbox` 把它标成 `isShadowed = true`；
    ///   3. 真正的 `user/message` 带着**同一个 rpcId** 到达，接管那条项 ——
    ///      不清标记的话会继承"已隐藏"，**用户的提示词整条消失**。
    func testDurableUserMessageTakingOverAConsumedQueueItemIsVisible() throws {
        var builder = TimelineBuilder()
        // ① 入队
        _ = builder.apply(try Fixture.event("""
        {"type":"agent/inbox/spliced","seq":1,"time":1791777000000,"data":{"inserted":[{"content":[{"type":"text","text":"排队的那条"}],"source":{"kind":"user","rpcId":"rpc-9"},"role":"user","id":"m1"}]},"surfaceOp":null}
        """))
        // ② 队列被消费
        _ = builder.apply(try Fixture.event("""
        {"type":"agent/inbox/spliced","seq":2,"time":1791777000000,"data":{"removedCount":1,"outcome":"claimed"},"surfaceOp":null}
        """))
        // ③ 真正落进日志
        _ = builder.apply(try Fixture.event(Fixture.userMessage("排队的那条", seq: 3, rpcId: "rpc-9")))

        let durable = builder.items.filter { item in
            guard case .userMessage(let message) = item.kind else { return false }
            return !message.isPending
        }
        XCTAssertEqual(durable.count, 1, "接管之后只该剩一条")
        XCTAssertFalse(durable[0].isShadowed, "接管时必须清掉队列项留下的 shadowed 标记")
        XCTAssertTrue(durable[0].isConversational, "而且要能渲染出来")
    }

    /// 排队中的消息**从日志推导**，不读投影。
    ///
    /// `applyInbox` 本来就在维护这些项（`agent/inbox/spliced` 的 `inserted` 建项、
    /// 被消化时标 shadowed），所以队列一变就跟着变。
    ///
    /// 之前渲染的是 `projections.inbox` —— 那个**只在快照时更新一次**，
    /// 于是在电脑上删掉排队任务之后，手机上要退出会话再进来才会消失（实测）。
    func testQueuedMessagesFollowTheLogNotTheProjection() throws {
        var builder = TimelineBuilder()
        _ = builder.apply(try Fixture.event("""
        {"type":"agent/inbox/spliced","seq":1,"time":1791777000000,"data":{"inserted":[{"content":[{"type":"text","text":"排队一"}],"source":{"kind":"user","rpcId":"r1"},"role":"user","id":"m1"}]},"surfaceOp":null}
        """))
        _ = builder.apply(try Fixture.event("""
        {"type":"agent/inbox/spliced","seq":2,"time":1791777000000,"data":{"inserted":[{"content":[{"type":"text","text":"排队二"}],"source":{"kind":"user","rpcId":"r2"},"role":"user","id":"m2"}]},"surfaceOp":null}
        """))
        XCTAssertEqual(builder.queuedMessages.map(\.text), ["排队一", "排队二"])

        // 电脑上把队列清掉（`removedCount`）→ 本地**立刻**跟着清
        _ = builder.apply(try Fixture.event("""
        {"type":"agent/inbox/spliced","seq":3,"time":1791777000000,"data":{"removedCount":2,"outcome":"claimed"},"surfaceOp":null}
        """))
        XCTAssertTrue(builder.queuedMessages.isEmpty, "电脑删掉排队任务后本地要立刻消失，不能等重进会话")
    }

    /// **队列项不能进时间线。**
    ///
    /// 它和"乐观插入"都是 `isPending`，但：
    ///   · 乐观插入 = 你自己刚发的，该在时间线上立刻出现（"发送中…"）；
    ///   · 队列项 = 还没轮到它，只该出现在底部的「排队中」区。
    /// 不区分的话队列项会被画成一个蓝色气泡、还带"发送中…" ——
    /// 看起来就像消息已经发出去了（实测：电脑上排队的任务在手机上就是这样）。
    func testQueuedItemDoesNotRenderAsASentMessage() throws {
        var builder = TimelineBuilder()
        // ① 你自己发的（乐观插入）→ 要进时间线
        _ = builder.insertOptimisticUserMessage(text: "我刚发的", images: [], files: [], rpcId: "mine")

        // ② 电脑上排队的 → 只该进队列区
        _ = builder.apply(try Fixture.event("""
        {"type":"agent/inbox/spliced","seq":1,"time":1791777000000,"data":{"inserted":[{"content":[{"type":"text","text":"排队中的"}],"source":{"kind":"user","rpcId":"queued"},"role":"user","id":"m1"}]},"surfaceOp":null}
        """))

        let visible = builder.conversationalItems.compactMap { item -> String? in
            guard case .userMessage(let message) = item.kind else { return nil }
            return message.text
        }
        XCTAssertEqual(visible, ["我刚发的"], "队列项不该出现在时间线里")
        XCTAssertEqual(builder.queuedMessages.map(\.text), ["排队中的"], "但要在队列区里")

        // ③ 轮到它了：真正的 user/message 接管 → 进时间线、出队列
        _ = builder.apply(try Fixture.event(Fixture.userMessage("排队中的", seq: 2, rpcId: "queued")))
        let after = builder.conversationalItems.compactMap { item -> String? in
            guard case .userMessage(let message) = item.kind else { return nil }
            return message.text
        }
        XCTAssertTrue(after.contains("排队中的"), "被接管之后要进时间线")
        XCTAssertTrue(builder.queuedMessages.isEmpty, "同时要从队列区消失")
    }

    /// **消化队列只该撤掉被消化的那几条。**
    ///
    /// `agent/inbox/spliced` 带 `start`（下标）与 `removedCount`，是一次 splice。
    /// 之前这里把**所有**队列项都标成已隐藏 —— 宿主消化掉一条之后，
    /// 手机上剩下的排队消息全都不见了（用户："排队的消息在手机上看不到"），
    /// 而且它们既不在队列区也不在时间线里，等于凭空消失。
    func testInboxRemovalOnlyDropsTheConsumedItems() throws {
        var builder = TimelineBuilder()
        for (index, text) in ["第一条", "第二条", "第三条"].enumerated() {
            _ = builder.apply(try Fixture.event(Fixture.inboxSpliced(text, rpcId: "r\(index)", seq: index + 1)))
        }
        XCTAssertEqual(builder.queuedMessages.map(\.text), ["第一条", "第二条", "第三条"])

        // 宿主消化掉**最前面**那一条（`start: 0`, `removedCount: 1`）
        _ = builder.apply(try Fixture.event("""
        {"type":"agent/inbox/spliced","seq":10,"time":1791777000000,"data":{"target":"next-turn","start":0,"removedCount":1,"inserted":[]}}
        """))
        XCTAssertEqual(builder.queuedMessages.map(\.text), ["第二条", "第三条"],
                       "只该少掉第一条，后面两条必须还在")

        // 再消化一条
        _ = builder.apply(try Fixture.event("""
        {"type":"agent/inbox/spliced","seq":11,"time":1791777000000,"data":{"target":"next-turn","start":0,"removedCount":1,"inserted":[]}}
        """))
        XCTAssertEqual(builder.queuedMessages.map(\.text), ["第三条"])
    }

    /// **宿主注入的"审批策略变了"通知不该进队列。**
    ///
    /// `dsh-user-approval` 在策略变化时走 `agent.inject(createUserMessage(…))`，
    /// 把它当成**用户消息**塞进队列。而 `/permission <preset>` 一次改两样
    ///（沙箱模式 + 审批策略），于是切一次权限就冒出**两条排队消息**。
    /// 用户没说过这两句话，权限也已经显示在输入框的胶囊上 —— 纯噪音。
    func testApprovalPolicyNoticeIsNotQueued() throws {
        var builder = TimelineBuilder()
        _ = builder.apply(try Fixture.event(Fixture.inboxSpliced(
            #"The approval policy changed from "never" to "ask" (changed by the user)."#,
            rpcId: "notice-1", seq: 1
        )))
        XCTAssertTrue(builder.queuedMessages.isEmpty, "机器通知不该出现在队列里")
        XCTAssertTrue(builder.conversationalItems.isEmpty, "也不该进时间线")

        // 用户自己发的照旧
        _ = builder.apply(try Fixture.event(Fixture.inboxSpliced("我自己的排队", rpcId: "mine", seq: 2)))
        XCTAssertEqual(builder.queuedMessages.map(\.text), ["我自己的排队"])
    }

    /// **`/permission` 引发的那一组配置 note 整组丢掉。**
    ///
    /// 一次权限切换会留下 5 行（`command/run` / `sandbox/mode` /
    /// `permission/preset` / `approval/policy` / `command/done`），
    /// 而权限已经显示在输入框的胶囊上 —— 纯噪音。
    ///
    /// 但**别的地方**（从电脑上改权限）照常显示 —— 窗口在 `command/done` 处关闭。
    func testPermissionCommandNotesAreSuppressed() throws {
        var builder = TimelineBuilder()
        _ = builder.apply(try Fixture.event(#"{"type":"command/run","seq":1,"time":1791777000000,"data":{"name":"permission","args":["danger-full-access"]}}"#))
        _ = builder.apply(try Fixture.event(#"{"type":"sandbox/mode","seq":2,"time":1791777000000,"data":{"mode":"danger-full-access"}}"#))
        _ = builder.apply(try Fixture.event(#"{"type":"permission/preset","seq":3,"time":1791777000000,"data":{"preset":"danger-full-access"}}"#))
        _ = builder.apply(try Fixture.event(#"{"type":"approval/policy","seq":4,"time":1791777000000,"data":{"policy":"never"}}"#))
        _ = builder.apply(try Fixture.event(#"{"type":"command/done","seq":5,"time":1791777000000,"data":{"name":"permission"}}"#))
        XCTAssertTrue(builder.items.isEmpty, "这一组五行都不该出现，实际：\(builder.items.map(\.kind))")

        // 窗口关了：之后**别处**来的配置变更照常显示
        _ = builder.apply(try Fixture.event(#"{"type":"sandbox/mode","seq":6,"time":1791777000000,"data":{"mode":"workspace-write"}}"#))
        XCTAssertEqual(builder.items.count, 1, "窗口关闭后要恢复正常")

        // 别的命令不受影响
        _ = builder.apply(try Fixture.event(#"{"type":"command/run","seq":7,"time":1791777000000,"data":{"name":"compact"}}"#))
        XCTAssertEqual(builder.items.count, 2, "只有 permission 被抑制")
    }

    /// 计时器的起点。
    ///
    /// 实测踩过的坑：`items.last?.turn` 是 `nil` 时（最后一条是注入上下文之类），
    /// 直接 `first(where: { $0.turn == nil })` 会匹配到**日志最开头**那条 ——
    /// 计时器显示成 `32 分 47 秒`。
    func testTurnTimerStart() throws {
        let now = Date(timeIntervalSince1970: 1000)
        func item(_ seq: Double, _ secondsAgo: TimeInterval, turn: Int?) -> TimelineItem {
            TimelineItem(
                id: "i\(seq)", seq: seq, time: now.addingTimeInterval(-secondsAgo), turn: turn,
                kind: .note(.init(text: "n\(seq)", symbolName: "x", tone: .neutral,
                                  sourceEventType: "x", isProminent: false))
            )
        }

        // ① 不跑着 → 没有起点（计时器不显示）
        XCTAssertNil(TurnTimer.start(items: [item(1, 5, turn: 1)], isRunning: false, existing: nil, now: now))

        // ② 已经有起点（`turn/start` 给的）→ 不动它
        let given = now.addingTimeInterval(-30)
        XCTAssertEqual(TurnTimer.start(items: [item(1, 5, turn: 1)], isRunning: true, existing: given, now: now), given)

        // ③ 没有起点 → 取**当前这一轮第一条**的时间，不是最后一条
        let items = [item(1, 300, turn: 1), item(2, 120, turn: 2), item(3, 10, turn: 2)]
        XCTAssertEqual(
            TurnTimer.start(items: items, isRunning: true, existing: nil, now: now),
            now.addingTimeInterval(-120),
            "当前这一轮（turn 2）的第一条是 120 秒前那条"
        )

        // ④ **最后一条没有 turn 时不能跳到日志最开头**（实测踩过的坑）
        let mixed = [item(1, 1800, turn: nil), item(2, 90, turn: 2), item(3, 10, turn: nil)]
        XCTAssertEqual(
            TurnTimer.start(items: mixed, isRunning: true, existing: nil, now: now),
            now.addingTimeInterval(-10),
            "退回最后一条的时间，绝不能匹配到开头那条无 turn 的"
        )

        // ⑤ 空列表 → 现在
        XCTAssertEqual(TurnTimer.start(items: [], isRunning: true, existing: nil, now: now), now)
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

        // 升版的理由，都要记住：
        //   · 加字段（审批的 callId）→ 旧缓存里 `Approval.callId` 是 nil，审批卡片认不出自己能答；
        //   · **折叠语义**变了（修好"错误地标成已隐藏"）→ 旧缓存里那个错误标记会一直生效，
        //     界面上看不出任何变化，会以为修复没生效；
        //   · 又加字段（队列项的 `isQueued`）→ 旧缓存里队列项会被当成已发出的消息渲染。
        XCTAssertEqual(TimelineBuilder.State.currentSchemaVersion, 4)
        XCTAssertNil(TimelineBuilder(state: TimelineBuilder.State(schemaVersion: 3)))
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
            // 只看"有没有解出正文"，**不设字数下限** —— 样本有长有短，
            // 短会话（比如一次 `pwd` 的两轮对话）正文本来就只有几十字。
            // "解析坏了"的信号由上面那两条（内容块数 + unknown 条数）负责，
            // 拿字数当完整性指标只会误伤短样本。
            XCTAssertGreaterThan(totalText, 0, "\(file.lastPathComponent)：助手正文一个字都没解出来")

            // 工具调用必须合并成一条一条的，而不是 call/result 各来一条
            let toolIds = builder.items.compactMap { item -> String? in
                guard case .toolCall(let call) = item.kind else { return nil }
                return call.callId
            }
            XCTAssertEqual(Set(toolIds).count, toolIds.count, "\(file.lastPathComponent)：有工具调用被渲染了两次")
        }
    }
}
