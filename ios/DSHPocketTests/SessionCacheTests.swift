import DSHKit
import XCTest

@testable import DSHPocket

/// 会话缓存的行为。
///
/// 这东西的价值全在"不能出错"上：读错一次就是**展示陈旧内容**或**丢掉历史**。
/// 所以四条底线各有一条测试：往返一致、LRU 有界、超限不缓存、版本不认就丢。
final class SessionCacheTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cache-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeState(seq: Double, itemCount: Int = 2, text: String = "内容") -> TimelineBuilder.State {
        var items: [TimelineItem] = []
        for index in 0..<itemCount {
            let itemSeq: Double = seq - Double(itemCount - index)
            let message = TimelineItem.UserMessage(text: text + String(index))
            let item = TimelineItem(
                id: "seq-\(Int(itemSeq))",
                seq: itemSeq,
                time: Date(),
                kind: TimelineItem.Kind.userMessage(message)
            )
            items.append(item)
        }
        return TimelineBuilder.State(cursor: Int(seq), lastSeq: seq, items: items)
    }

    private func makeSession(seq: Double, title: String = "标题") -> SessionCache.CachedSession {
        SessionCache.CachedSession(timeline: makeState(seq: seq), title: title, permission: "workspace-write")
    }

    func testRoundTripKeepsTimelineTitleAndPermission() async throws {
        let cache = SessionCache(directory: directory)
        await cache.store(makeSession(seq: 42, title: "为 dsh-pocket 加缓存"), for: "session-abc")

        let restored = await cache.session(for: "session-abc")
        let cached = try XCTUnwrap(restored)
        XCTAssertEqual(cached.title, "为 dsh-pocket 加缓存")
        XCTAssertEqual(cached.permission, "workspace-write")
        XCTAssertEqual(cached.timeline.items.count, 2)
        XCTAssertEqual(cached.timeline.lastSeq, 42)
    }

    /// 会话 id 里有 `:` 和 `/`（`im:feishu_…`），直接当文件名会跨目录。
    func testSessionIdWithColonsAndSlashesDoesNotEscapeTheDirectory() async throws {
        let cache = SessionCache(directory: directory)
        let tricky = "im:feishu_ab12cd34ef56/dm:1791780245515:oc_x"
        await cache.store(makeSession(seq: 7), for: tricky)

        let restored = await cache.session(for: tricky)
        XCTAssertNotNil(restored, "转义之后仍然要能读回来")

        // 目录里不该多出子目录（`/` 被转义掉了）
        let timelines = directory.appendingPathComponent("DSHPocket/SessionCache/timelines")
        let entries = try FileManager.default.contentsOfDirectory(atPath: timelines.path)
        XCTAssertEqual(entries.count, 1)
        XCTAssertFalse(entries[0].contains(":"), "文件名里的冒号也要转义")
    }

    func testUnknownSchemaVersionIsDiscardedNotGuessed() async throws {
        let cache = SessionCache(directory: directory)
        // 直接写一份"未来版本"的文件
        let stale = TimelineBuilder.State(schemaVersion: 999, cursor: 5, lastSeq: 5)
        let envelope = SessionCache.CachedSession(timeline: stale, title: "旧的", permission: nil)
        let data = try JSONEncoder().encode(envelope)
        let timelines = directory.appendingPathComponent("DSHPocket/SessionCache/timelines")
        try FileManager.default.createDirectory(at: timelines, withIntermediateDirectories: true)
        try data.write(to: timelines.appendingPathComponent("session-old.json"))

        // 能读出来，但 `TimelineBuilder(state:)` 必须拒绝它
        let restored = await cache.session(for: "session-old")
        XCTAssertNotNil(restored, "信封本身能解开")
        XCTAssertNil(TimelineBuilder(state: try XCTUnwrap(restored).timeline), "但版本对不上就不能用")
    }

    /// 单个会话超过上限时**不缓存**（而不是截断内容 —— 截断过的工具输出比没有更糟）。
    func testOversizedSessionIsNotCached() async throws {
        let cache = SessionCache(directory: directory, totalBudget: 10 * 1024 * 1024, perSessionLimit: 512)
        await cache.store(makeSession(seq: 1, title: String(repeating: "长", count: 2_000)), for: "session-big")

        let restored = await cache.session(for: "session-big")
        XCTAssertNil(restored, "超限的会话不该留在缓存里")

        let stats = await cache.statistics()
        XCTAssertEqual(stats.sessions, 0, "而且要顺手把旧的清掉，不留更老的一份")
    }

    /// 淘汰顺序按"最久没用过"。
    ///
    /// 用 `maxSessions` 而不是体积来触发淘汰 —— 按体积的话得先估算每条多大，
    /// 测试会变得又脆又难读（第一版就是这么写错的：还没"触碰"它就已经被淘汰了）。
    func testEvictionKeepsTheMostRecentlyUsed() async throws {
        let cache = SessionCache(
            directory: directory,
            totalBudget: 10 * 1024 * 1024,
            perSessionLimit: 10 * 1024 * 1024,
            maxSessions: 2
        )
        await cache.store(makeSession(seq: 1), for: "session-a")
        try await Task.sleep(for: .milliseconds(20))
        await cache.store(makeSession(seq: 2), for: "session-b")

        // 读一下 a：它现在是"最近用过"的
        let touched = await cache.session(for: "session-a")
        XCTAssertNotNil(touched)
        try await Task.sleep(for: .milliseconds(20))

        // 再塞一条，超出 maxSessions → 应当淘汰最久没用的 b，而不是刚读过的 a
        await cache.store(makeSession(seq: 3), for: "session-c")

        let survivorA = await cache.session(for: "session-a")
        let evictedB = await cache.session(for: "session-b")
        let storedC = await cache.session(for: "session-c")
        XCTAssertNotNil(survivorA, "刚读过的会话不该被淘汰")
        XCTAssertNil(evictedB, "最久没用过的才该被淘汰")
        XCTAssertNotNil(storedC, "新写入的当然要在")

        let stats = await cache.statistics()
        XCTAssertLessThanOrEqual(stats.sessions, 2)
    }

    func testSessionListRoundTrips() async throws {
        let cache = SessionCache(directory: directory)
        let value = Fixture.json(#"{"items":[{"sessionId":"session-a"}]}"#)
        await cache.store(sessionList: value)
        let restored = await cache.sessionList()
        XCTAssertEqual(restored?["items"]?.arrayValue?.count, 1)
    }

    func testClearRemovesEverything() async throws {
        let cache = SessionCache(directory: directory)
        await cache.store(makeSession(seq: 3), for: "session-a")
        await cache.store(sessionList: Fixture.json(#"{"items":[]}"#))

        await cache.clear()
        let stats = await cache.statistics()
        XCTAssertEqual(stats.sessions, 0)
        let list = await cache.sessionList()
        XCTAssertNil(list)
    }

    /// 索引里记着、文件却不在了（系统清过 `Caches/`）→ 读的时候不能崩，要当成没缓存。
    func testMissingFileOnDiskIsTreatedAsNoCache() async throws {
        let cache = SessionCache(directory: directory)
        await cache.store(makeSession(seq: 3), for: "session-gone")

        let timelines = directory.appendingPathComponent("DSHPocket/SessionCache/timelines")
        try FileManager.default.removeItem(at: timelines.appendingPathComponent("session-gone.json"))

        let restored = await cache.session(for: "session-gone")
        XCTAssertNil(restored)
        let stats = await cache.statistics()
        XCTAssertEqual(stats.sessions, 0, "索引要对账掉")
    }

    // MARK: - 归档会话缓存修剪

    /// 存了归档集合之后，`pruneArchived` 应该把已归档的时间线清掉、未归档的保留。
    func testPruneArchivedRemovesArchivedTimelinesOnly() async throws {
        let cache = SessionCache(directory: directory)
        await cache.store(makeSession(seq: 1), for: "session-active")
        await cache.store(makeSession(seq: 2), for: "session-archived")

        await cache.store(archivedSessionIds: ["session-archived"])
        await cache.pruneArchived()

        let active = await cache.session(for: "session-active")
        let archived = await cache.session(for: "session-archived")
        XCTAssertNotNil(active, "未归档的不能动")
        XCTAssertNil(archived, "已归档的该被清掉")

        let stats = await cache.statistics()
        XCTAssertEqual(stats.sessions, 1)
    }

    /// `except` 里的会话不清 —— 给"用户正在看这个归档会话"的场景用。
    func testPruneArchivedRespectsExcept() async throws {
        let cache = SessionCache(directory: directory)
        await cache.store(makeSession(seq: 1), for: "session-archived")

        await cache.store(archivedSessionIds: ["session-archived"])
        await cache.pruneArchived(except: ["session-archived"])

        let kept = await cache.session(for: "session-archived")
        XCTAssertNotNil(kept, "except 里的要留着")
    }

    /// 没有存过归档集合时，`pruneArchived` 是 no-op（不能误删）。
    func testPruneArchivedIsNoOpWithoutSnapshot() async throws {
        let cache = SessionCache(directory: directory)
        await cache.store(makeSession(seq: 1), for: "session-active")

        await cache.pruneArchived()

        let active = await cache.session(for: "session-active")
        XCTAssertNotNil(active, "没有归档快照时不能动任何缓存")
    }

    /// 冷启动过滤：缓存里的列表含已归档的，`activeSessionList()` 只返回未归档的。
    func testActiveSessionListFiltersArchived() async throws {
        let cache = SessionCache(directory: directory)
        let value = Fixture.json(#"""
        {"items":[
            {"sessionId":"session-a","title":"活跃的"},
            {"sessionId":"session-b","title":"归档的"}
        ]}
        """#)
        await cache.store(sessionList: value)
        await cache.store(archivedSessionIds: ["session-b"])

        let active = await cache.activeSessionList()
        let items = active?["items"]?.arrayValue ?? []
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?["sessionId"]?.stringValue, "session-a")
    }

    /// 没有归档快照时，`activeSessionList()` 返回全量（跟原来一样）。
    func testActiveSessionListWithoutSnapshotReturnsEverything() async throws {
        let cache = SessionCache(directory: directory)
        let value = Fixture.json(#"{"items":[{"sessionId":"session-a"}]}"#)
        await cache.store(sessionList: value)

        let active = await cache.activeSessionList()
        XCTAssertEqual(active?["items"]?.arrayValue?.count, 1)
    }

    /// `activeSessionList()` 会顺手把已归档的时间线从磁盘上清掉。
    func testActiveSessionListPrunesArchivedTimelinesAsSideEffect() async throws {
        let cache = SessionCache(directory: directory)
        let value = Fixture.json(#"{"items":[{"sessionId":"session-b"}]}"#)
        await cache.store(sessionList: value)
        await cache.store(makeSession(seq: 1), for: "session-b")
        await cache.store(archivedSessionIds: ["session-b"])

        _ = await cache.activeSessionList()

        let archived = await cache.session(for: "session-b")
        XCTAssertNil(archived, "归档的时间线该被顺手清掉")
    }

    /// 过滤只改 `items`，**不能**把负载里别的字段弄丢。
    /// 缓存里存的是宿主的原始负载，以后很可能会读别的字段。
    func testActiveSessionListKeepsOtherTopLevelKeys() async throws {
        let cache = SessionCache(directory: directory)
        await cache.store(sessionList: Fixture.json(#"""
        {"items":[{"sessionId":"session-a"},{"sessionId":"session-b"}],"cursor":42,"hasMore":true}
        """#))
        await cache.store(archivedSessionIds: ["session-b"])

        let active = await cache.activeSessionList()
        XCTAssertEqual(active?["items"]?.arrayValue?.count, 1)
        XCTAssertEqual(active?["cursor"]?.intValue, 42, "别的字段要原样带回去")
        XCTAssertEqual(active?["hasMore"]?.boolValue, true)
    }

    /// 老形态的负载用 `sessions` 而不是 `items`（`decodeSessionList` 两个都认），
    /// 过滤这边也必须两个都认 —— 只认一个的话会静默退化成"不过滤"。
    func testActiveSessionListFiltersTheLegacySessionsKeyToo() async throws {
        let cache = SessionCache(directory: directory)
        await cache.store(sessionList: Fixture.json(#"""
        {"sessions":[{"sessionId":"session-a"},{"sessionId":"session-b"}]}
        """#))
        await cache.store(archivedSessionIds: ["session-b"])

        let active = await cache.activeSessionList()
        XCTAssertEqual(active?["sessions"]?.arrayValue?.count, 1)
        XCTAssertEqual(active?["sessions"]?.arrayValue?.first?["sessionId"]?.stringValue, "session-a")
    }

    /// 负载里既没有 `items` 也没有 `sessions` 时，原样返回，不要崩也不要吞掉。
    func testActiveSessionListPassesThroughUnknownShape() async throws {
        let cache = SessionCache(directory: directory)
        await cache.store(sessionList: Fixture.json(#"{"somethingElse":1}"#))
        await cache.store(archivedSessionIds: ["session-b"])

        let active = await cache.activeSessionList()
        XCTAssertEqual(active?["somethingElse"]?.intValue, 1)
    }
}
