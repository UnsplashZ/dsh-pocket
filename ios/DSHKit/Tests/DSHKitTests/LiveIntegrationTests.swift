import Foundation
import XCTest

@testable import DSHKit

/// 对着**活着的 DSH** 的真实回归。
///
/// 默认跳过（保持 `swift test` 不需要任何外部依赖）。跑法：
///
/// ```bash
/// node tools/dev-proxy.mjs &                 # 注入 cookie 的 DEV-DIRECT 代理
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
            "未开启实时测试。设 DSH_LIVE=1 并先跑 node tools/dev-proxy.mjs（或指向真机代理端口）"
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
        let target = try XCTUnwrap(
            sessions.filter { !$0.sessionId.hasPrefix("im:") && $0.asOfSeq > 40 }
                .min { $0.asOfSeq < $1.asOfSeq },
            "需要一个 seq>40 的会话"
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
    func testArchiveRoundTripRestoresOriginalSet() async throws {
        try requireLive()
        let client = makeClient()
        let sessions = try await client.listSessions()
        // 必须挑**没在跑**的：DSH 会以 `workspace/session-active` 拒绝归档
        // 有活跃 turn/job 的会话（本机实测踩到过，当时挑中的正是当前会话）。
        let target = try XCTUnwrap(
            sessions.first { !$0.sessionId.hasPrefix("im:") && !$0.isRunning },
            "需要一个空闲的真实会话来验证归档往返"
        )

        var before: [String] = []
        try await withTimeout(10) {
            for try await frame in client.workspaceFollow() {
                if case .baseline(let archivedIds, _, _) = frame {
                    before = archivedIds
                    break
                }
            }
        }
        XCTAssertFalse(before.contains(target.sessionId), "挑的会话不该已经在归档里")

        let afterArchive = try await client.archiveSession(sessionId: target.sessionId)
        XCTAssertTrue(afterArchive.contains(target.sessionId), "归档后集合里应该有它")

        let afterUnarchive = try await client.unarchiveSession(sessionId: target.sessionId)
        XCTAssertFalse(afterUnarchive.contains(target.sessionId), "恢复后集合里不该有它")
        XCTAssertEqual(Set(afterUnarchive), Set(before), "往返之后应该回到原来的集合")
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
        guard let idle = sessions.first(where: { !$0.isRunning && !$0.sessionId.hasPrefix("im:") }) else {
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
        let commands = try await client.commands(sessionId: target.sessionId)
        let names = commands.compactMap { $0.string("name") }
        XCTAssertFalse(names.isEmpty, "命令清单不该是空的")
        XCTAssertTrue(names.contains("permission"),
                      "命令清单里应该有 permission，实际：\(names.prefix(8))")

        // 不带参数 → 只读当前档位
        let execution = try await client.executeCommand(sessionId: target.sessionId, line: "/permission")
        XCTAssertTrue(execution.isSuccess, "不带参数的 /permission 应当成功")
        XCTAssertTrue(execution.text.contains("preset") || execution.text.contains("current"),
                      "应当回报当前档位，实际：\(execution.text)")
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
            _ = try await client.listProjections(sessionIds: ["definitely-not-a-session"])
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
