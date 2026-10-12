import DSHKit
import SwiftUI
import TetherKit
import XCTest

@testable import DSHPocket

/// App 层单测：只测**纯逻辑**（设置、模式切换、Markdown 切分、格式化）。
/// 协议与传输的正确性由 `ios/DSHKit/Tests`、`ios/TetherKit/Tests` 用 `swift test` 覆盖，
/// 这里不重复造。
final class AppLogicTests: XCTestCase {
    // MARK: 设置

    @MainActor
    func testSettingsRoundTrip() {
        let suite = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        defer { suite.removePersistentDomain(forName: suite.description) }

        let settings = AppSettings(defaults: suite)
        XCTAssertEqual(settings.appearance, .system, "默认跟随系统")
        XCTAssertFalse(settings.notifications.anyEnabled, "通知默认全关：权限只在用户打开开关时才请求")
        XCTAssertFalse(settings.showRawEvents)
        XCTAssertFalse(settings.hasOnboarded)

        settings.appearance = .dark
        settings.notifications.approvals = true
        settings.showRawEvents = true
        settings.hasOnboarded = true
        settings.activeHostId = "abc"

        let reloaded = AppSettings(defaults: suite)
        XCTAssertEqual(reloaded.appearance, .dark)
        XCTAssertTrue(reloaded.notifications.approvals)
        XCTAssertFalse(reloaded.notifications.questions)
        XCTAssertTrue(reloaded.showRawEvents)
        XCTAssertTrue(reloaded.hasOnboarded)
        XCTAssertEqual(reloaded.activeHostId, "abc")
    }

    @MainActor
    func testDisplayNameIsTrimmedAndBounded() {
        let suite = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        defer { suite.removePersistentDomain(forName: suite.description) }
        let settings = AppSettings(defaults: suite)

        settings.displayName = "   "
        XCTAssertEqual(settings.sanitizedDisplayName, "iPhone", "空名字要有兜底")

        settings.displayName = String(repeating: "名", count: 100)
        XCTAssertEqual(settings.sanitizedDisplayName.count, 40, "未配对首行有 512 字节硬上限，名字必须短")

        settings.displayName = "  我的手机  "
        XCTAssertEqual(settings.sanitizedDisplayName, "我的手机")
    }

    func testAppearanceMapsToColorScheme() {
        XCTAssertNil(AppearancePreference.system.colorScheme)
        XCTAssertEqual(AppearancePreference.light.colorScheme, .light)
        XCTAssertEqual(AppearancePreference.dark.colorScheme, .dark)
    }

    // MARK: 格式化

