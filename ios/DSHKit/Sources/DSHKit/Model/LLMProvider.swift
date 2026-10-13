import Foundation

/// 一个模型提供商（`llm-pi-ai.providers.<key>`）。
///
/// **必须保留原始 JSON**：提供商和模型里有一大堆我们不在界面上编辑的字段
/// （`reasoningEfforts`、`compat.chatTemplateKwargs`、`input`、`systemPromptUpdate`…）。
/// 如果按我们的模型字段重新拼一份 JSON 写回去，这些字段会**全部丢掉** ——
/// 用户的推理档位、模板参数就没了。
/// 所以每份都带着 `raw`，保存时在它上面覆盖用户改过的那几个字段。
public struct LLMProvider: Sendable, Hashable, Identifiable {
    public var id: String
    public var displayName: String
    public var baseURL: String
    public var api: String
    /// API key 走**环境变量名**，密钥本身不在设置里（所以这里改着是安全的）。
    public var apiKeyEnv: String
    public var models: [LLMModel]
    public var raw: JSONValue

    public init(id: String, raw: JSONValue) {
        self.id = id
        self.raw = raw
        self.displayName = raw.string("displayName") ?? id
        self.baseURL = raw.string("baseURL") ?? ""
        self.api = raw.string("api") ?? "openai-completions"
        self.apiKeyEnv = raw.string("apiKeyEnv") ?? ""
        self.models = (raw.array("models") ?? []).enumerated().map { index, model in
            LLMModel(id: model.string("id") ?? "model-\(index)", raw: model)
        }
    }

    /// 把界面上的改动合并回原始 JSON。
    ///
    /// 只覆盖我们编辑过的键，别的原样带过去。
    public func mergedJSON() -> JSONValue {
        var object = raw.objectValue ?? [:]
        object["displayName"] = .string(displayName)
        object["baseURL"] = .string(baseURL)
        object["api"] = .string(api)
        if apiKeyEnv.isEmpty { object["apiKeyEnv"] = nil } else { object["apiKeyEnv"] = .string(apiKeyEnv) }
        object["models"] = .array(models.map { $0.mergedJSON() })
        return .object(object)
    }

    /// 可选的 api 协议。写错会让这个提供商完全不可用，所以给固定选项而不是自由输入。
    public static let knownAPIs = ["openai-completions", "openai-responses", "anthropic-messages", "google-generative-ai"]
}

/// 一个模型。
public struct LLMModel: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var contextWindow: Int?
    public var maxTokens: Int?
    public var raw: JSONValue

    public init(id: String, raw: JSONValue) {
        self.id = id
        self.raw = raw
        self.name = raw.string("name") ?? id
        self.contextWindow = raw.int("contextWindow")
        self.maxTokens = raw.int("maxTokens")
    }

    public init(id: String, name: String, contextWindow: Int?, maxTokens: Int?) {
        self.id = id
        self.name = name
        self.contextWindow = contextWindow
        self.maxTokens = maxTokens
        self.raw = .object([:])
    }

    public func mergedJSON() -> JSONValue {
        var object = raw.objectValue ?? [:]
        object["id"] = .string(id)
        object["name"] = .string(name.isEmpty ? id : name)
        object["contextWindow"] = contextWindow.map { .number(Double($0)) }
        object["maxTokens"] = maxTokens.map { .number(Double($0)) }
        return .object(object)
    }
}

/// 从 `settings/describe` 的命名空间里解出提供商表。
///
/// 形状是 `{providers: {"<key>": {…}}}` —— **键就是提供商 id**，
/// 所以顺序不稳定，界面要自己排。
public func decodeProviders(_ namespace: SettingsNamespace) -> [LLMProvider] {
    guard let providers = namespace.value["providers"]?.objectValue else { return [] }
    return providers
        .map { LLMProvider(id: $0.key, raw: $0.value) }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
}
