import Foundation

/// 一个 agent preset（`agentPresets/list`）。
///
/// 线上形状（实测）：`{presets: [{id, name?, description?, order, isDefault}]}`。
/// 本机有 `standard`（默认）/ `ptc` / `minimal` / `cordis` / `analytics`。
///
/// **只有 `id` 是必填的** —— 除了 `analytics` 之外都没给 `name`/`description`，
/// 所以界面必须在缺名字时退回 id，而不是显示空白。
public struct AgentPreset: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    public var name: String?
    public var summary: String?
    public var order: Int
    public var isDefault: Bool

    /// 显示名：没给名字就用 id。
    public var title: String { name?.isEmpty == false ? name! : id }

    public init(json: JSONValue) {
        let id = json.string("id") ?? ""
        self.id = id
        self.name = json.string("name")
        self.summary = json.string("description")
        self.order = json.int("order") ?? 0
        self.isDefault = json.bool("isDefault") ?? false
    }

    public init(id: String, name: String? = nil, summary: String? = nil, order: Int = 0, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.summary = summary
        self.order = order
        self.isDefault = isDefault
    }

    public static func decodeList(_ value: JSONValue) -> [AgentPreset] {
        (value.array("presets") ?? [])
            .map(AgentPreset.init(json:))
            .sorted { $0.order < $1.order }
    }
}
