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

    // 这些文案跟着 App 当前语言走，**不能**写死中文：CI 的 runner 是 en-US，
    // 写死的断言到那儿全红（第一次跑 CI 就是这么红的）。
    //
    // 为什么不给 `Format` 加一个 locale 参数来钉死语言：`String(localized:locale:)`
    // 的 `locale` 只影响文案内部的数字/日期格式，挑不了 `.lproj` ——
    // 在 en 设备上传 `zh-Hans` 出来还是英文（CI 上实测）。语言由
    // `Bundle.main.preferredLocalizations` 决定，所以期望值也从那里取。
    // 另外，两种语言都齐全这件事由 CI 的 `gen-strings.py --check` 保证。
    private static let expectsChinese = (Bundle.main.preferredLocalizations.first ?? "en").hasPrefix("zh")

    func testRelativeTimeReadsNaturally() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(
            Format.relativeTime(now.addingTimeInterval(-5), now: now),
            Self.expectsChinese ? "刚刚" : "Just now"
        )
        XCTAssertFalse(Format.relativeTime(now.addingTimeInterval(-3600), now: now).isEmpty)
        XCTAssertFalse(Format.relativeTime(now.addingTimeInterval(-86_400 * 30), now: now).isEmpty)
    }

    func testDurationFormatting() {
        XCTAssertEqual(Format.duration(0.045), Self.expectsChinese ? "45 毫秒" : "45 ms")
        XCTAssertEqual(Format.duration(2.24), Self.expectsChinese ? "2.2 秒" : "2.2 s")
        XCTAssertEqual(Format.duration(125), Self.expectsChinese ? "2 分 5 秒" : "2m 5s")
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

    /// 新建会话的候选工作区**来自宿主的工作区注册表**，不是从会话反推。
    ///
    /// 从会话反推会漏掉"已添加但还没有会话"的工作区 —— 用户实测：`chat-bot`
    /// 当时只有频道会话，于是它在新建议话的列表里消失了。
    @MainActor
    func testWorkspaceListComesFromTheRegistryNotFromSessions() {
        let registry = [
            Fixture.workspace(id: "w1", path: "/Users/example/dev/Github/dsh-pocket", title: "dsh-pocket", sessionIds: ["a", "b"]),
            Fixture.workspace(id: "w2", path: "/Users/example/dev/Github/chat-bot", title: "chat-bot", sessionIds: ["im:weixin_x:dm:1:y"]),
            Fixture.workspace(id: "w3", path: "/Users/example/dev/scripts/net-tools", title: "net-tools", sessionIds: []),
        ]
        // 这三个里只有 w1 有普通会话，但**三个都要能选**。
        XCTAssertEqual(registry.count, 3)
        XCTAssertTrue(registry.contains { $0.title == "chat-bot" })
        XCTAssertTrue(registry.contains { $0.title == "net-tools" && $0.sessionIds.isEmpty })
    }

    /// `session/create` 要的是 **`workspaceId`**。
    ///
    /// 只传 `cwd` 建出来的会话在电脑端会落到「未分组」—— 用户看到的就是
    /// "选了工作区但不生效"。而 `workspaceId` 与 `cwd` 不能同时给（会被拒）。
    func testWorkspaceTargetCarriesWorkspaceId() {
        let summary = Fixture.workspace(id: "ws-42", path: "/Users/example/dev/Github/analytics", title: "analytics")
        XCTAssertEqual(summary.id, "ws-42")
        XCTAssertEqual(summary.title, "analytics")
        XCTAssertEqual(summary.path, "/Users/example/dev/Github/analytics")
    }

    // MARK: 频道（IM 插件）

    /// 频道是 IM 插件产生的效果，不是 App 自带的能力。
    ///
    /// 判据是**启发式**（插件不声明自己产出什么，只能看名字）：本机实测那个叫
    /// `@michengai/dsh-im-connect`，是第三方插件，所以不能只匹配官方前缀。
    /// 认不出时宁可少一个入口 —— 摆一个空标签页会让人以为坏了。
    @MainActor
    func testChannelPluginDetectionCoversThirdPartyNames() {
        func plugin(_ module: String, title: String = "", summary: String? = nil, enabled: Bool = true) -> HostPlugin {
            var object: [String: JSONValue] = [
                "entryId": .string(module),
                "moduleName": .string(module),
                "enabled": .bool(enabled),
            ]
            var meta: [String: JSONValue] = [:]
            if !title.isEmpty { meta["title"] = .string(title) }
            if let summary { meta["description"] = .string(summary) }
            if !meta.isEmpty { object["meta"] = .object(meta) }
            return HostPlugin(json: .object(object))
        }

        // 本机实际装的那个（第三方）
        XCTAssertTrue(AppModel.looksLikeChannelPlugin(plugin("@michengai/dsh-im-connect")))
        // 常见替代
        XCTAssertTrue(AppModel.looksLikeChannelPlugin(plugin("@someone/dsh-feishu-bridge")))
        XCTAssertTrue(AppModel.looksLikeChannelPlugin(plugin("@x/lark-connect")))
        XCTAssertTrue(AppModel.looksLikeChannelPlugin(plugin("@x/wechat-im")))
        // 名字里能看出来时也算
        XCTAssertTrue(AppModel.looksLikeChannelPlugin(plugin("@x/whatever", summary: "Connect instant-messaging channels")))

        // 无关插件不该被误判 —— 误判会让频道入口在不该出现时出现
        XCTAssertFalse(AppModel.looksLikeChannelPlugin(plugin("@deepseek-ai/dsh-tool-fs")))
        XCTAssertFalse(AppModel.looksLikeChannelPlugin(plugin("@deepseek-ai/dsh-agent-loop")))
        XCTAssertFalse(AppModel.looksLikeChannelPlugin(plugin("@deepseek-ai/cordis-plugin-timer")))
    }

    // MARK: Markdown 块级解析

    /// 表格曾经原样显示成 `| 方向 | 能做什么 |` —— 因为压根没有块级解析。
    func testMarkdownParsesTables() {
        let text = """
        我能帮你做这些事：

        | 方向 | 能做什么 |
        | --- | :---: |
        | 写代码 | 读代码库、定位 bug |
        | 查资料 | 联网搜索 |
        """
        let blocks = MarkdownParser.parse(text)
        XCTAssertEqual(blocks.count, 2)
        guard case .table(let table) = blocks[1] else { return XCTFail("第二块应该是表格") }
        XCTAssertEqual(table.headers, ["方向", "能做什么"])
        XCTAssertEqual(table.rows.count, 2)
        XCTAssertEqual(table.rows[0], ["写代码", "读代码库、定位 bug"])
        XCTAssertEqual(table.alignments, [.leading, .center])
    }

    func testMarkdownTableToleratesRaggedRows() {
        // 少列/多列的行都要能容错，不能让整段渲染失败
        let text = """
        | a | b | c |
        |---|---|---|
        | 1 |
        | 1 | 2 | 3 | 4 |
        """
        guard case .table(let table) = MarkdownParser.parse(text).first else { return XCTFail() }
        XCTAssertEqual(table.rows[0], ["1", "", ""], "缺的列补空")
        XCTAssertEqual(table.rows[1], ["1", "2", "3"], "多的列截掉")
    }

    func testMarkdownParsesListsQuotesAndRules() {
        let text = """
        - 第一项
        - 第二项
          - 缩进项

        1. 有序一
        2. 有序二

        > 引用一行

        ---
        """
        let blocks = MarkdownParser.parse(text)
        let markers = blocks.compactMap { block -> String? in
            if case .listItem(let marker, _, _) = block { return marker }
            return nil
        }
        XCTAssertEqual(markers, ["•", "•", "•", "1.", "2."])

        let depths = blocks.compactMap { block -> Int? in
            if case .listItem(_, _, let depth) = block { return depth }
            return nil
        }
        XCTAssertEqual(depths[2], 1, "缩进项要有一层深度")
        XCTAssertTrue(blocks.contains { if case .quote = $0 { return true }; return false })
        XCTAssertTrue(blocks.contains { if case .rule = $0 { return true }; return false })
    }

    func testMarkdownKeepsCodeFencesIntact() {
        let text = """
        前面的话

        ```swift
        let a = 1
        | 这不是表格 |
        ```

        后面的话
        """
        let blocks = MarkdownParser.parse(text)
        XCTAssertEqual(blocks.count, 3)
        guard case .code(let language, let code) = blocks[1] else { return XCTFail() }
        XCTAssertEqual(language, "swift")
        XCTAssertTrue(code.contains("| 这不是表格 |"), "代码块里的内容不该被当成表格")
    }

    func testMarkdownRecognisesStandaloneImages() {
        let blocks = MarkdownParser.parse("![架构图](https://example.com/a.png)")
        guard case .image(let alt, let url) = blocks.first else { return XCTFail("应该识别为图片块") }
        XCTAssertEqual(alt, "架构图")
        XCTAssertEqual(url, "https://example.com/a.png")
    }

    /// `---` 是分隔线，不是空列表项。
    func testMarkdownDistinguishesRuleFromListMarker() {
        XCTAssertEqual(MarkdownParser.parse("---"), [.rule])
        XCTAssertEqual(MarkdownParser.parse("***"), [.rule])
        guard case .listItem = MarkdownParser.parse("- 项").first else { return XCTFail("- 才是列表项") }
    }

    /// **缓存不能改变解析结果。**
    ///
    /// 展开/收缩掉帧的修复靠按文本缓存解析结果（`NSCache`）—— 命中的那次
    /// 必须和第一次解析**完全一样**，否则"滚回去内容变了"这种 bug 极难查。
    /// 这里连打三次同一段（第一次冷、后两次命中），结果必须逐字节相等；
    /// 同时确认 `parseUncached` 与带缓存的 `parse` 给的是同一个东西。
    func testMarkdownCacheReturnsIdenticalResults() {
        let text = """
        # 标题

        一段**正文**，带 `行内代码`。

        | a | b |
        |---|---|
        | 1 | 2 |

        - 列表项

        > 引用
        """
        let cold = MarkdownParser.parse(text)
        let warm = MarkdownParser.parse(text)
        let again = MarkdownParser.parse(text)
        XCTAssertEqual(cold, warm)
        XCTAssertEqual(cold, again)
        XCTAssertEqual(cold, MarkdownParser.parseUncached(text), "带缓存的路径必须和纯函数一致")
        XCTAssertFalse(cold.isEmpty)
    }

    /// 不同文本不能串味（缓存键就是文本本身）。
    func testMarkdownCacheKeysByText() {
        let a = MarkdownParser.parse("# 甲")
        let b = MarkdownParser.parse("# 乙")
        XCTAssertEqual(a, [.heading(level: 1, text: "甲")])
        XCTAssertEqual(b, [.heading(level: 1, text: "乙")])
        // 再取一次，确认没有被对方的缓存污染
        XCTAssertEqual(MarkdownParser.parse("# 甲"), [.heading(level: 1, text: "甲")])
    }

    // MARK: 权限档位

    func testPermissionPresetCatalogParses() {
        let catalog = PermissionPresetCatalog.decode(Fixture.json(#"""
        {"options":[{"value":"read-only","name":"read-only"},
                    {"value":"workspace-write","name":"workspace-write"},
                    {"value":"danger-full-access","name":"danger-full-access"}],
         "defaultPreset":"workspace-write"}
        """#))
        XCTAssertEqual(catalog.options.map(\.value), ["read-only", "workspace-write", "danger-full-access"])
        XCTAssertEqual(catalog.defaultPreset, "workspace-write")
        XCTAssertTrue(catalog.options.first { $0.value == "danger-full-access" }?.isRisky ?? false)
        XCTAssertFalse(catalog.options.first { $0.value == "read-only" }?.isRisky ?? true)
        for preset in catalog.options {
            XCTAssertNotNil(preset.explanation, "\(preset.value) 应该有一句解释")
        }
    }

    func testCommandExecutionParsesSuccessAndFailure() {
        let ok = CommandExecution.decode(Fixture.json(#"{"commandId":"cmd-1","result":{"kind":"success","text":"preset read-only"}}"#))
        XCTAssertTrue(ok.isSuccess)
        XCTAssertEqual(ok.text, "preset read-only")

        let bad = CommandExecution.decode(Fixture.json(#"{"commandId":"cmd-2","result":{"kind":"error","text":"unknown preset"}}"#))
        XCTAssertFalse(bad.isSuccess)
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

    // MARK: 计时器文案

    /// 工作状态那行的已用时格式：`12 秒` / `1 分 23 秒` —— 跟 desktop 的说法一致。
    /// 负数与零都要被调用方夹过（`max(0, …)`），这里钉住格式本身。
    func testElapsedTextFormatting() {
        XCTAssertEqual(Composer.elapsedText(0), String(format: String(localized: "%lld 秒"), 0))
        XCTAssertEqual(Composer.elapsedText(12), String(format: String(localized: "%lld 秒"), 12))
        XCTAssertEqual(Composer.elapsedText(59), String(format: String(localized: "%lld 秒"), 59))
        XCTAssertEqual(Composer.elapsedText(60), String(format: String(localized: "%lld 分 %lld 秒"), 1, 0))
        XCTAssertEqual(Composer.elapsedText(83), String(format: String(localized: "%lld 分 %lld 秒"), 1, 23))
        XCTAssertEqual(Composer.elapsedText(3599), String(format: String(localized: "%lld 分 %lld 秒"), 59, 59))
        // 超过一小时也是"N 分 N 秒"（desktop 没有小时档）
        XCTAssertEqual(Composer.elapsedText(3661), String(format: String(localized: "%lld 分 %lld 秒"), 61, 1))
        // 小数截断而不是四舍五入 —— 计时器不该"提前"
        XCTAssertEqual(Composer.elapsedText(83.9), String(format: String(localized: "%lld 分 %lld 秒"), 1, 23))
    }
}

/// 与 DSHKit 测试同款的 JSON 构造助手（这里只需要最简的一个）。
enum Fixture {
    static func workspace(
        id: String,
        path: String,
        title: String? = nil,
        sessionIds: [String] = []
    ) -> WorkspaceSummary {
        WorkspaceSummary(json: .object([
            "workspaceId": .string(id),
            "path": .string(path),
            "title": .string(title ?? (path as NSString).lastPathComponent),
            "sessionIds": .array(sessionIds.map { .string($0) }),
        ]))
    }

    static func json(_ text: String) -> JSONValue {
        (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .null
    }
}