    func testRelativeTimeReadsNaturally() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(Format.relativeTime(now.addingTimeInterval(-5), now: now), "刚刚")
        XCTAssertFalse(Format.relativeTime(now.addingTimeInterval(-3600), now: now).isEmpty)
        XCTAssertFalse(Format.relativeTime(now.addingTimeInterval(-86_400 * 30), now: now).isEmpty)
    }

    func testDurationFormatting() {
        XCTAssertEqual(Format.duration(0.045), "45 毫秒")
        XCTAssertEqual(Format.duration(2.24), "2.2 秒")
        XCTAssertEqual(Format.duration(125), "2 分 5 秒")
        XCTAssertNil(Format.duration(nil))
        XCTAssertNil(Format.duration(-1))
    }

    func testTokenFormatting() {
        XCTAssertEqual(Format.tokens(999), "999")
        XCTAssertEqual(Format.tokens(12_345), "12.3k")
        XCTAssertEqual(Format.tokens(2_500_000), "2.5M")
    }

    func testContextPressureFormatting() {
        let pressure = ContextPressure(json: Fixture.json(#"{"pressureTokens":62250,"projectedTokens":62446,"contextWindow":1000000}"#))
        XCTAssertEqual(Format.contextPressure(pressure), "6% · 62.4k / 1.0M")
        XCTAssertNil(Format.contextPressure(nil))
        XCTAssertNil(Format.contextPressure(ContextPressure(json: .object([:]))), "窗口为 0 时不该显示百分比")
    }

    // MARK: Markdown 切分

    func testMarkdownSegmentsSplitCodeFences() {
        let text = """
        先说结论。

        ```swift
        let a = 1
        ```

        就这样。
        """
        let segments = MarkdownBody.segments(of: text)
        XCTAssertEqual(segments.count, 3)
        guard case .prose(let first) = segments[0] else { return XCTFail("第一段应是散文") }
        XCTAssertEqual(first, "先说结论。")
        guard case .code(let code, let language) = segments[1] else { return XCTFail("第二段应是代码") }
        XCTAssertEqual(language, "swift")
        XCTAssertEqual(code, "let a = 1")
        guard case .prose(let last) = segments[2] else { return XCTFail("第三段应是散文") }
        XCTAssertEqual(last, "就这样。")
    }

    func testMarkdownSegmentsExtractHeadings() {
        let text = """
        # 一级
        ## 二级
        正文
        ### 三级
        """
        let segments = MarkdownBody.segments(of: text)
        let headings = segments.compactMap { segment -> (Int, String)? in
            if case .heading(let level, let text) = segment { return (level, text) }
            return nil
        }
        XCTAssertEqual(headings.map(\.0), [1, 2, 3])
        XCTAssertEqual(headings.map(\.1), ["一级", "二级", "三级"])
        // `#` 不是标题时要留在正文里（例如 C 语言的 #include）
        let include = MarkdownBody.segments(of: "#include <stdio.h>")
        XCTAssertEqual(include.count, 1)
        guard case .prose(let line) = include[0] else { return XCTFail() }
        XCTAssertEqual(line, "#include <stdio.h>")
    }

    func testMarkdownSegmentsHandleUnclosedFence() {
        let segments = MarkdownBody.segments(of: "前文\n```\n未闭合的代码")
        XCTAssertEqual(segments.count, 2)
        guard case .code(let code, _) = segments[1] else { return XCTFail() }
        XCTAssertEqual(code, "未闭合的代码")
    }

    func testMarkdownSegmentsOnEmptyInput() {
        XCTAssertTrue(MarkdownBody.segments(of: "").isEmpty)
    }

    // MARK: 主机协调器

    @MainActor
    func testHostCoordinatorDevDirectMode() async throws {
        let suite = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        defer { suite.removePersistentDomain(forName: suite.description) }
        let settings = AppSettings(defaults: suite)
        settings.transportMode = .devDirect
        settings.devDirectBaseURL = "http://127.0.0.1:8788"

        let session = TetherSession(store: EphemeralSecretStore(), deviceName: "test")
        let coordinator = HostCoordinator(settings: settings, session: session)

        XCTAssertEqual(coordinator.mode, .devDirect("http://127.0.0.1:8788"))
        let base = try await coordinator.baseURL()
        XCTAssertEqual(base.absoluteString, "http://127.0.0.1:8788")
        let socket = try await coordinator.webSocketURL()
        XCTAssertEqual(socket.absoluteString, "ws://127.0.0.1:8788")
        let ready = await coordinator.isReady()
        XCTAssertTrue(ready)
    }

    @MainActor
    func testHostCoordinatorRefusesToFakeConnectivity() async {
        let suite = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        defer { suite.removePersistentDomain(forName: suite.description) }
        let settings = AppSettings(defaults: suite)
        settings.transportMode = .remote

        let session = TetherSession(store: EphemeralSecretStore(), deviceName: "test")
        let coordinator = HostCoordinator(settings: settings, session: session)

        // 没连上就必须抛 notConnected，绝不能"假在线"（IOS-DESIGN §10 反模式）
        do {
            _ = try await coordinator.baseURL()
            XCTFail("未连接时不该给出基址")
        } catch let error as DSHTransportError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("错误的错误类型：\(error)")
        }
        let ready = await coordinator.isReady()
        XCTAssertFalse(ready)
    }

    // MARK: 新建会话的工作区

    /// `session/create` 的 `cwd` **必须是绝对路径**。列表里显示的是 basename，
    /// 直接拿它当路径传会被宿主拒：
    /// `session header cwd must be an absolute path, got "dsh-pocket"`。
    /// 这就是"选完工作区没反应"的根因。
    @MainActor
    func testWorkspaceTargetsCarryAbsolutePathsNotDisplayNames() {
        let sessions = [
            makeSummary(id: "a", title: "A", updatedAt: 100, cwd: "/Users/example/dev/Github/dsh-pocket"),
            makeSummary(id: "b", title: "B", updatedAt: 200, cwd: "/Users/example/dev/Github/dsh-pocket"),
            makeSummary(id: "c", title: "C", updatedAt: 300, cwd: "/Users/example/dev/Github/analytics"),
        ]
        let targets = SessionPartition.workspaceTargets(sessions, archived: [])
        XCTAssertEqual(targets.map(\.cwd).sorted(), ["/Users/example/dev/Github/analytics", "/Users/example/dev/Github/dsh-pocket"])
        XCTAssertTrue(targets.allSatisfy { $0.cwd.hasPrefix("/") }, "传给 session/create 的必须是绝对路径")
        XCTAssertEqual(targets.first { $0.cwd.hasSuffix("dsh-pocket") }?.sessionCount, 2)
        XCTAssertEqual(targets.first { $0.cwd.hasSuffix("dsh-pocket") }?.name, "dsh-pocket", "显示名仍用 basename")
    }

    /// 同名不同目录的工作区不能被合并成一个 —— id 用完整路径。
    @MainActor
    func testWorkspaceTargetsDoNotMergeSameNamedDirectories() {
        let sessions = [
            makeSummary(id: "a", title: "A", updatedAt: 100, cwd: "/work/one/Github"),
            makeSummary(id: "b", title: "B", updatedAt: 200, cwd: "/work/two/Github"),
        ]
        let targets = SessionPartition.workspaceTargets(sessions, archived: [])
        XCTAssertEqual(targets.count, 2, "同名不同目录必须分开")
        XCTAssertEqual(Set(targets.map(\.id)).count, 2)
    }

    // MARK: 连接方式

    @MainActor
    func testTransportModeMigratesFromLegacyDevDirectFlag() {
        let suite = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        defer { suite.removePersistentDomain(forName: suite.description) }

        // 老版本只有 devDirectEnabled 这个开关：打开过就要迁移成 .devDirect，
        // 否则用户升级之后会莫名其妙地又走回 iroh。
        suite.set(true, forKey: "settings.devDirect")
        XCTAssertEqual(AppSettings(defaults: suite).transportMode, .devDirect)

        suite.set(false, forKey: "settings.devDirect")
        XCTAssertEqual(AppSettings(defaults: suite).transportMode, .remote)
    }

    @MainActor
    func testTransportModeRoundTrip() {
        let suite = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        defer { suite.removePersistentDomain(forName: suite.description) }
        let settings = AppSettings(defaults: suite)
        settings.transportMode = .directGateway
        settings.gatewayURL = "http://100.64.0.1:8788"
        settings.gatewayToken = "s3cret"

        let reloaded = AppSettings(defaults: suite)
        XCTAssertEqual(reloaded.transportMode, .directGateway)
        XCTAssertEqual(reloaded.gatewayURL, "http://100.64.0.1:8788")
        XCTAssertEqual(reloaded.gatewayToken, "s3cret")
    }

    @MainActor
    func testDirectGatewaySendsBearerTokenOnEveryRequest() async throws {
        let suite = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        defer { suite.removePersistentDomain(forName: suite.description) }
        let settings = AppSettings(defaults: suite)
        settings.transportMode = .directGateway
        settings.gatewayURL = "http://100.64.0.1:8788"
        settings.gatewayToken = "s3cret"

        let session = TetherSession(store: EphemeralSecretStore(), deviceName: "test")
        let coordinator = HostCoordinator(settings: settings, session: session)

        let base = try await coordinator.baseURL()
        XCTAssertEqual(base.absoluteString, "http://100.64.0.1:8788")
        let headers = await coordinator.requestHeaders()
        XCTAssertEqual(headers["Authorization"], "Bearer s3cret")

        // 地址只填 host:port（没写 scheme）时也要能用
        settings.gatewayURL = "100.64.0.1:8788"
        let bare = try await coordinator.baseURL()
        XCTAssertEqual(bare.absoluteString, "http://100.64.0.1:8788")
    }

    @MainActor
    func testRemoteModeDoesNotSendGatewayToken() async throws {
        let suite = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        defer { suite.removePersistentDomain(forName: suite.description) }
        let settings = AppSettings(defaults: suite)
        settings.transportMode = .remote
        settings.gatewayToken = "s3cret"   // 就算填了，iroh 路径也不该带上

        let session = TetherSession(store: EphemeralSecretStore(), deviceName: "test")
        let coordinator = HostCoordinator(settings: settings, session: session)
        let headers = await coordinator.requestHeaders()
        XCTAssertTrue(headers.isEmpty, "iroh 路径靠配对白名单，不需要也不该带网关令牌")
    }

    // MARK: 归档分流

    @MainActor
    func testArchivedSessionsAreKeptOutOfTheList() {
        let sessions = [
            makeSummary(id: "a", title: "在用的一号", updatedAt: 300),
            makeSummary(id: "b", title: "归档的二号", updatedAt: 200),
            makeSummary(id: "c", title: "在用的三号", updatedAt: 100),
        ]
        let archived: Set<String> = ["b"]

        let active = SessionPartition.active(sessions, archived: archived)
        XCTAssertEqual(active.map(\.sessionId), ["a", "c"], "归档的不能留在对话列表里")

        let archivedList = SessionPartition.archived(sessions, archived: archived)
        XCTAssertEqual(archivedList.map(\.sessionId), ["b"])
    }

    @MainActor
    func testArchivedListIsSortedByRecencyAndSurvivesUnknownIds() {
        let sessions = [
            makeSummary(id: "old", title: "旧的", updatedAt: 100),
            makeSummary(id: "new", title: "新的", updatedAt: 900),
        ]
        // 归档集合里可能有 session/list 还没返回的 id（两条流到达顺序不定）——
        // 不能因此崩，也不能把别的会话误判成归档。
        let archived: Set<String> = ["old", "new", "not-yet-loaded"]
        let list = SessionPartition.archived(sessions, archived: archived)
        XCTAssertEqual(list.map(\.sessionId), ["new", "old"], "归档列表按最近更新排序")
        XCTAssertEqual(SessionPartition.active(sessions, archived: archived).count, 0)
    }

    private func makeSummary(
        id: String,
        title: String,
        updatedAt: TimeInterval,
        cwd: String = "/Users/example/dev/Github/demo",
        origin: String? = nil,
        parentSessionId: String? = nil
    ) -> SessionSummary {
        var object: [String: JSONValue] = [
            "sessionId": .string(id),
            "updatedAt": .number(updatedAt * 1000),
            "agentAvailable": .bool(true),
            "running": .bool(false),
            "blank": .bool(false),
            "cwd": .string(cwd),
            "projections": .object([
                "kind": .string("sequenced"),
                "asOfSeq": .number(1),
                "values": .object(["title": .string(title)]),
            ]),
        ]
        if let origin { object["origin"] = .string(origin) }
        if let parentSessionId { object["parentSessionId"] = .string(parentSessionId) }
        return SessionSummary.decode(.object(object))!
    }

    // MARK: 会话分流（子代理 / 频道 / 工作区）

    @MainActor
    func testSubagentSessionsNeverReachTheList() {
        let sessions = [
            makeSummary(id: "session-aaa", title: "普通会话", updatedAt: 300),
            makeSummary(id: "session-bbb", title: "子代理", updatedAt: 400, origin: "subagent"),
            makeSummary(id: "session-ccc", title: "带父会话", updatedAt: 500, parentSessionId: "session-aaa"),
        ]
        // 官方工作区 UI 也是这么过滤的：origin === 'subagent' 一律不进主列表。
        for scope in SessionScope.allCases {
            let ids = SessionPartition.inScope(sessions, scope: scope).map(\.sessionId)
            XCTAssertFalse(ids.contains("session-bbb"), "\(scope) 不该显示子代理会话")
            XCTAssertFalse(ids.contains("session-ccc"), "\(scope) 不该显示带父会话的子会话")
        }
        XCTAssertEqual(SessionPartition.inScope(sessions, scope: .sessions).map(\.sessionId), ["session-aaa"])
    }

    @MainActor
    func testChannelSessionsAreTheirOwnScope() {
        let sessions = [
            makeSummary(id: "session-aaa", title: "普通会话", updatedAt: 100),
            makeSummary(id: "im:feishu_ab12cd34ef56:dm:1:oc_x", title: "飞书群", updatedAt: 200),
            makeSummary(id: "im:weixin_31b4a82a1195:dm:2:o9cq@im.wechat", title: "微信", updatedAt: 300),
        ]
        XCTAssertEqual(SessionPartition.inScope(sessions, scope: .sessions).map(\.sessionId), ["session-aaa"])

        let channels = SessionPartition.inScope(sessions, scope: .channels)
        XCTAssertEqual(channels.count, 2)
        XCTAssertEqual(channels.map { $0.category.channelLabel }, ["Feishu", "Weixin"])
    }

    func testChannelNameExtraction() {
        XCTAssertNil(SessionSummary.channelName(from: "session-aaa"))
        XCTAssertEqual(SessionSummary.channelName(from: "im:feishu_ab12cd34ef56:dm:1791780245515:oc_x"), "feishu")
        XCTAssertEqual(SessionSummary.channelName(from: "im:weixin_31b4a82a1195:dm:1:o9cq"), "weixin")
        XCTAssertEqual(SessionSummary.channelName(from: "im:plain:dm:1:x"), "plain")
        XCTAssertEqual(SessionSummary.channelName(from: "im:"), "im")
    }

    @MainActor
    func testWorkspaceFilter() {
        let sessions = [
            makeSummary(id: "a", title: "A", updatedAt: 100, cwd: "/Users/example/dev/Github/dsh-pocket"),
            makeSummary(id: "b", title: "B", updatedAt: 200, cwd: "/Users/example/dev/Github/analytics"),
        ]
        XCTAssertEqual(SessionPartition.inScope(sessions, scope: .sessions).count, 2)
        XCTAssertEqual(
            SessionPartition.inScope(sessions, scope: .sessions, workspace: "dsh-pocket").map(\.sessionId),
            ["a"]
        )
        XCTAssertTrue(SessionPartition.inScope(sessions, scope: .sessions, workspace: "不存在的").isEmpty)
    }

    // MARK: 依赖注入的合理性

    @MainActor
    func testAppModelStartsIdleAndDoesNotPretendToBeConnected() {
        let suite = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        defer { suite.removePersistentDomain(forName: suite.description) }
        let model = AppModel(settings: AppSettings(defaults: suite))

        XCTAssertEqual(model.connection, .idle)
        XCTAssertFalse(model.connection.isConnected)
        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertTrue(model.pendingApprovals.isEmpty, "App 永不自动决策：待审批队列初始为空")
        XCTAssertTrue(model.pendingQuestions.isEmpty)
    }

    @MainActor
    func testArchivingUnknownSessionIsHarmless() async {
        let suite = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        defer { suite.removePersistentDomain(forName: suite.description) }
        let model = AppModel(settings: AppSettings(defaults: suite))
        // 未连接时归档只是把错误记下来，不该崩、也不该假装成功
        await model.archive("session-does-not-exist")
        XCTAssertTrue(model.sessions.isEmpty)
    }
}

/// 与 DSHKit 测试同款的 JSON 构造助手（这里只需要最简的一个）。
enum Fixture {
    static func json(_ text: String) -> JSONValue {
        (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .null
    }
}
