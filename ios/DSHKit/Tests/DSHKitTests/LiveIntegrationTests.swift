import Foundation
import XCTest

@testable import DSHKit

/// 对着**活着的 DSH** 的真实回归。
///
/// 默认跳过（保持 `swift test` 不需要任何外部依赖）。跑法：
///
/// ```bash
/// node tools/direct-gateway.mjs &           # 注入 cookie 的 DEV-DIRECT 代理
/// DSH_LIVE=1 swift test --filter LiveIntegration
/// ```
///
/// 这组测试是 ADR-0009 想买到的东西：协议层的每一次真实回归都不需要手机、不需要配对。
final class LiveIntegrationTests: XCTestCase {
    private var baseURL: URL {
        let raw = ProcessInfo.processInfo.environment["DSH_BASE_URL"] ?? "http://127.0.0.1:8788"
        return URL(string: raw)!
    }

    private func requireLive() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["DSH_LIVE"] == "1",
            "未开启实时测试。设 DSH_LIVE=1 并先跑 node tools/direct-gateway.mjs（或指向真机代理端口）"
        )
    }

    private func makeClient() -> DSHClient {
        DSHClient(provider: StaticHostProvider(base: baseURL), retry: .none)
    }

    func testSessionListReturnsRealProjections() async throws {
        try requireLive()
        let sessions = try await makeClient().listSessions()
        XCTAssertFalse(sessions.isEmpty, "活服务器上应该至少有一个会话")
        for session in sessions.prefix(5) {
            XCTAssertFalse(session.sessionId.isEmpty)
            XCTAssertGreaterThan(session.asOfSeq, -2)
        }
        let titled = sessions.filter { !$0.projections.title.isNullOrEmpty }
        XCTAssertFalse(titled.isEmpty, "至少要有带标题的会话，说明 projections 解对了")
    }

    func testFollowSnapshotFoldsWithoutUnknownFlood() async throws {
        try requireLive()
        let client = makeClient()
        let sessions = try await client.listSessions()
        // 挑一个中等大小、有真实内容但不是超大快照的会话
        let candidates = sessions
            .filter { !$0.sessionId.hasPrefix("im:") && $0.asOfSeq > 5 }
            .sorted { $0.asOfSeq < $1.asOfSeq }
        let target = try XCTUnwrap(candidates.first, "需要一个有条目的会话")

        var builder = TimelineBuilder()
        var sawSnapshot = false
        var eventCount = 0

        // 有界读取：拿到快照 + 前几条实时事件就够了，到点就停（别让测试挂住）。
        try await withTimeout(20) {
            var attempts = 0
            for try await frame in client.follow(sessionId: target.sessionId, assistantStream: true) {
                switch frame {
                case .snapshot(let snapshot):
                    sawSnapshot = true
                    XCTAssertEqual(snapshot.header.id, target.sessionId)
                    XCTAssertGreaterThan(snapshot.cursor, -1)
                    _ = builder.apply(snapshot: snapshot)
                    eventCount += snapshot.events.count
                case .event(let event):
                    _ = builder.apply(event)
                    eventCount += 1
                case .assistantStream:
                    break
                }
                attempts += 1
                if attempts > 3 { break }
            }
        }

        XCTAssertTrue(sawSnapshot, "follow 的首帧必须是 snapshot")
        XCTAssertGreaterThan(eventCount, 0)
        XCTAssertFalse(builder.items.isEmpty)

        let unknown = builder.items.filter { if case .unknown = $0.kind { return true }; return false }
        XCTAssertTrue(unknown.isEmpty, "活服务器上不该有认不出的事件：\(unknown.map(\.kindName))")
    }

    func testPageBackwardsIsContiguous() async throws {
        try requireLive()
        let client = makeClient()
        let sessions = try await client.listSessions()
        // 要挑**足够长**的会话：短会话一页就到底，测不出"往前翻"。
        let target = try XCTUnwrap(
            sessions.filter { !$0.sessionId.hasPrefix("im:") && $0.asOfSeq > 300 }
                .max { $0.asOfSeq < $1.asOfSeq },
            "需要一个 seq>300 的会话"
        )

        var cursor = -1
        try await withTimeout(20) {
            for try await frame in client.follow(sessionId: target.sessionId, assistantStream: false) {
                if case .snapshot(let snapshot) = frame {
                    cursor = snapshot.cursor
                    break
                }
            }
        }
        XCTAssertGreaterThan(cursor, 0)

        let page = try await client.page(sessionId: target.sessionId, throughSeq: cursor, maxMessages: 20)
        XCTAssertFalse(page.events.isEmpty, "向上补一页应该拿到事件")

        // **真正往前翻**：返回体里没有 `cursor`，所以不能指望"用返回的游标再翻一页"。
        // 要把手里最老的 seq 传进 `beforeSeq`。不这么做的话游标永远不前进，
        // 反复点只会拿回同一页 —— 去重之后等于没动（「载入更早的内容」点了没反应）。
        let oldest = try XCTUnwrap(page.events.map(\.seq).min())
        let earlier = try await client.page(
            sessionId: target.sessionId,
            throughSeq: cursor,
            beforeSeq: Int(oldest),
            maxMessages: 20
        )
        XCTAssertFalse(earlier.events.isEmpty, "再往前一页也要拿得到")
        XCTAssertLessThan(
            try XCTUnwrap(earlier.events.map(\.seq).max()), oldest,
            "`beforeSeq` 必须真的往回翻，而不是又给一遍同一页"
        )
        XCTAssertTrue(
            Set(page.events.map(\.seq)).isDisjoint(with: Set(earlier.events.map(\.seq))),
            "两页不该有重叠"
        )
        let seqs = page.events.map(\.seq)
        XCTAssertEqual(seqs, seqs.sorted(), "页内必须按 seq 升序")
        XCTAssertEqual(Set(seqs).count, seqs.count, "页内不能有重复 seq")
        XCTAssertLessThanOrEqual(seqs.last ?? .infinity, Double(cursor), "页不能越过 throughSeq")
    }

    func testEventsStreamYieldsReadyGeneration() async throws {
        try requireLive()
        let client = makeClient()
        var generation: String?
        try await withTimeout(10) {
            var attempts = 0
            for try await event in client.events() {
                if case .ready(let clientId, let host) = event {
                    generation = clientId
                    XCTAssertFalse(clientId.isEmpty)
                    XCTAssertFalse((host.string("home") ?? "").isEmpty, "$events 的 ready 应带 host.home")
                    break
                }
                attempts += 1
                if attempts > 20 { break }
            }
        }
        XCTAssertNotNil(generation, "$events 的首帧必须是 ready")
    }

    /// `workspace/follow` 是**唯一**能拿到"哪些会话被归档了"的地方 ——
    /// `session/list` 里没有这个字段。归档没被过滤掉的表现是列表被淹没。
    func testWorkspaceFollowReportsArchivedSessions() async throws {
        try requireLive()
        let client = makeClient()
        var archived: [String]?
        var pinned: [String]?

        try await withTimeout(15) {
            for try await frame in client.workspaceFollow() {
                if case .baseline(let archivedIds, let pinnedIds, _) = frame {
                    archived = archivedIds
                    pinned = pinnedIds
                    break
                }
            }
        }

        let archivedIds = try XCTUnwrap(archived, "workspace/follow 的首帧必须是 baseline")
        XCTAssertNotNil(pinned)
        // 本机确实有归档会话（实测 30+），所以这里能验证"真的读到了东西"，
        // 而不是只验证"没崩"。
        XCTAssertFalse(archivedIds.isEmpty, "这台机器上应该有已归档的会话")
        for id in archivedIds {
            XCTAssertFalse(id.isEmpty)
        }
    }

    /// 归档 → 恢复 的往返。用一个真实存在的会话，最后恢复原状。
    ///
    /// **只断言自己那条会话的归属，不要断言"整个归档集合相等"** ——
    /// 那是一个外部共享状态：别的测试、用户自己的操作都会动它，
    /// 全集相等天然是竞态的（实测被同一次运行里的另一条测试搅红过）。
    func testArchiveRoundTripRestoresOriginalSet() async throws {
        try requireLive()
        let client = makeClient()

        func archivedNow() async throws -> Set<String> {
            var ids: [String] = []
            try await withTimeout(10) {
                for try await frame in client.workspaceFollow() {
                    if case .baseline(let archived, _, _) = frame {
                        ids = archived
                        break
                    }
                }
            }
            return Set(ids)
        }

        let before = try await archivedNow()
        let sessions = try await client.listSessions()
        // 挑一个既没在跑、也还没被归档的 —— 否则"归档它"这一步本身就是错的前提。
        let target = try XCTUnwrap(
            sessions.first { !$0.sessionId.hasPrefix("im:") && !$0.isRunning && !before.contains($0.sessionId) },
            "需要一个空闲且未归档的会话来验证归档往返"
        )

        let afterArchive = Set(try await client.archiveSession(sessionId: target.sessionId))
        XCTAssertTrue(afterArchive.contains(target.sessionId), "归档后集合里应该有它")

        let afterUnarchive = Set(try await client.unarchiveSession(sessionId: target.sessionId))
        XCTAssertFalse(afterUnarchive.contains(target.sessionId), "恢复后集合里不该有它")
        XCTAssertEqual(
            afterUnarchive.contains(target.sessionId), before.contains(target.sessionId),
            "往返之后这条会话的归属应当回到原状"
        )
    }

    /// 归档一个正在跑的会话必须被拒绝，且错误码可分类 ——
    /// App 要靠它决定"先停下来再归档"这条提示。
    func testArchivingARunningSessionIsRefused() async throws {
        try requireLive()
        let client = makeClient()
        let sessions = try await client.listSessions()
        guard let running = sessions.first(where: { $0.isRunning && !$0.sessionId.hasPrefix("im:") }) else {
            throw XCTSkip("此刻没有正在跑的会话，跳过")
        }
        do {
            _ = try await client.archiveSession(sessionId: running.sessionId)
            XCTFail("正在跑的会话不该被归档成功")
        } catch let error as DSHClientError {
            XCTAssertEqual(error.kind, .remote)
            if case .remote(let remote) = error {
                XCTAssertEqual(remote.code, "workspace/session-active")
            }
        }
    }

    /// **真的发一条消息**。
    ///
    /// 这条测试是补课：`session/prompt` 的形状（`mode` 必填、图片内联 base64）
    /// 之前是靠读源码猜的，猜错了两次，而单测只验形状、验不出"宿主收不收"。
    /// 会真的起一轮 agent（然后立刻 cancel），所以默认跳过：
    ///     DSH_LIVE_PROMPT=1 DSH_LIVE=1 swift test --filter LivePrompt
    func testLivePromptIsAccepted() async throws {
        try requireLive()
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["DSH_LIVE_PROMPT"] == "1",
            "会真的起一轮 agent。设 DSH_LIVE_PROMPT=1 才跑。"
        )
        let client = makeClient()

        // 用一个临时会话，别打扰用户正在用的那些。
        let sessionId = try await client.createSession(cwd: NSHomeDirectory())
        let requestId = RpcId.make()

        let accepted = try await client.prompt(
            sessionId: sessionId,
            requestId: requestId,
            text: "Reply with exactly: pong",
            mode: .queue
        )
        XCTAssertTrue(accepted, "session/prompt 应该被接受（形状对了才会被接受）")

        // 同 requestId 重发应该幂等接受，而不是报错
        let again = try await client.prompt(
            sessionId: sessionId,
            requestId: requestId,
            text: "Reply with exactly: pong",
            mode: .queue
        )
        XCTAssertTrue(again, "同一个 requestId 重发应当幂等")

        // 别把 agent 挂着跑
        _ = try await client.cancel(sessionId: sessionId)
    }

    /// `session/cancel` 的形状只有 `{sessionId}` —— 多发字段会被边界校验拒掉。
    /// 对空闲会话调用应当成功（无事可取消），而不是抛边界错误。
    func testCancelAcceptsBareSessionId() async throws {
        try requireLive()
        let client = makeClient()
        let sessions = try await client.listSessions()
        // 子代理会话不在选人范围：宿主对它们拒 `session/cancel`
        //（`session/agent-busy`，要求走 subagent delivery）—— 那是协议边界，
        // 不是这条用例要验的"形状校验"（KNOWN-ISSUES 一-2，2026-10-14 实测踩中）。
        guard let idle = sessions.first(where: {
            !$0.isRunning && !$0.sessionId.hasPrefix("im:") && !$0.category.isSubagent
        }) else {
            throw XCTSkip("没有空闲会话")
        }
        let result = try await client.cancel(sessionId: idle.sessionId)
        XCTAssertTrue(result, "对空闲会话 cancel 应当是成功的空操作，而不是边界校验失败")
    }

    /// `session/selectModel` 是**扁平**的 `{sessionId, provider, model}`，
    /// 套一层 `selection` 会被拒。这里用当前模型选一次当前模型（幂等）。
    func testSelectModelUsesFlatShape() async throws {
        try requireLive()
        let client = makeClient()
        let sessions = try await client.listSessions()
        guard let target = sessions.first(where: { !$0.sessionId.hasPrefix("im:") && $0.projections.modelSelection != nil }),
              let selection = target.projections.modelSelection else {
            throw XCTSkip("没有带模型信息的会话")
        }
        XCTAssertFalse(selection.provider.isEmpty, "modelSelection 应该能解出 provider（它是嵌套的 lastUsed/next）")
        XCTAssertFalse(selection.model.isEmpty, "modelSelection 应该能解出 model")
        // 选同一个模型：不改变任何状态，但会走完整条校验路径。
        try await client.selectModel(
            sessionId: target.sessionId,
            provider: selection.provider,
            model: selection.model,
            reasoningEffort: selection.reasoningEffort
        )
    }

    /// **半实时**：别人（比如电脑上的 DSH 桌面端）往一个会话里发消息时，
    /// 已经打开着 `session/follow` 的客户端应当立刻看到它。
    ///
    /// 这条直接对应"我在 dsh desktop 上发了一条新消息，但手机上没有显示"。
    /// 会真的起一轮 agent（然后立刻 cancel），默认跳过。
    func testFollowDeliversEventsAppendedByAnotherWriter() async throws {
        try requireLive()
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["DSH_LIVE_PROMPT"] == "1",
            "会真的起一轮 agent。设 DSH_LIVE_PROMPT=1 才跑。"
        )
        let client = makeClient()
        let sessionId = try await client.createSession(cwd: NSHomeDirectory())

        // 先订阅，再写 —— 这样才能证明"实时"而不是"重放"。
        let ready = expectation(description: "follow 收到快照")
        let sawUserMessage = expectation(description: "follow 收到新写入的 user/message")
        let writer = Task {
            // 等订阅建立
            try await Task.sleep(for: .milliseconds(400))
            _ = try await client.prompt(
                sessionId: sessionId,
                requestId: RpcId.make(),
                text: "Reply with exactly: pong",
                mode: .queue
            )
        }

        let reader = Task {
            var sawSnapshot = false
            for try await frame in client.follow(sessionId: sessionId, assistantStream: false) {
                switch frame {
                case .snapshot:
                    if !sawSnapshot {
                        sawSnapshot = true
                        ready.fulfill()
                    }
                case .event(let event):
                    if event.type == "user/message", event.string("data.source.kind") == "user" {
                        sawUserMessage.fulfill()
                        return
                    }
                case .assistantStream:
                    break
                }
            }
        }

        await fulfillment(of: [ready], timeout: 20)
        await fulfillment(of: [sawUserMessage], timeout: 25)
        reader.cancel()
        _ = try? await writer.value
        _ = try await client.cancel(sessionId: sessionId)
    }

    /// 权限档位：catalog 只读，改档位走 `/permission <preset>` 这个斜杠命令。
    ///
    /// 这里**只跑不带参数的 `/permission`** —— 它只打印当前档位，不改任何东西，
    /// 所以可以随便跑。真正改权限的操作不能进自动化测试。
    func testPermissionCatalogAndCommandPath() async throws {
        try requireLive()
        let client = makeClient()

        let catalog = try await client.permissionPresets()
        XCTAssertFalse(catalog.options.isEmpty, "应该有可选的权限档位")
        XCTAssertTrue(catalog.options.contains { $0.value == "read-only" })
        XCTAssertTrue(catalog.options.contains { $0.value == "workspace-write" })

        let sessions = try await client.listSessions()
        guard let target = sessions.first(where: { !$0.sessionId.hasPrefix("im:") && !$0.isRunning }) else {
            throw XCTSkip("没有空闲会话")
        }

        // 命令清单里必须有 permission（每条是对象，取 name 字段）
        let commands = try await client.listCommands(sessionId: target.sessionId)
        let names = commands.map(\.name)
        XCTAssertFalse(names.isEmpty, "命令清单不该是空的")
        XCTAssertTrue(names.contains("permission"),
                      "命令清单里应该有 permission，实际：\(names.prefix(8))")

        // 不带参数 → 只读当前档位
        let execution = try await client.executeCommand(sessionId: target.sessionId, line: "/permission")
        XCTAssertTrue(execution.isSuccess, "不带参数的 /permission 应当成功")
        XCTAssertTrue(execution.text.contains("preset") || execution.text.contains("current"),
                      "应当回报当前档位，实际：\(execution.text)")
    }

    /// 在指定工作区里建会话，并确认它**真的落在那个工作区下**。
    ///
    /// 这条是"选完工作区不生效、会话跑到「未分组」"的回归：只传 `cwd` 建出来的会话
    /// 不会挂到工作区上，必须传 `workspaceId`。实测过一次，确认会话会出现在
    /// 该工作区的 `sessionIds` 里。
    func testCreateSessionLandsInTheChosenWorkspace() async throws {
        try requireLive()
        let client = makeClient()

        var workspaces: [WorkspaceSummary] = []
        try await withTimeout(15) {
            for try await frame in client.workspaceFollow() {
                if case .baseline(_, _, let items) = frame {
                    workspaces = items
                    break
                }
            }
        }
        let target = try XCTUnwrap(workspaces.first, "至少需要一个工作区")

        let sessionId = try await client.createSession(workspaceId: target.id)
        XCTAssertFalse(sessionId.isEmpty)

        // 等宿主的 workspace 视图更新
        var landed = false
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(300))
            var current: [WorkspaceSummary] = []
            try await withTimeout(10) {
                for try await frame in client.workspaceFollow() {
                    if case .baseline(_, _, let items) = frame {
                        current = items
                        break
                    }
                }
            }
            if current.first(where: { $0.id == target.id })?.sessionIds.contains(sessionId) == true {
                landed = true
                break
            }
        }
        XCTAssertTrue(landed, "新建的会话应该出现在工作区 \(target.title) 的 sessionIds 里（否则电脑端会显示「未分组」）")

        // 收尾：归档掉这个测试会话，别留在用户列表里
        _ = try? await client.archiveSession(sessionId: sessionId)
    }

    /// **端到端**验证"用户回答 agent 的提问"这条链路真的通。
    ///
    /// 之前这里是坏的：`AppModel.route` 对提问返回"我不答"，协调器立刻回 `{kind:'next'}`
    /// 并清掉 pending —— 于是界面上弹出了问题卡片、点提交却毫无作用，agent 只能等到超时。
    ///
    /// 这条测试把整条链路跑一遍：真的让 agent 提问 → 拿到 waterfall → **挂起** →
    /// 用 `respond` 把答案交回去 → 断言 agent 收到了这个答案并继续跑完。
    ///
    /// 会真的起两轮 agent，默认跳过：`DSH_LIVE_PROMPT=1`。
    func testUserQuestionRoundTripActuallyReachesTheAgent() async throws {
        try requireLive()
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["DSH_LIVE_PROMPT"] == "1",
            "会真的起 agent。设 DSH_LIVE_PROMPT=1 才跑。"
        )
        let client = makeClient()
        let sessionId = try await client.createSession(cwd: NSHomeDirectory())
        defer { Task { _ = try? await client.cancel(sessionId: sessionId) } }

        // 新会话没有默认模型，不选会直接 `session/model-unavailable`。
        let catalog = try await client.modelCatalog()
        if let fallback = catalog.defaultSelection {
            try await client.selectModel(
                sessionId: sessionId,
                provider: fallback.provider,
                model: fallback.model,
                reasoningEffort: fallback.reasoningEffort
            )
        }

        let coordinator = EventStreamCoordinator(client: client)
        let seen = AsyncStream.makeStream(of: WaterfallRequest.self)
        await coordinator.setAnswerer { request in
            // **只认这个会话的提问**：宿主会把别的会话里未决的 waterfall 一并重放给
            // 新客户端（实测：一次连接里收到三条来自不同会话的），不做过滤就会答错人。
            guard request.isUserQuestion, request.agentId == sessionId else { return .next }
            seen.continuation.yield(request)
            // **挂起** —— 这正是被修掉的那个 bug 所在的位置。
            return .deferred
        }
        await coordinator.start()
        defer { Task { await coordinator.stop() } }

        _ = try await client.prompt(
            sessionId: sessionId,
            requestId: RpcId.make(),
            text: """
            Call the ask_user_question tool exactly once: ask which color I prefer, \
            with header "Color", question id "color", and exactly two options: Red and Blue. \
            Output nothing else.
            """,
            mode: .queue
        )

        var request: WaterfallRequest?
        for await candidate in seen.stream {
            request = candidate
            break
        }
        let question = try XCTUnwrap(request, "40 秒内应当收到 user-questions/request")
        XCTAssertFalse(question.questions.isEmpty)
        XCTAssertNil(question.questionCallId, "网关转发时会把 wait/callId 剥掉，远端只能按 eventId 回")

        // 挂起状态：这时候答，必须还能送达。
        let pending = await coordinator.isPending(eventId: question.eventId)
        XCTAssertTrue(pending, "deferred 之后这条 waterfall 必须还挂着，否则回答案就是白发")

        let answers = question.questions.map { item in
            (id: item.id, selected: [item.options.first?.label ?? "Red"], custom: String?.none)
        }
        await coordinator.respond(question, outcome: WaterfallRequest.answersOutcome(answers))

        // agent 应当收到答案、恢复、跑完
        var finished = false
        for _ in 0..<40 {
            try await Task.sleep(for: .seconds(2))
            let sessions = try await client.listSessions()
            if sessions.first(where: { $0.sessionId == sessionId })?.isRunning == false {
                finished = true
                break
            }
        }
        XCTAssertTrue(finished, "回答之后 agent 应当恢复并跑完（否则就是答案没送到，它会一直等到超时）")

        // 答案内容要真的落进日志：`ask_user_question` 的 tool/result 里应当出现所选标签
        var resultText = ""
        for try await frame in client.follow(sessionId: sessionId, assistantStream: false) {
            guard case .snapshot(let snapshot) = frame else { break }
            for event in snapshot.events {
                // `tool/result` 的正文在 `data.message.content[].text` ——
                // **不是** `data.output`，也没有 `data.name`（名字只在 `tool/call` 上）。
                if event.type == "tool/result" {
                    resultText += (event.data.array("message.content") ?? [])
                        .compactMap { $0.string("text") }
                        .joined(separator: "\n")
                }
                // 用户的回答还会作为一条 `user-question-reply` 消息进日志
                if event.type == "user/message",
                   event.string("data.source.kind") == "user-question-reply" {
                    resultText += (event.data.array("content") ?? [])
                        .compactMap { $0.string("text") }
                        .joined(separator: "\n")
                }
            }
            break
        }
        XCTAssertTrue(
            resultText.contains("Red"),
            "日志里应当能看到这次回答的内容，实际：\(resultText.prefix(200))"
        )

        _ = try? await client.archiveSession(sessionId: sessionId)
    }

    /// 消息评价的线上形状是**扁平的**，不是那个带 `item` 的 TS 接口：
    /// `put({request:{sessionId, messageId, rating, ifVersion}})`。
    /// `ifVersion` 是必填（没有就传 `null`），漏了会被边界校验拒掉。
    ///
    /// 走一遍 put → list → delete，并在最后**删干净**（评价会落进会话日志，
    /// 不该在用户的历史里留垃圾）。
    func testMessageFeedbackRoundTrip() async throws {
        try requireLive()
        let client = makeClient()
        let sessions = try await client.listSessions()
        let target = try XCTUnwrap(
            sessions.first { !$0.sessionId.hasPrefix("im:") && !$0.isRunning },
            "需要一个空闲会话"
        )

        // 找一条真实的助手消息
        var messageId: String?
        var seq: Int?
        try await withTimeout(20) {
            for try await frame in client.follow(sessionId: target.sessionId, assistantStream: false) {
                if case .snapshot(let snapshot) = frame {
                    for event in snapshot.events where event.type == "assistant/message" {
                        if let id = event.string("data.message.id") { messageId = id; seq = Int(event.seq) }
                    }
                    break
                }
            }
        }
        guard let messageId, let seq else { throw XCTSkip("这个会话里没有助手消息") }

        // put（新建）
        let saved = try await client.putMessageFeedback(
            sessionId: target.sessionId, messageId: messageId, rating: .positive, ifVersion: nil
        )
        let created = try XCTUnwrap(saved)
        XCTAssertEqual(created.rating, .positive)
        XCTAssertFalse(created.version.isEmpty, "要拿到版本，改/删时当 ifVersion 传回去")

        // list 里能看到
        let listed = try await client.messageFeedback(sessionId: target.sessionId)
        XCTAssertTrue(listed.contains { $0.messageId == messageId && $0.rating == .positive })

        // 用**旧版本**再改应当被拒（乐观并发控制）。
        // 注意这是**业务级**拒绝（HTTP 200 + `{ok:false, error:{code}}`），
        // 所以必须显式识别，否则会以为"保存成功了"。
        do {
            _ = try await client.putMessageFeedback(
                sessionId: target.sessionId, messageId: messageId, rating: .negative, ifVersion: "不存在的版本"
            )
            XCTFail("版本对不上时应当被拒，而不是悄悄覆盖")
        } catch let error as DSHClientError {
            XCTAssertTrue(error.isVersionConflict, "应当是版本冲突，实际：\(error.displayMessage)")
        }

        // 改成 negative（带正确版本）
        let updated = try await client.putMessageFeedback(
            sessionId: target.sessionId, messageId: messageId, rating: .negative, ifVersion: created.version
        )
        XCTAssertEqual(updated?.rating, .negative)

        // 撤销 + 确认清干净
        _ = try await client.deleteMessageFeedback(
            sessionId: target.sessionId, messageId: messageId, ifVersion: try XCTUnwrap(updated?.version)
        )
        let after = try await client.messageFeedback(sessionId: target.sessionId)
        XCTAssertFalse(after.contains { $0.messageId == messageId }, "删掉之后不该还在")
        XCTAssertGreaterThan(seq, 0)
    }

    /// 分支：`session/fork({sessionId, atSeq?})` → 新会话 id。
    /// 跑完**归档**掉分出来的那条，别留在用户列表里。
    func testForkCreatesANewSession() async throws {
        try requireLive()
        let client = makeClient()
        let sessions = try await client.listSessions()
        let target = try XCTUnwrap(
            sessions.first { !$0.sessionId.hasPrefix("im:") && $0.asOfSeq > 20 },
            "需要一个有内容的会话"
        )

        let forked = try await client.forkSession(sessionId: target.sessionId, atSeq: 20)
        XCTAssertNotEqual(forked, target.sessionId)
        XCTAssertTrue(forked.hasPrefix("session-"))

        let all = try await client.listSessions()
        XCTAssertTrue(all.contains { $0.sessionId == forked }, "分出来的会话应当出现在列表里")

        // 收尾：别留在用户列表里
        _ = try? await client.archiveSession(sessionId: forked)
    }

    /// `agentPresets/list` 的返回是 `{presets:[…]}`，而且**大部分 preset 只有 id** ——
    /// 界面必须能接受"没有名字和说明"，否则会显示空白行。
    func testAgentPresetListAgainstLiveHost() async throws {
        try requireLive()
        let client = makeClient()
        let presets = try await client.agentPresets()
        XCTAssertFalse(presets.isEmpty, "主机上应当有可选的 preset")
        XCTAssertTrue(presets.contains { $0.isDefault }, "应当有一个默认的")
        for preset in presets {
            XCTAssertFalse(preset.id.isEmpty)
            XCTAssertFalse(preset.title.isEmpty, "缺名字时要退回 id，不能是空的")
        }
        // order 是排序依据，得是递增的
        XCTAssertEqual(presets.map(\.order), presets.map(\.order).sorted())
    }

    /// **新建的会话不会自动套用主机默认模型。**
    ///
    /// 实测：`session/create` 之后 `modelSelection` 是 `{lastUsed: null, next: null}`，
    /// 于是主机退回**模型的第一档**思考等级（本机是 `low`），
    /// 而用户在电脑上设的是 `high` —— 这就是"新对话默认思考等级是 low"的原因。
    ///
    /// 主机有个 `session/initializeDefaultModel`，但它是**内部接口**
    /// （参数名带下划线 `_request`，远端两种形状都被拒），所以只能
    /// 自己拿 `modelCatalog.default` 去 `selectModel`。
    ///
    /// 这条测试把这个行为钉住：**别指望 create 会带上默认**。
    func testNewSessionDoesNotInheritTheDefaultModel() async throws {
        try requireLive()
        let client = makeClient()

        let id = try await client.createSession(workspaceId: nil, cwd: NSHomeDirectory())
        defer { Task { _ = try? await client.archiveSession(sessionId: id) } }

        let before = try await client.sessionProjections(sessionId: id)
        let beforeSelection = before["values"]?["modelSelection"]
        XCTAssertNil(beforeSelection?["next"]?.string("provider"), "新建的会话不该已经有模型选择")
        XCTAssertNil(beforeSelection?["next"]?.string("reasoningEffort"))

        // 主机默认必须是**完整的**（含思考等级），否则套上去也没用
        let catalog = try await client.modelCatalog()
        let fallback = try XCTUnwrap(catalog.defaultSelection, "主机应当给出默认模型")
        XCTAssertFalse(fallback.provider.isEmpty)
        XCTAssertFalse(fallback.model.isEmpty)

        try await client.selectModel(
            sessionId: id,
            provider: fallback.provider,
            model: fallback.model,
            reasoningEffort: fallback.reasoningEffort
        )

        let after = try await client.sessionProjections(sessionId: id)
        let next = try XCTUnwrap(after["values"]?["modelSelection"]?["next"])
        XCTAssertEqual(next.string("provider"), fallback.provider)
        XCTAssertEqual(next.string("model"), fallback.model)
        XCTAssertEqual(next.string("reasoningEffort"), fallback.reasoningEffort,
                       "思考等级要跟主机默认一致，不能退回模型的第一档")
    }

    func testModelCatalogAndUnaryErrorShape() async throws {
        try requireLive()
        let client = makeClient()
        let catalog = try await client.modelCatalog()
        XCTAssertFalse(catalog.isEmpty, "modelCatalog 应该解出至少一个分组（形状是 groups[].models[]）")
        XCTAssertFalse(catalog.allModels.isEmpty)
        for group in catalog.groups {
            XCTAssertFalse(group.name.isEmpty, "每个分组都该有名字")
            for model in group.models {
                XCTAssertFalse(model.id.isEmpty)
                XCTAssertFalse(model.name.isEmpty)
            }
        }

        // 未知方法 → 业务错误（HTTP 200 + result.ok=false）或 404，两种都要能被识别成错误。
        do {
            _ = try await client.sessionProjections(sessionId: "definitely-not-a-session")
            // 有的部署对未知 id 返回空列表而不是错误 —— 那也算通过。
        } catch let error as DSHClientError {
            XCTAssertTrue(
                [.remote, .notFound, .transport].contains(error.kind),
                "未知 id 应给出可分类的错误，实际 \(error.kind)"
            )
        }
    }

    func testWaterfallAnswerRejectsUnknownEventIdGracefully() async throws {
        try requireLive()
        // 不是真的 waterfall（eventId 不存在）：宿主应该给出可分类的错误，而不是崩。
        do {
            try await makeClient().answerEvent(clientId: "no-such-generation", eventId: "no-such-event", outcome: .object(["kind": .string("next")]))
        } catch let error as DSHClientError {
            XCTAssertTrue([.remote, .notFound, .transport, .disconnected].contains(error.kind))
        }
    }
}

private extension Optional where Wrapped == String {
    var isNullOrEmpty: Bool {
        switch self {
        case .none: return true
        case .some(let value): return value.isEmpty
        }
    }
}

/// 有界的异步读取：到点就返回 `nil`，绝不让测试无限等下去。
@discardableResult
func withTimeout<T: Sendable>(
    _ seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T? {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let first = try await group.next()
        group.cancelAll()
        return first ?? nil
    }
}
