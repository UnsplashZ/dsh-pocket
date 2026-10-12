import Foundation
import XCTest

@testable import DSHKit

/// 协议层里最容易被"想当然"写错的那几处，单独钉死。
final class ProtocolContractTests: XCTestCase {
    // MARK: JSONValue

    func testJSONValueKeepsUnknownFields() throws {
        let text = #"{"type":"x","seq":1,"data":{"known":1,"brandNewField":{"nested":[1,2,3]}},"futureTopLevel":true}"#
        let value = Fixture.json(text)
        XCTAssertEqual(value.int("data.known"), 1)
        XCTAssertEqual(value.array("data.brandNewField.nested")?.count, 3)
        XCTAssertEqual(value.bool("futureTopLevel"), true)
        // 原样回写：未知字段不能丢，否则"转发/回放"这类功能会静默损坏数据
        let encoded = try JSONEncoder.dshCompact.encode(value)
        let round = try JSONDecoder.dsh.decode(JSONValue.self, from: encoded)
        XCTAssertEqual(round, value)
    }

    func testJSONValueEncodesIntegralNumbersAsIntegers() throws {
        XCTAssertEqual(Fixture.json(#"{"seq":5}"#).description, #"{"seq":5}"#)
        XCTAssertEqual(Fixture.json(#"{"ratio":0.5}"#).description, #"{"ratio":0.5}"#)
    }

    func testJSONValuePathAccess() {
        let value = Fixture.json(#"{"a":{"b":{"c":42}}}"#)
        XCTAssertEqual(value.int("a.b.c"), 42)
        XCTAssertNil(value.int("a.b.d"))
        XCTAssertNil(value.int("a.nope.c"))
    }

    // MARK: surfaceOp

    func testSurfaceOpDecoding() {
        XCTAssertEqual(SurfaceOp.decode(.string("append")), .append)
        XCTAssertEqual(
            SurfaceOp.decode(Fixture.json(#"{"op":"replace","startSeq":7,"endSeq":9}"#)),
            .replace(startSeq: 7, endSeq: 9)
        )
        XCTAssertNil(SurfaceOp.decode(nil))
        XCTAssertNil(SurfaceOp.decode(Fixture.json(#"{"op":"append"}"#)), "对象形式的 append 不是合法形状")
    }

    // MARK: 事件信封

    func testEventEnvelopeRequiresSeqAndTime() {
        XCTAssertThrowsError(try Fixture.event(#"{"type":"turn/start","time":1,"data":{}}"#))
        XCTAssertThrowsError(try Fixture.event(#"{"type":"turn/start","seq":0,"data":{}}"#))
        XCTAssertThrowsError(try Fixture.event(#"{"seq":0,"time":1,"data":{}}"#))
    }

    func testEventEnvelopeAcceptsZeroSeqAndIgnoresUnknownEnvelopeFields() throws {
        // 我们比宿主宽松一档：多出来的信封字段不致命，读到就带上。
        let event = try Fixture.event(#"{"type":"permission/preset","seq":0,"time":1791777000000,"data":{"preset":"workspace-write"},"someFutureEnvelope":1}"#)
        XCTAssertEqual(event.seq, 0)
        XCTAssertEqual(event.durableSeq, 0)
        XCTAssertEqual(event.string("data.preset"), "workspace-write")
    }

    func testEpochMillisecondsBecomeDates() throws {
        let event = try Fixture.event(#"{"type":"turn/start","seq":1,"time":1791777000123,"data":{"turn":1}}"#)
        XCTAssertEqual(event.time.timeIntervalSince1970, 1_791_777_000.123, accuracy: 0.0005)
    }

    func testSnapshotDecodingSkipsUnknownRecordKinds() throws {
        let snapshot = try SessionSnapshot.decode(Fixture.json(#"""
        {"type":"snapshot","header":{"id":"s1","createdAt":0},"cursor":7,"records":[
          {"type":"event","event":{"type":"turn/start","seq":0,"time":1,"data":{"turn":1}}},
          {"type":"future-record-kind","whatever":1}
        ],"hasMore":true,"projections":{"asOfSeq":7,"values":{}}}
        """#))
        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.cursor, 7)
        XCTAssertTrue(snapshot.hasMore)
    }

    // MARK: mux 帧

    func testMuxItemWithoutValueIsAllowed() throws {
        // 宿主允许 `item` 不带 `value`（顶层 undefined）。
        let frame = Fixture.json(#"{"type":"item","streamId":"s1"}"#)
        XCTAssertNil(frame["value"])
        XCTAssertEqual(frame.string("type"), "item")
    }

    // MARK: waterfall 应答

    func testApprovalOutcomeVocabulary() throws {
        // 读自 dsh-user-approval：allowed-once 是唯一的授予。
        let grant = WaterfallRequest.approvalOutcome(.allowedOnce)
        XCTAssertEqual(grant.string("kind"), "result")
        XCTAssertEqual(grant.string("value"), "allowed-once")
        XCTAssertTrue(WaterfallRequest.ApprovalDecision.allowedOnce.isGrant)
        XCTAssertFalse(WaterfallRequest.ApprovalDecision.rejected.isGrant)
        XCTAssertFalse(WaterfallRequest.ApprovalDecision.unavailable.isGrant)
    }

    func testApprovalRequestDecoding() {
        let request = Fixture.waterfallApproval(eventId: "ev-1", toolName: "bash", reason: "要跑 rm")
        XCTAssertTrue(request.isApproval)
        XCTAssertFalse(request.isUserQuestion)
        XCTAssertEqual(request.approvalToolName, "bash")
        XCTAssertEqual(request.approvalReason, "要跑 rm")
        XCTAssertEqual(request.approvalCallId, "call-1")
        XCTAssertEqual(request.sessionId, "session-test")
    }

    func testUserQuestionDecodingAndAnswerShape() {
        let request = Fixture.waterfallQuestion(eventId: "ev-2")
        XCTAssertTrue(request.isUserQuestion)
        XCTAssertEqual(request.questions.count, 2)
        XCTAssertEqual(request.questions[0].options.map(\.label), ["甲", "乙"])
        XCTAssertEqual(request.questions[0].options[0].description, "快")
        XCTAssertFalse(request.questions[0].isMultiSelect)
        XCTAssertTrue(request.questions[1].options.isEmpty)

        let outcome = WaterfallRequest.answersOutcome([
            (id: "q1", selected: ["甲"], custom: nil),
            (id: "q2", selected: [], custom: "自己写的答案"),
        ])
        XCTAssertEqual(outcome.string("kind"), "result")
        let answers = outcome.array("value.answers") ?? []
        XCTAssertEqual(answers.count, 2)
        XCTAssertEqual(answers[0].array("selected")?.first?.stringValue, "甲")
        XCTAssertEqual(answers[1].string("custom"), "自己写的答案")
    }

    func testNextOutcomeShape() {
        XCTAssertEqual(WaterfallRequest.nextOutcome.string("kind"), "next")
        XCTAssertEqual(WaterfallRequest.nextOutcome.objectValue?.count, 1, "next 只能有 kind 一个键")
    }

    func testRejectedOutcomeShape() {
        let rejected = WaterfallRequest.rejectedOutcome(name: "Error", message: "不认这条", code: "not-mine")
        XCTAssertEqual(rejected.string("kind"), "rejected")
        XCTAssertEqual(rejected.string("error.name"), "Error")
        XCTAssertEqual(rejected.string("error.code"), "not-mine")
    }

    func testSafeFallbackFailsClosed() {
        let approval = Fixture.waterfallApproval(eventId: "ev-3")
        XCTAssertEqual(EventStreamCoordinator.safeFallback(for: approval).string("value"), "unavailable")

        let question = Fixture.waterfallQuestion(eventId: "ev-4")
        XCTAssertEqual(EventStreamCoordinator.safeFallback(for: question).string("kind"), "next")
    }

    func testHostEventDecoding() {
        guard case .ready(let clientId, let host) = HostEvent.decode(Fixture.ready(clientId: "c1")) else {
            return XCTFail("ready 帧没解出来")
        }
        XCTAssertEqual(clientId, "c1")
        XCTAssertEqual(host.string("home"), "/Users/example")

        guard case .emit(let name, _) = HostEvent.decode(Fixture.json(#"{"type":"emit","event":"api-session/added","args":{"a":1}}"#)) else {
            return XCTFail("emit 帧没解出来")
        }
        XCTAssertEqual(name, "api-session/added")

        guard case .waterfall(let request) = HostEvent.decode(Fixture.json(#"{"type":"waterfall","event":"approval/request","eventId":"e","agentId":"a","request":{}}"#)) else {
            return XCTFail("waterfall 帧没解出来")
        }
        XCTAssertTrue(request.isApproval)
    }

    // MARK: 错误分类

    func testErrorKindsDriveUIBranches() {
        XCTAssertEqual(DSHClientError.remote(DSHError(code: "session/not-found", message: "")).kind, .notFound)
        XCTAssertEqual(DSHClientError.transport(.http(status: 401, body: "")).kind, .unauthorized)
        XCTAssertEqual(DSHClientError.transport(.socketClosed(reason: "x")).kind, .disconnected)
        XCTAssertEqual(DSHClientError.transport(.cancelled).kind, .cancelled)
    }

    // MARK: 重试策略

    func testRetryPolicyRetriesOnlyTransientFailures() {
        let policy = RetryPolicy.default
        XCTAssertFalse(policy.shouldRetry(DSHClientError.remote(DSHError(code: "gateway/bad-request", message: ""))), "业务错误不该重试")
        XCTAssertFalse(policy.shouldRetry(DSHClientError.transport(.http(status: 404, body: ""))))
        XCTAssertTrue(policy.shouldRetry(DSHClientError.transport(.http(status: 503, body: ""))))
        XCTAssertTrue(policy.shouldRetry(DSHClientError.transport(.malformedResponse("x"))))
        XCTAssertFalse(policy.shouldRetry(DSHClientError.transport(.notConnected)))
    }

    func testRetryBackoffIsCapped() {
        let policy = RetryPolicy(maxAttempts: 8, baseDelay: .milliseconds(500), maxDelay: .milliseconds(2_000), jitter: 0)
        XCTAssertEqual(policy.delay(afterAttempt: 1).seconds, 0.5, accuracy: 0.001)
        XCTAssertEqual(policy.delay(afterAttempt: 2).seconds, 1.0, accuracy: 0.001)
        XCTAssertEqual(policy.delay(afterAttempt: 3).seconds, 2.0, accuracy: 0.001)
        XCTAssertEqual(policy.delay(afterAttempt: 4).seconds, 2.0, accuracy: 0.001, "要封顶")
    }

    // MARK: 路由拼接

    func testAPIRouteBuilding() {
        let base = URL(string: "http://127.0.0.1:20000")!
        XCTAssertEqual(DSHAPI.url(base: base, method: "session/list").absoluteString, "http://127.0.0.1:20000/api/session/list")
        XCTAssertEqual(DSHAPI.url(base: base, method: "$events/result").absoluteString, "http://127.0.0.1:20000/api/$events/result")
        XCTAssertEqual(
            DSHAPI.rawURL(base: base, path: "api/session/uploadFileBinary").absoluteString,
            "http://127.0.0.1:20000/api/session/uploadFileBinary"
        )
    }

    func testStaticHostProviderDerivesWebSocketURL() async throws {
        let provider = StaticHostProvider(base: URL(string: "http://127.0.0.1:20000")!)
        let base = try await provider.baseURL()
        let socket = try await provider.webSocketURL()
        XCTAssertEqual(base.absoluteString, "http://127.0.0.1:20000")
        XCTAssertEqual(socket.absoluteString, "ws://127.0.0.1:20000")

        let offline = StaticHostProvider(base: URL(string: "http://127.0.0.1:1")!, ready: false)
        do {
            _ = try await offline.baseURL()
            XCTFail("未就绪的 provider 应该抛错，而不是让 UI 假在线")
        } catch let error as DSHTransportError {
            XCTAssertEqual(error, .notConnected)
        }
    }

    // MARK: 队列（inbox）

    /// 排队中的消息**不在会话日志里** —— 实测：轮次跑着的时候发一条，
    /// 日志里一条 `user/message` 都没有，只出现在 `inbox` 投影里。
    /// 所以队列 UI 唯一的数据来源就是它。
    func testInboxProjectionParsesQueuedMessages() throws {
        let projections = Fixture.json(#"""
        {"values":{"inbox":{"next-turn":[
            {"content":[{"type":"text","text":"排队的第一条"}],"source":{"kind":"user","rpcId":"r2"},"role":"user","id":"q1"},
            {"content":[{"type":"text","text":"排队的第二条"},{"type":"image","mediaType":"image/png","data":"AAAA"}],"source":{"kind":"user"},"role":"user","id":"q2"}
         ],"next-step":[]}}}
        """#)
        let parsed = SessionProjections(json: projections)
        XCTAssertEqual(parsed.inbox.nextTurn.count, 2)
        XCTAssertEqual(parsed.inbox.nextTurn[0].text, "排队的第一条")
        XCTAssertEqual(parsed.inbox.nextTurn[0].rpcId, "r2", "rpcId 用来跟乐观插入对上，避免同一句话显示两遍")
        XCTAssertEqual(parsed.inbox.nextTurn[1].imageCount, 1)
        XCTAssertTrue(parsed.inbox.nextStep.isEmpty)
    }

    func testInboxIsEmptyWhenTheProjectionOmitsIt() throws {
        let parsed = SessionProjections(json: Fixture.json(#"{"values":{}}"#))
        XCTAssertTrue(parsed.inbox.isEmpty)
    }

    // MARK: 主机插件

    func testPluginParsesToggleabilityAndReadOnlyReason() throws {
        let plugins = [
            Fixture.json(#"{"entryId":"include:timer","moduleName":"@deepseek-ai/cordis-plugin-timer","enabled":true,"fiberPhase":"active"}"#),
            Fixture.json(#"{"entryId":"include:plugin-manager","moduleName":"@deepseek-ai/dsh-plugin-manager","enabled":true,"fiberPhase":"active","readOnlyReason":"management-required"}"#),
            Fixture.json(#"{"entryId":"include","moduleName":"cordis:include","enabled":true,"fiberPhase":"active","readOnlyReason":"unaddressable"}"#),
            Fixture.json(#"{"entryId":"include:tool-fs","moduleName":"@deepseek-ai/dsh-tool-fs","enabled":false,"fiberPhase":null,"meta":{"title":"文件工具","description":"读写文件"}}"#),
        ].map(HostPlugin.init(json:))

        XCTAssertTrue(plugins[0].isToggleable)
        XCTAssertEqual(plugins[0].statusLabel, String(localized: "运行中"))

        // 不能开关的必须说明原因，而不是摆一个灰开关让人猜
        XCTAssertFalse(plugins[1].isToggleable)
        XCTAssertNotNil(plugins[1].readOnlyExplanation)
        XCTAssertFalse(plugins[2].isToggleable)

        XCTAssertTrue(plugins[3].isToggleable)
        XCTAssertEqual(plugins[3].title, "文件工具", "meta.title 优先于 moduleName")
        XCTAssertEqual(plugins[3].summary, "读写文件")
        XCTAssertEqual(plugins[3].statusLabel, String(localized: "已停用"))
    }

    // MARK: 主机设置

    func testSettingsSnapshotParsesNamespacesAndOverrideFlag() throws {
        let snapshot = SettingsSnapshot.decode(Fixture.json(#"""
        {"writable":true,"hasDocument":true,"namespaces":[
          {"ns":"agent-default-model","applies":"live","revision":3,
           "value":{"provider":"wb","model":"deepseek-v4.1-flash","reasoningEffort":"high"},
           "base":{"provider":"deepseek-official","model":"deepseek-flash"},
           "user":{"provider":"wb","model":"deepseek-v4.1-flash","reasoningEffort":"high"}},
          {"ns":"locale","applies":"live","revision":0,"value":{"language":"zh-Hans"},"user":{}}
        ]}
        """#))
        XCTAssertTrue(snapshot.writable)
        let model = try XCTUnwrap(snapshot.namespace("agent-default-model"))
        XCTAssertEqual(model.value.string("model"), "deepseek-v4.1-flash")
        XCTAssertEqual(model.revision, 3, "乐观并发控制要用这个 revision")
        XCTAssertTrue(model.hasUserOverride)
        // 判断"用户改过没有"要看 `user`，不是 `value`
        XCTAssertFalse(try XCTUnwrap(snapshot.namespace("locale")).hasUserOverride)
        XCTAssertNil(snapshot.namespace("不存在"))
    }

    // MARK: 模型清单

    /// 实测返回里模型在 `groups[].models[]`，不在 `models[]` / `providers[]`。
    /// 按后两者找会得到空数组 —— 表现就是模型页永远转圈。
    func testModelCatalogParsesGroupsAndReasoningEfforts() throws {
        let value = Fixture.json(#"""
        {"default":{"provider":"wb","model":"deepseek-v4.1-flash","reasoningEffort":"high"},
         "routableProviders":["wb","deepseek-account"],
         "groups":[
           {"id":"wb","name":"WB","models":[
             {"id":"hy4-preview-f","name":"Hy4 preview","reasoning":{"efforts":[{"id":"high","name":"High"}]}},
             {"id":"deepseek-v4.1-flash","name":"Deepseek-V4.1-Flash","reasoning":{"efforts":[{"id":"low","name":"Low"},{"id":"high","name":"High"},{"id":"max","name":"Max"}]}}
           ]}
         ],
         "failures":[]}
        """#)
        let catalog = ModelCatalog.decode(value)
        XCTAssertFalse(catalog.isEmpty)
        XCTAssertEqual(catalog.groups.count, 1)
        XCTAssertEqual(catalog.groups[0].name, "WB")
        XCTAssertEqual(catalog.groups[0].models.count, 2)
        XCTAssertEqual(catalog.allModels.map(\.id), ["hy4-preview-f", "deepseek-v4.1-flash"])
        XCTAssertEqual(catalog.defaultSelection?.model, "deepseek-v4.1-flash")

        // 不同模型的推理强度选项不一样 —— 选取器必须按模型取，不能写死
        XCTAssertEqual(catalog.reasoningEfforts(provider: "wb", model: "hy4-preview-f").map(\.id), ["high"])
        XCTAssertEqual(
            catalog.reasoningEfforts(provider: "wb", model: "deepseek-v4.1-flash").map(\.name),
            ["Low", "High", "Max"]
        )
        XCTAssertTrue(catalog.reasoningEfforts(provider: "nope", model: "nope").isEmpty)
    }

    func testModelCatalogReportsFailuresInsteadOfSwallowingThem() {
        let catalog = ModelCatalog.decode(Fixture.json(#"""
        {"default":{"provider":"","model":""},"routableProviders":[],"groups":[],
         "failures":[{"provider":"foo","code":"auth","message":"需要登录"}]}
        """#))
        XCTAssertTrue(catalog.isEmpty)
        XCTAssertEqual(catalog.failures, ["需要登录"])
    }

    // MARK: 会话列表投影

    func testSessionSummaryDecodingFromRealShape() throws {
        let value = Fixture.json(#"""
        {"sessionId":"session-abc","updatedAt":1791779990130,"agentAvailable":true,"running":true,"blank":false,
         "cwd":"/Users/example/dev/Github/dsh-pocket",
         "projections":{"kind":"sequenced","asOfSeq":98,"values":{
            "title":"阅读该会话","tokenUsage":{"uncachedInputTokens":59262,"outputTokens":4160,"cacheReadTokens":420864,"cacheWriteTokens":0},
            "contextPressure":{"pressureTokens":62250,"projectedTokens":62446,"contextWindow":1000000},
            "turnOutline":[{"turn":1,"seq":5,"prompt":"阅读该会话","response":"好的"}],
            "agentPreset":"standard"}}}
        """#)
        let summary = try XCTUnwrap(SessionSummary.decode(value))
        XCTAssertEqual(summary.sessionId, "session-abc")
        XCTAssertTrue(summary.isRunning)
        XCTAssertEqual(summary.title, "阅读该会话")
        XCTAssertEqual(summary.workspaceName, "dsh-pocket")
        XCTAssertEqual(summary.subtitle, "好的")
        XCTAssertEqual(summary.asOfSeq, 98)
        XCTAssertEqual(summary.projections.tokenUsage.cacheReadTokens, 420_864)
        XCTAssertEqual(summary.projections.contextFraction ?? 0, 0.062446, accuracy: 0.000001)
    }

    func testSessionSummaryFallsBackToIdWhenUntitled() throws {
        let value = Fixture.json(#"{"sessionId":"session-0123456789abcdef","updatedAt":0,"projections":{"asOfSeq":-1,"values":{}}}"#)
        let summary = try XCTUnwrap(SessionSummary.decode(value))
        XCTAssertEqual(summary.title, "session-0123456789")
        XCTAssertEqual(summary.workspaceName, "其它")
        XCTAssertEqual(summary.subtitle, "")
    }

    func testListRowCleaningCollapsesWhitespaceAndMarkdown() {
        let raw = "## 结论\n\n**重点**：```swift\nlet a = 1\n```\n就这样"
        let cleaned = raw.cleanedForListRow()
        XCTAssertFalse(cleaned.contains("\n"))
        XCTAssertFalse(cleaned.contains("```"))
        XCTAssertFalse(cleaned.contains("**"))
        XCTAssertTrue(cleaned.hasPrefix("结论"))
    }

    // MARK: 日志

    func testMemoryLogKeepsCapacityBound() async {
        let sink = MemoryLogSink(capacity: 5, minimumLevel: .info)
        for index in 0..<20 {
            sink.log(.info, "第 \(index) 条")
        }
        // log 是 fire-and-forget，等一拍让 Task 落下去
        try? await Task.sleep(for: .milliseconds(120))
        let entries = await sink.snapshot()
        XCTAssertLessThanOrEqual(entries.count, 5)
        XCTAssertTrue(entries.allSatisfy { $0.message.hasPrefix("第 ") })
        let exported = await sink.exportText()
        XCTAssertTrue(exported.contains("[INFO]"))
    }
}
