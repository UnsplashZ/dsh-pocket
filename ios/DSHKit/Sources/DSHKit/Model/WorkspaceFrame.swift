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
    case workspaces([WorkspaceSummary])
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
        default:
            return .other(type: value.string("type") ?? "?", value: value)
        }
    }
}

/// 工作区（`cwd` 的分组单位）。
public struct WorkspaceSummary: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let path: String?

    public init(json: JSONValue) {
        self.id = json.string("id") ?? json.string("workspaceId") ?? ""
        self.name = json.string("name") ?? json.string("title") ?? (json.string("path").map { ($0 as NSString).lastPathComponent } ?? "")
        self.path = json.string("path") ?? json.string("cwd")
    }
}
