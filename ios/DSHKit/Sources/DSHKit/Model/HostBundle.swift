import Foundation

/// 主机上的一个**插件包**（`pluginManager/listBundles`）。
///
/// 为什么界面要展示包而不是插件：`listPlugins` 在本机返回 **202 条**，
/// 那是包**里面**的单个插件（`dsh-base` 一个包就 94 行），平铺出来完全看不清。
/// 桌面端的「插件」页展示的是这一层 —— 本机 **17 个包**，每个带人类可读的
/// 标题与说明。这也是 `setBundleEnabled` 的作用对象。
///
/// 线上形状（实测）：
/// ```json
/// [{"name":"@michengai/dsh-im-connect","version":"…","enabled":true,
///   "installed":true,"optional":false,"removable":true,"rows":[…],"overrides":[…],
///   "readOnlyReason":"management-required",
///   "meta":{"title":"IM Connect","description":"…","icon":"data:image/svg+xml;base64,…"}}]
/// ```
public struct HostBundle: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var version: String?
    public var enabled: Bool
    /// 用户自己装的（区别于随应用分发的官方包）。
    public var installed: Bool
    /// 官方**可选**包（桌面端把它们标成「实验性」）。
    public var optional: Bool
    public var removable: Bool
    public var readOnlyReason: String?
    /// 包里有几行补丁 —— 说明这个包的体量。
    public var rowCount: Int
    public var title: String
    public var summary: String?

    public var isToggleable: Bool { readOnlyReason == nil }

    /// 是不是"官方"（随应用分发）。桌面端按这个分「官方 / 已安装」两组。
    public var isOfficial: Bool { name.hasPrefix("@deepseek-ai/") }

    public var readOnlyExplanation: String? {
        switch readOnlyReason {
        case "management-required": return String(localized: "系统组件，不能关")
        case "unaddressable": return String(localized: "没有可寻址的位置，改不了")
        case .some(let other): return other
        case nil: return nil
        }
    }

    /// `languages` 是**环境**，不是这段解析逻辑的一部分，所以从参数进来（默认跟系统走）。
    /// 不这样的话「按语言挑本地化字段」根本没法测：在中文机器上过、在英文机器上挂 ——
    /// CI（en-US runner）就是这么红的。
    public init(json: JSONValue, languages: [String] = Locale.preferredLanguages) {
        let name = json.string("name") ?? ""
        self.name = name
        self.version = json.string("version")
        self.enabled = json.bool("enabled") ?? false
        self.installed = json.bool("installed") ?? false
        self.optional = json.bool("optional") ?? false
        self.removable = json.bool("removable") ?? false
        self.readOnlyReason = json.string("readOnlyReason")
        self.rowCount = (json.array("rows") ?? []).count
        let meta = json["meta"] ?? .object([:])
        // `meta.title` 可能是纯字符串，也可能是 `{en, zh}` —— 两种都要认。
        self.title = meta.localized("title", languages: languages) ?? name
        self.summary = meta.localized("description", languages: languages) ?? json.string("description")
    }
}

extension JSONValue {
    /// 取一个"可能是本地化字典、也可能是纯字符串"的字段。
    ///
    /// 实测两种形态都存在：`dshmarket` 的 `meta.title` 是 `"dshmarket"`，
    /// 而 `dsh-context` 的是 `{"en":"Context (dsh-context)","zh":"上下文 (dsh-context)"}`。
    public func localized(_ key: String, languages: [String] = Locale.preferredLanguages) -> String? {
        guard let value = self[key] else { return nil }
        if let plain = value.stringValue, !plain.isEmpty { return plain }
        guard let object = value.objectValue else { return nil }
        for candidate in JSONValue.preferredLocaleKeys(for: languages) {
            if let text = object[candidate]?.stringValue, !text.isEmpty { return text }
        }
        // 认不出的键：拿第一个非空值也比丢掉强。
        for entry in object.values {
            if let text = entry.stringValue, !text.isEmpty { return text }
        }
        return nil
    }

    /// 语言偏好顺序：`zh-Hans` → `zh` → 完整标签 → `en`。
    public static func preferredLocaleKeys(for languages: [String] = Locale.preferredLanguages) -> [String] {
        var keys: [String] = []
        for language in languages {
            let parts = language.split(separator: "-")
            if parts.count > 1 { keys.append("\(parts[0])-\(parts[1])") }
            keys.append(String(parts[0]))
            keys.append(language)
        }
        keys.append("en")
        return keys
    }
}
