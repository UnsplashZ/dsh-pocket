import Foundation

/// `workspace/follow` 的一帧。
///
/// 读自 `dsh-api-workspace-controller/lib/types/feed.js`（已在本机核对过）：
///   · 首帧恒为 `{type:'baseline', value:{items, archivedSessionIds, pinnedSessionIds}}`；
///   · 之后是增量：`archived` / `pinned` / `upsert` / `order` / …
///
/// **为什么必须有这条流**：`session/list` 里没有归档字段。归档属于工作区，
/// 只有这条流会告诉你"哪些会话被归档了"。少了它，归档过的会话会一直留在列表里
/// （本机实测有 32 个，列表会非常乱）。
public enum WorkspaceFrame: Sendable {
    case baseline(archivedSessionIds: [String], pinnedSessionIds: [String], workspaces: [WorkspaceSummary])
    case archived([String])
    case pinned([String])
    /// `upsert`：新增/更新一个工作区。
    case workspaces([WorkspaceSummary])
    /// `order`：工作区顺序变了。
    case order([String])
    case other(type: String, value: JSONValue)

    public static func decode(_ value: JSONValue) -> WorkspaceFrame {
        switch value.string("type") {
        case "baseline":
            let payload = value["value"] ?? .object([:])
            return .baseline(
                archivedSessionIds: payload.array("archivedSessionIds")?.compactMap(\.stringValue) ?? [],
                pinnedSessionIds: payload.array("pinnedSessionIds")?.compactMap(\.stringValue) ?? [],
                workspaces: (payload.array("items") ?? []).map(WorkspaceSummary.init(json:))
            )
        case "archived":
            return .archived(value.array("archivedSessionIds")?.compactMap(\.stringValue) ?? [])
        case "pinned":
            return .pinned(value.array("pinnedSessionIds")?.compactMap(\.stringValue) ?? [])
        case "upsert":
            return .workspaces([WorkspaceSummary(json: value["workspace"] ?? .object([:]))])
        case "order":
            return .order(value.array("workspaceIds")?.compactMap(\.stringValue) ?? [])
        default:
            return .other(type: value.string("type") ?? "?", value: value)
        }
    }
}

/// 工作区（会话的分组单位）。
///
/// 线上形状（`WorkspaceView`，本机实测核对过）：
/// ```ts
/// { workspaceId, path, title, sessionIds[], createdAt, updatedAt }
/// ```
///
/// **`session/create` 要的是 `workspaceId`，不是 `cwd`。** 只传 `cwd` 建出来的会话
/// 在电脑端会落在「未分组」里 —— 这正是"选完工作区不生效"的原因。
public struct WorkspaceSummary: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let path: String
    public let sessionIds: [String]
    /// 最后更新时间。`WorkspaceView` 里是 **ISO-8601 字符串**（不是纪元毫秒 ——
    /// 全协议里只有它和时间相关的字段是这样的）。
    public let updatedAt: Date?

    public init(json: JSONValue) {
        let id = json.string("workspaceId") ?? json.string("id") ?? ""
        self.id = id
        let path = json.string("path") ?? ""
        self.path = path
        self.title = json.string("title")
            ?? (path.isEmpty ? id : (path as NSString).lastPathComponent)
        self.sessionIds = json.array("sessionIds")?.compactMap(\.stringValue) ?? []
        if let raw = json.string("updatedAt") {
            self.updatedAt = ISO8601DateFormatter().date(from: raw)
        } else {
            self.updatedAt = nil
        }
    }
}
