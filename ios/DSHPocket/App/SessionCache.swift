import DSHKit
import Foundation

/// 会话内容的**磁盘缓存**。
///
/// 目的：切换会话时不用每次等远程快照。打开时先用缓存把内容铺出来，
/// 同时照常订阅 `session/follow`，按 `seq` 增量补齐 —— 用户看到的是"秒开 + 后台校准"，
/// 而不是一个转圈。
///
/// 三条设计约束：
///   1. **正确性优先**：缓存只当"提示"，永远以宿主的 `session/follow` 为准。
///      恢复之后必须还能继续增量折叠（所以存的是 `TimelineBuilder.State` 全量，
///      不是只存渲染用的条目数组）。
///   2. **有界**：写入时按 LRU 淘汰，总预算 + 单会话上限都卡死；
///      单个会话超过上限就**不缓存**（而不是截断内容 —— 截断过的工具输出比没有更糟）。
///   3. **可丢弃**：放在 `Caches/`，系统可以随时清掉；版本对不上也直接丢。
///      它从来不是"数据的家"，只是一个加速器。
actor SessionCache {
    /// 落盘的信封。
    ///
    /// 为什么要包一层而不是直接存 `TimelineBuilder.State`：标题与权限档位**不在**
    /// 折叠状态里（它们是会话级属性，不是时间线的），但正是"秒开"时最显眼的两样东西 ——
    /// 导航栏标题和权限菜单文案。只存时间线的话打开瞬间标题还是 `session-xxxx`。
    struct CachedSession: Codable, Sendable {
        var timeline: TimelineBuilder.State
        var title: String
        var permission: String?
    }

    /// 一个会话缓存后的体积统计。
    private struct Entry: Codable, Sendable {
        var bytes: Int
        var savedAt: Date
        var lastSeq: Double
    }

    private let directory: URL
    private let totalBudget: Int
    private let perSessionLimit: Int
    private let maxSessions: Int
    private let logger: any DSHLogSink

    private var index: [String: Entry] = [:]
    private var loaded = false

    /// - Parameters:
    ///   - totalBudget: 全部缓存加起来的上限。默认 32 MB。
    ///   - perSessionLimit: 单个会话超过它就不缓存。默认 4 MB。
    init(
        directory: URL? = nil,
        totalBudget: Int = 32 * 1024 * 1024,
        perSessionLimit: Int = 4 * 1024 * 1024,
        maxSessions: Int = 40,
        logger: any DSHLogSink = NullLogSink()
    ) {
        let base = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.directory = base.appendingPathComponent("DSHPocket/SessionCache", isDirectory: true)
        self.totalBudget = totalBudget
        self.perSessionLimit = perSessionLimit
        self.maxSessions = maxSessions
        self.logger = logger
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    // MARK: 时间线

    /// 读一个会话的折叠状态。读不到 / 版本对不上都返回 `nil`（调用方退回重拉）。
    func session(for sessionId: String) -> CachedSession? {
        loadIndexIfNeeded()
        let url = timelineURL(sessionId)
        guard let data = try? Data(contentsOf: url) else {
            // 系统清过 `Caches/`：文件没了就把索引条目也丢掉，
            // 否则诊断页会一直报一个大于实际的数量。
            if index[sessionId] != nil {
                index[sessionId] = nil
                saveIndex()
            }
            return nil
        }
        guard let state = try? JSONDecoder.cache.decode(CachedSession.self, from: data) else {
            // 解不开就当没有：可能是换了 app 版本之后遗留的旧结构。
            try? FileManager.default.removeItem(at: url)
            index[sessionId] = nil
            saveIndex()
            return nil
        }
        // 触碰一下，让 LRU 知道它还有用。
        if var entry = index[sessionId] {
            entry.savedAt = Date()
            index[sessionId] = entry
        }
        return state
    }

    /// 写一个会话的折叠状态。超上限则跳过（并顺手把旧的清掉，免得留下更老的一份）。
    func store(_ session: CachedSession, for sessionId: String) {
        loadIndexIfNeeded()
        let state = session.timeline
        // 内存里的流式项没有价值，落盘前剔掉（它们永远会被持久事件取代）。
        let durable = TimelineBuilder.State(
            header: state.header,
            cursor: state.cursor,
            lastSeq: state.lastSeq,
            hasMoreHistory: state.hasMoreHistory,
            items: state.items.filter(\.isDurable),
            surfaceNodes: state.surfaceNodes,
            replacements: state.replacements,
            toolCalls: state.toolCalls,
            approvals: state.approvals,
            inboxItems: [:] ,
            optimisticItems: [:],
            transientCounter: 0
        )
        let envelope = CachedSession(timeline: durable, title: session.title, permission: session.permission)
        guard let data = try? JSONEncoder.cache.encode(envelope) else { return }

        guard data.count <= perSessionLimit else {
            logger.log(.debug, "会话缓存跳过（\(data.count / 1024) KB 超过单会话上限）")
            discard(sessionId: sessionId)
            return
        }

        let url = timelineURL(sessionId)
        do {
            try data.write(to: url, options: Data.WritingOptions.atomic)
        } catch {
            logger.log(.debug, "会话缓存写入失败：\(error.localizedDescription)")
            return
        }
        protect(url)
        index[sessionId] = Entry(bytes: data.count, savedAt: Date(), lastSeq: state.lastSeq)
        evictIfNeeded()
        saveIndex()
    }

    func discard(sessionId: String) {
        loadIndexIfNeeded()
        try? FileManager.default.removeItem(at: timelineURL(sessionId))
        index[sessionId] = nil
        saveIndex()
    }

    // MARK: 会话列表

    /// 会话列表的原始投影 JSON。冷启动时先把列表铺出来，再等 `session/list` 校准。
    func sessionList() -> JSONValue? {
        guard let data = try? Data(contentsOf: sessionListURL),
              let value = try? JSONDecoder.cache.decode(JSONValue.self, from: data)
        else { return nil }
        return value
    }

    /// 只含**未归档**会话的列表。
    ///
    /// 为什么单独有这个方法而不是让调用方自己 filter：`session/list` 里没有归档字段，
    /// 冷启动第一屏如果直接把缓存里的全量列表铺出来，已归档的会话会**先显示出来**，
    /// 直到 `workspace/follow` 的 baseline 到达才被剔掉 —— 用户看到的就是"打开 app
    /// 一堆已归档的会话闪过"。这里用上次存下来的归档集合把缓存**读的时候就**过滤掉，
    /// 并顺手把磁盘上已归档的时间线文件清掉（它们不再有人读，只会白占预算）。
    func activeSessionList() -> JSONValue? {
        guard let archived = archivedSessionList(), !archived.isEmpty else { return sessionList() }
        // 全清，无例外 —— 这是冷启动路径，没有在浏览任何会话。
        pruneArchived()
        guard let list = sessionList() else { return nil }
        // 宿主用 `items`，老版本是 `sessions`（`decodeSessionList` 两个都认）。
        // 这里也必须两个都认：只认一个的话，另一种形态下会静默退化成"不过滤"，
        // 已归档的会话又冒出来 —— 而且是最难查的那种"看起来没问题"。
        let key = list["items"] != nil ? "items" : "sessions"
        guard let items = list[key]?.arrayValue else { return list }
        let filteredItems = items.filter { item in
            guard let id = item["sessionId"]?.stringValue else { return true }
            return !archived.contains(id)
        }
        // 只替换那一个键再整块还回去，别把"改过 items 的列表"变成"只剩 items 的列表"：
        // 缓存里存的是宿主的原始负载，以后很可能会读别的字段。
        guard var object = list.objectValue else { return list }
        object[key] = .array(filteredItems)
        return .object(object)
    }

    /// 上次存下来的归档集合（`session/list` 不带来这个字段，这里存的是上次
    /// `workspace/follow` 同步过来的快照）。
    func archivedSessionList() -> Set<String>? {
        guard let data = try? Data(contentsOf: archivedSessionListURL),
              let value = try? JSONDecoder.cache.decode([String].self, from: data)
        else { return nil }
        return Set(value)
    }

    func store(sessionList value: JSONValue) {
        guard let data = try? JSONEncoder.cache.encode(value) else { return }
        // 列表很小（几十 KB），单独放在预算之外 —— 它决定冷启动第一屏，
        // 被工具输出挤掉是最不划算的。
        try? data.write(to: sessionListURL, options: Data.WritingOptions.atomic)
    }

    /// 把当前的归档集合存下来，供 `activeSessionList()` 冷启动过滤用。
    func store(archivedSessionIds: Set<String>) {
        guard let data = try? JSONEncoder.cache.encode(Array(archivedSessionIds)) else { return }
        try? data.write(to: archivedSessionListURL, options: Data.WritingOptions.atomic)
    }

    /// 清掉**已归档会话**的时间线缓存（不动未归档的）。
    ///
    /// 归档的语义本来就是"收起来" —— 它们几乎不会再被点开，留着只会挤占 LRU 预算。
    /// `except` 用于"用户正在看这个归档会话"的场景：把它留着，免得刚从缓存铺出来
    /// 又被自己清掉。
    func pruneArchived(except exceptions: Set<String> = []) {
        loadIndexIfNeeded()
        let archived = archivedSessionList() ?? []
        guard !archived.isEmpty else { return }
        var changed = false
        for sessionId in archived where !exceptions.contains(sessionId) {
            guard index[sessionId] != nil else { continue }
            try? FileManager.default.removeItem(at: timelineURL(sessionId))
            index[sessionId] = nil
            changed = true
        }
        if changed { saveIndex() }
    }

    // MARK: 维护

    /// 缓存现状，给诊断页用。
    func statistics() -> (sessions: Int, bytes: Int) {
        loadIndexIfNeeded()
        // 主动对账而不是只信索引：`Caches/` 是系统随时可以清的，
        // 索引文件留下、时间线文件没了是完全正常的组合。
        reconcile()
        return (index.count, index.values.reduce(0) { $0 + $1.bytes })
    }

    func clear() {
        loadIndexIfNeeded()
        for sessionId in index.keys {
            try? FileManager.default.removeItem(at: timelineURL(sessionId))
        }
        index.removeAll()
        try? FileManager.default.removeItem(at: sessionListURL)
        try? FileManager.default.removeItem(at: archivedSessionListURL)
        saveIndex()
    }

    // MARK: 内部

    private var timelineDirectory: URL {
        directory.appendingPathComponent("timelines", isDirectory: true)
    }

    /// `Caches/` 默认会被 iCloud 备份排除，但**不会**自动加数据保护类 ——
    /// 这里存的是会话内容，显式标一下"设备解锁后可读、不同步"。
    private func protect(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    private func timelineURL(_ sessionId: String) -> URL {
        timelineDirectory.appendingPathComponent(sanitize(sessionId)).appendingPathExtension("json")
    }

    /// 会话 id 可能含 `:` `/`（`im:feishu_…`）—— 直接当文件名会跨目录，必须转义。
    private func sanitize(_ sessionId: String) -> String {
        sessionId.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "_"
        }.reduce(into: "") { $0.append($1) }
    }

    private var sessionListURL: URL {
        directory.appendingPathComponent("session-list.json")
    }

    /// 归档集合的快照。`session/list` 里没有这个字段（归档属于工作区），
    /// 冷启动第一屏要等 `workspace/follow` 的 baseline 才能拿到 —— 在那之前
    /// 先用上次存下来的快照把已归档的从缓存列表里剔掉。
    private var archivedSessionListURL: URL {
        directory.appendingPathComponent("archived-sessions.json")
    }

    private var indexPath: URL {
        directory.appendingPathComponent("index.json")
    }

    private func loadIndexIfNeeded() {
        guard !loaded else { return }
        loaded = true
        try? FileManager.default.createDirectory(at: timelineDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexPath),
           let decoded = try? JSONDecoder.cache.decode([String: Entry].self, from: data) {
            index = decoded
        }
        reconcile()
    }

    /// 索引里记了、文件却不在了（被系统清过 `Caches/`）→ 对账掉。
    private func reconcile() {
        var changed = false
        for (sessionId, _) in index where !FileManager.default.fileExists(atPath: timelineURL(sessionId).path) {
            index[sessionId] = nil
            changed = true
        }
        if changed { saveIndex() }
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder.cache.encode(index) else { return }
        try? data.write(to: indexPath, options: Data.WritingOptions.atomic)
    }

    /// 淘汰到预算之内：先按"最久没用过"删，再按数量删。
    private func evictIfNeeded() {
        var total = index.values.reduce(0) { $0 + $1.bytes }
        var ordered = index.sorted { $0.value.savedAt < $1.value.savedAt }

        while (total > totalBudget || index.count > maxSessions), let oldest = ordered.first {
            index[oldest.key] = nil
            try? FileManager.default.removeItem(at: timelineURL(oldest.key))
            total -= oldest.value.bytes
            ordered.removeFirst()
        }
    }
}

extension JSONDecoder {
    /// 缓存用的解码器。日期走 ISO-8601，键保持原样。
    static let cache: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension JSONEncoder {
    /// 缓存用的编码器。不用 `sortedKeys` —— 缓存只需可读，不需要稳定 diff，
    /// 排序反而要遍历全部键。
    static let cache: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
