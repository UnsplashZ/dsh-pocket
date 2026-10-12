import Foundation

/// `session/modelCatalog` 的返回。
///
/// 形状读自 `dsh-api-session-controller` 的 `ModelCatalog`（实测核对过）：
///
/// ```ts
/// interface ModelCatalog {
///     default: ModelSelection;                    // { provider, model, reasoningEffort? }
///     routableProviders: readonly string[];
///     groups: readonly ModelProviderGroup[];      // ← 模型在 groups[].models[] 里
///     failures: readonly ModelCatalogFailure[];
/// }
/// ```
///
/// 之前按 `models` / `providers` 找，两个都不存在 → 永远是空数组 →
/// 模型页永远停在"正在读取模型清单…"。
public struct ModelCatalog: Sendable {
    public var defaultSelection: ModelSelection?
    public var routableProviders: [String]
    public var groups: [ModelProviderGroup]
    public var failures: [String]

    public init(
        defaultSelection: ModelSelection? = nil,
        routableProviders: [String] = [],
        groups: [ModelProviderGroup] = [],
        failures: [String] = []
    ) {
        self.defaultSelection = defaultSelection
        self.routableProviders = routableProviders
        self.groups = groups
        self.failures = failures
    }

    public var isEmpty: Bool { groups.allSatisfy(\.models.isEmpty) }

    /// 拍平后的全部模型，便于按 id 找。
    public var allModels: [ModelCatalogModel] { groups.flatMap(\.models) }

    public func model(provider: String, id: String) -> ModelCatalogModel? {
        groups.first { $0.id == provider }?.models.first { $0.id == id }
    }

    /// 某个模型支持的推理强度。供选取器用 —— 不同模型的可选项不一样
    /// （实测：`hy4-preview-f` 只有 high，`deepseek-v4.1-flash` 有 low/high/max）。
    public func reasoningEfforts(provider: String, model: String) -> [ModelProviderGroup.ReasoningEffort] {
        self.model(provider: provider, id: model)?.reasoningEfforts ?? []
    }

    public static func decode(_ value: JSONValue) -> ModelCatalog {
        let failures = (value.array("failures") ?? []).compactMap { entry -> String? in
            // 认不出的形状就原样描述，别把失败吞掉
            entry.string("message") ?? entry.string("code") ?? entry.string("provider")
        }
        return ModelCatalog(
            defaultSelection: value["default"].map(ModelSelection.init(json:)),
            routableProviders: value.array("routableProviders")?.compactMap(\.stringValue) ?? [],
            groups: (value.array("groups") ?? []).map(ModelProviderGroup.init(json:)),
            failures: failures
        )
    }
}

/// 一个 provider 分组。
public struct ModelProviderGroup: Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var models: [ModelCatalogModel]

    public init(json: JSONValue) {
        let id = json.string("id") ?? json.string("provider") ?? ""
        self.id = id
        self.name = json.string("name") ?? (id.isEmpty ? "其它" : id)
        self.models = (json.array("models") ?? []).map(ModelCatalogModel.init(json:))
    }

    /// 一个可选的推理强度。
    public struct ReasoningEffort: Sendable, Identifiable, Hashable {
        public var id: String
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }

        public init(json: JSONValue) {
            let id = json.string("id") ?? ""
            self.id = id
            self.name = json.string("name") ?? id
        }
    }
}

/// 一个可选模型。
public struct ModelCatalogModel: Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var reasoningEfforts: [ModelProviderGroup.ReasoningEffort]

    public init(json: JSONValue) {
        let id = json.string("id") ?? json.string("model") ?? ""
        self.id = id
        self.name = json.string("name") ?? id
        self.reasoningEfforts = (json.array("reasoning.efforts") ?? json.array("efforts") ?? [])
            .map(ModelProviderGroup.ReasoningEffort.init(json:))
    }
}
