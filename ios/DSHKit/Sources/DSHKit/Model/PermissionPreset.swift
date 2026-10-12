import Foundation

/// 一个可选的文件读写/审批权限档位。
///
/// 读自 `permissionPresets/catalog`（本机实测）：
/// ```json
/// {"options":[{"value":"read-only","name":"read-only"},
///             {"value":"workspace-write","name":"workspace-write"},
///             {"value":"danger-full-access","name":"danger-full-access"}],
///  "defaultPreset":"workspace-write"}
/// ```
public struct PermissionPreset: Sendable, Identifiable, Hashable {
    public var id: String { value }
    public var value: String
    public var name: String

    public init(value: String, name: String) {
        self.value = value
        self.name = name
    }

    public init(json: JSONValue) {
        let value = json.string("value") ?? json.string("id") ?? ""
        self.value = value
        self.name = json.string("name") ?? value
    }

    /// 这个档位在做什么。**只做解释，不做判断** —— 危险档位不美化、不恐吓，
    /// 但会把"减少确认步骤"这件事说清楚。
    public var explanation: String? {
        switch value {
        case "read-only":
            return String(localized: "只能读，不能改文件，也不能跑会写盘的命令。")
        case "workspace-write":
            return String(localized: "能在工作区目录里读写。工作区之外的操作仍然要你批准。")
        case "danger-full-access":
            return String(localized: "读写不受工作区限制，而且会减少确认步骤，包括敏感操作与外部命令。只在你信任接下来的任务时用。")
        default:
            return nil
        }
    }

    public var symbol: String {
        switch value {
        case "read-only": return "eye"
        case "workspace-write": return "folder.badge.gearshape"
        case "danger-full-access": return "exclamationmark.shield"
        default: return "lock"
        }
    }

    public var isRisky: Bool { value == "danger-full-access" }
}

/// `permissionPresets/catalog` 的返回。
public struct PermissionPresetCatalog: Sendable {
    public var options: [PermissionPreset]
    public var defaultPreset: String?

    public init(options: [PermissionPreset] = [], defaultPreset: String? = nil) {
        self.options = options
        self.defaultPreset = defaultPreset
    }

    public static func decode(_ value: JSONValue) -> PermissionPresetCatalog {
        PermissionPresetCatalog(
            options: (value.array("options") ?? []).map(PermissionPreset.init(json:)),
            defaultPreset: value.string("defaultPreset")
        )
    }
}

/// 一条斜杠命令的执行结果。
public struct CommandExecution: Sendable {
    public var commandId: String
    /// `success` / `error`，认不出原样带着。
    public var kind: String
    public var text: String

    public var isSuccess: Bool { kind == "success" }

    public static func decode(_ value: JSONValue) -> CommandExecution {
        let result = value["result"] ?? .object([:])
        return CommandExecution(
            commandId: value.string("commandId") ?? "",
            kind: result.string("kind") ?? "unknown",
            text: result.string("text") ?? ""
        )
    }
}
