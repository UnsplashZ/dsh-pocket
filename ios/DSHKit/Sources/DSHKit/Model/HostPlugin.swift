import Foundation

/// 主机上的一个插件（`pluginManager/listPlugins`）。
///
/// 线上形状（实测）：
/// ```json
/// [{"entryId":"include:timer","moduleName":"@deepseek-ai/cordis-plugin-timer",
///   "enabled":true,"fiberPhase":"active","patchId":"…",
///   "readOnlyReason":"unaddressable"|"management-required",
///   "meta":{"title":"…","description":"…"}}]
/// ```
///
/// `readOnlyReason` 是**能不能开关**的权威说明，不能自己猜：
///   · `unaddressable` —— 没有可寻址的 patch 位置，改不了；
///   · `management-required` —— 管理类插件，不给自己开关自己。
public struct HostPlugin: Sendable, Hashable, Identifiable {
    public var id: String { entryId }
    public var entryId: String
    public var moduleName: String
    public var enabled: Bool
    public var fiberPhase: String?
    public var readOnlyReason: String?
    public var patchId: String?
    public var title: String
    public var summary: String?

    public var isToggleable: Bool { readOnlyReason == nil }

    /// 加载状态的人话。`fiberPhase` 是插件运行时状态。
    public var statusLabel: String {
        if !enabled { return String(localized: "已停用") }
        switch fiberPhase {
        case "active": return String(localized: "运行中")
        case .some(let other): return other
        case nil: return String(localized: "已启用")
        }
    }

    public var readOnlyExplanation: String? {
        switch readOnlyReason {
        case "unaddressable": return String(localized: "没有可寻址的位置，改不了")
        case "management-required": return String(localized: "管理插件，不能自己关自己")
        case .some(let other): return other
        case nil: return nil
        }
    }

    public init(json: JSONValue) {
        let module = json.string("moduleName") ?? ""
        self.entryId = json.string("entryId") ?? module
        self.moduleName = module
        self.enabled = json.bool("enabled") ?? false
        self.fiberPhase = json.string("fiberPhase")
        self.readOnlyReason = json.string("readOnlyReason")
        self.patchId = json.string("patchId")
        let meta = json["meta"] ?? .object([:])
        self.title = meta.string("title") ?? module
        self.summary = meta.string("description")
    }
}

/// 主机的设置命名空间（`settings/describe`）。
///
/// ```json
/// {"writable":true,"hasDocument":true,
///  "namespaces":[{"ns":"agent-default-model","schema":{…},"value":{…},
///                 "base":{…},"user":{…},"applies":"live","revision":0}]}
/// ```
///
/// `value` 是**生效值**，`user` 是用户显式覆盖的部分（空对象 = 全用默认）。
/// 判断"用户改过没有"要看 `user` 而不是 `value`。
public struct SettingsNamespace: Sendable, Hashable, Identifiable {
    public var id: String { ns }
    public var ns: String
    public var value: JSONValue
    public var base: JSONValue?
    public var user: JSONValue?
    public var revision: Int
    public var isWritable: Bool

    public var hasUserOverride: Bool {
        guard let object = user?.objectValue else { return false }
        return !object.isEmpty
    }

    public init(json: JSONValue, isWritable: Bool) {
        self.ns = json.string("ns") ?? ""
        self.value = json["value"] ?? .object([:])
        self.base = json["base"]
        self.user = json["user"]
        self.revision = json.int("revision") ?? 0
        self.isWritable = isWritable
    }
}

/// `settings/describe` 的返回。
public struct SettingsSnapshot: Sendable {
    public var writable: Bool
    public var namespaces: [SettingsNamespace]

    public init(writable: Bool = false, namespaces: [SettingsNamespace] = []) {
        self.writable = writable
        self.namespaces = namespaces
    }

    public func namespace(_ ns: String) -> SettingsNamespace? {
        namespaces.first { $0.ns == ns }
    }

    public static func decode(_ value: JSONValue) -> SettingsSnapshot {
        let writable = value.bool("writable") ?? false
        return SettingsSnapshot(
            writable: writable,
            namespaces: (value.array("namespaces") ?? []).map {
                SettingsNamespace(json: $0, isWritable: writable)
            }
        )
    }
}
