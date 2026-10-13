import DSHKit
import SwiftUI

/// 模型提供商与模型。
///
/// 改的是 `settings` 里带 `providers` 的那几个命名空间（本机是 `llm-pi-ai`）。
/// **密钥不在这里** —— 提供商配的是 `apiKeyEnv`（环境变量名），
/// 真正的 key 在电脑的环境里。所以这一页改着是安全的，
/// 但**改错 `baseURL` / `api` 会让那个提供商直接不可用**，所以保存前要确认。
struct ModelProvidersView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var editing: LLMProvider?
    @State private var isCreating = false
    @State private var pendingDelete: LLMProvider?
    @State private var errorMessage: String?

    /// 承载提供商的那个命名空间（本机是 `llm-pi-ai`）。
    private var namespace: SettingsNamespace? {
        model.hostSettings?.namespaces.first { $0.value["providers"]?.objectValue != nil }
    }

    private var providers: [LLMProvider] {
        namespace.map(decodeProviders) ?? []
    }

    var body: some View {
        NavigationStack {
            List {
                if namespace == nil {
                    Section {
                        Text(model.isLoadingHostSettings
                             ? String(localized: "正在读取…")
                             : String(localized: "这台电脑没有暴露模型提供商设置。"))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(providers) { provider in
                            Button {
                                editing = provider
                            } label: {
                                row(provider)
                            }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button("删除", role: .destructive) { pendingDelete = provider }
                            }
                        }
                        Button {
                            isCreating = true
                        } label: {
                            Label("添加提供商", systemImage: "plus.circle")
                        }
                    } header: {
                        Text(String(format: String(localized: "提供商 · %lld"), providers.count))
                    } footer: {
                        Text("密钥不在手机上：提供商配的是**环境变量名**，真正的 key 在电脑的环境里。左滑可以删除。")
                    }
                }
            }
            .navigationTitle("模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                await model.refreshHostSettings()
                #if DEBUG
                if UserDefaults.standard.bool(forKey: "DSHShowProviderEditor") {
                    editing = providers.first
                }
                #endif
            }
            .sheet(item: $editing) { provider in
                ProviderEditorView(provider: provider, namespace: namespace?.ns, isNew: false)
            }
            .sheet(isPresented: $isCreating) {
                ProviderEditorView(provider: nil, namespace: namespace?.ns, isNew: true)
            }
            .confirmationDialog(
                "删除这个提供商？",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    if let provider = pendingDelete { delete(provider) }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("用它跑着的会话不会立刻停，但之后就选不到它的模型了。")
            }
            .alert("改不了", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("知道了", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func row(_ provider: LLMProvider) -> some View {
        HStack(alignment: .top, spacing: Token.Spacing.tight) {
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .font(.body)
                    .lineLimit(1)
                if !provider.baseURL.isEmpty {
                    Text(provider.baseURL)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(String(format: String(localized: "%lld 个模型"), provider.models.count))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Token.Spacing.tight)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(minHeight: Token.minimumHitTarget)
        .contentShape(Rectangle())
    }

    private func delete(_ provider: LLMProvider) {
        guard let namespace else { return }
        Task {
            // 提供商是 `providers` 对象里的一个键 —— 用 `unset` 精确删掉它，
            // 而不是把整个 `providers` 重写一遍（那会连带影响别的提供商）。
            errorMessage = await model.mutateSettings(
                namespace: namespace.ns,
                operations: [("unset", ["providers", provider.id], nil)],
                expectedRevision: namespace.revision
            )
        }
    }
}

/// 编辑一个提供商（含它的模型）。
struct ProviderEditorView: View {
    /// `nil` = 新建。
    let provider: LLMProvider?
    let namespace: String?
    let isNew: Bool

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var providerId = ""
    @State private var displayName = ""
    @State private var baseURL = ""
    @State private var api = LLMProvider.knownAPIs[0]
    @State private var apiKeyEnv = ""
    @State private var models: [LLMModel] = []
    @State private var editingModel: LLMModel?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var hasLoaded = false
    /// 新密钥。**只写不读** —— 拉回来的只有 `credential`（配过没有）。
    @State private var apiKey = ""
    @State private var credential: CredentialInfo?
    @State private var clearKey = false

    private var isValid: Bool {
        !providerId.trimmingCharacters(in: .whitespaces).isEmpty
            && !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // 输入框用 `prompt:` 而不是标题：这些是**示例值**，
                    // 不是要翻译的文案（写成标题会被抽进本地化目录）。
                    // 可读标签由外面的 `LabeledContent` 提供。
                    LabeledContent("标识") {
                        TextField("", text: $providerId, prompt: Text(verbatim: "wb"))
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .disabled(!isNew)
                    }
                    LabeledContent("名称") {
                        TextField("", text: $displayName, prompt: Text(verbatim: "WB")).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("地址") {
                        TextField("", text: $baseURL, prompt: Text(verbatim: "http://…:8788/v1"))
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                    }
                    Picker("协议", selection: $api) {
                        ForEach(LLMProvider.knownAPIs, id: \.self) { Text($0).tag($0) }
                    }
                    LabeledContent("密钥名") {
                        TextField("", text: $apiKeyEnv, prompt: Text(verbatim: "WB_API_KEY"))
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                } header: {
                    Text("提供商")
                } footer: {
                    // 说清"标识"为什么不能改：它是别的配置引用这个提供商的键。
                    Text("「标识」是别的配置引用这个提供商用的键，建好之后不能改。\n\n「密钥名」是电脑端凭据库里的**名字**，密钥原文在下面单独填。")
                }

                // 密钥单独一段：**只写不读**。电脑端只回"配过没有"，
                // 原文既不在手机上、也不会被拉回来。
                Section {
                    HStack {
                        Label("密钥", systemImage: "key")
                        Spacer()
                        if credential?.configured == true {
                            Label("已配置", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                                .labelStyle(.titleAndIcon)
                        } else if credential?.writable == false {
                            Text("由电脑上的环境变量提供")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("未配置")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    if credential?.writable != false {
                        SecureField("粘贴 API 密钥", text: $apiKey)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        if credential?.configured == true, !apiKey.isEmpty {
                            Text("保存后会覆盖电脑上已有的那个密钥。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if credential?.configured == true, apiKey.isEmpty {
                            Button("清除这个密钥", role: .destructive) { clearKey = true }
                        }
                    }
                } header: {
                    Text("密钥")
                } footer: {
                    Text("密钥**只写不读**：走的是已经端到端加密的 iroh 通道，存在电脑端的凭据库里；之后手机只能查到「配过没有」，拉不回原文。")
                }

                Section {
                    ForEach(models) { entry in
                        Button {
                            editingModel = entry
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name)
                                    Text(entry.id).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                                }
                                Spacer()
                                if let window = entry.contextWindow {
                                    Text(Format.tokens(window) ?? "")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .frame(minHeight: Token.minimumHitTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("删除", role: .destructive) {
                                models.removeAll { $0.id == entry.id }
                            }
                        }
                    }
                    Button {
                        editingModel = LLMModel(id: "", name: "", contextWindow: nil, maxTokens: nil)
                    } label: {
                        Label("添加模型", systemImage: "plus.circle")
                    }
                } header: {
                    Text(String(format: String(localized: "模型 · %lld"), models.count))
                } footer: {
                    Text("左滑删除。模型里没在界面上列出的字段（推理档位、模板参数…）会**原样保留**。\n\n模型 id 要和电脑端认的完全一致，否则这个提供商会保存失败。")
                }
            }
            .navigationTitle(isNew ? String(localized: "添加提供商") : displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("保存") { save() }.disabled(!isValid)
                    }
                }
            }
            .task {
                guard !hasLoaded else { return }
                hasLoaded = true
                if let provider {
                    providerId = provider.id
                    displayName = provider.displayName
                    baseURL = provider.baseURL
                    api = provider.api
                    apiKeyEnv = provider.apiKeyEnv
                    models = provider.models
                    await refreshCredential()
                }
            }
            .confirmationDialog("清除这个密钥？", isPresented: $clearKey, titleVisibility: .visible) {
                Button("清除", role: .destructive) {
                    Task { await unsetCredential() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("电脑上那个提供商会立刻用不了，直到重新填一个。")
            }
            .sheet(item: $editingModel) { entry in
                ModelEditorView(model: entry) { updated in
                    if let index = models.firstIndex(where: { $0.id == entry.id }) {
                        models[index] = updated
                    } else {
                        models.append(updated)
                    }
                }
            }
            .alert("保存失败", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("知道了", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    /// 查这个 ref 配了没有。**查不到值** —— 线上就不给。
    private func refreshCredential() async {
        let ref = apiKeyEnv.trimmingCharacters(in: .whitespaces)
        guard !ref.isEmpty else { credential = nil; return }
        credential = try? await model.client.credentialsDescribe(refs: [ref])[ref]
    }

    private func unsetCredential() async {
        let ref = apiKeyEnv.trimmingCharacters(in: .whitespaces)
        guard !ref.isEmpty else { return }
        do {
            try await model.client.credentialsUnset(ref: ref)
            await refreshCredential()
        } catch {
            errorMessage = (error as? DSHClientError)?.displayMessage ?? error.localizedDescription
        }
    }

    private func save() {
        guard let namespace else { return }
        let id = providerId.trimmingCharacters(in: .whitespaces)
        let draft = LLMProvider(
            id: id,
            raw: provider?.raw ?? .object([:])
        )
        var updated = draft
        updated.displayName = displayName.isEmpty ? id : displayName
        updated.baseURL = baseURL.trimmingCharacters(in: .whitespaces)
        updated.api = api
        updated.apiKeyEnv = apiKeyEnv.trimmingCharacters(in: .whitespaces)
        updated.models = models

        isSaving = true
        Task {
            // 先写密钥（如果有）—— 设置里只放 ref，密钥本体进凭据库。
            let ref = apiKeyEnv.trimmingCharacters(in: .whitespaces)
            if !apiKey.isEmpty, !ref.isEmpty {
                do {
                    try await model.client.credentialsSet(ref: ref, value: apiKey)
                } catch {
                    errorMessage = (error as? DSHClientError)?.displayMessage ?? error.localizedDescription
                    isSaving = false
                    return
                }
            }
            // 用 `set` 精确写到 `providers.<id>`：**不要**重写整个 `providers`，
            // 那样会把别的提供商也一起覆盖（并发改动会丢）。
            errorMessage = await model.mutateSettings(
                namespace: namespace,
                operations: [("set", ["providers", id], updated.mergedJSON())],
                expectedRevision: model.hostSettings?.namespace(namespace)?.revision
            )
            isSaving = false
            if errorMessage == nil { dismiss() }
        }
    }
}

/// 编辑一个模型。只动四个字段，其余原样保留。
struct ModelEditorView: View {
    let model: LLMModel
    let onSave: (LLMModel) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var id = ""
    @State private var name = ""
    @State private var contextWindow = ""
    @State private var maxTokens = ""
    @State private var hasLoaded = false

    private var isValid: Bool { !id.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("模型 id") {
                        TextField("", text: $id, prompt: Text(verbatim: "deepseek-v4.1-flash"))
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    LabeledContent("名称") {
                        TextField("", text: $name, prompt: Text(verbatim: "Deepseek-V4.1-Flash")).multilineTextAlignment(.trailing)
                    }
                } footer: {
                    Text("模型 id 必须跟服务端认的那个完全一致，写错会选不中。")
                }

                Section("容量") {
                    LabeledContent("上下文窗口") {
                        TextField("", text: $contextWindow, prompt: Text(verbatim: "1000000"))
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                    }
                    LabeledContent("单次输出上限") {
                        TextField("", text: $maxTokens, prompt: Text(verbatim: "64000"))
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                    }
                }
            }
            .navigationTitle(String(localized: "模型"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var updated = model
                        updated.id = id.trimmingCharacters(in: .whitespaces)
                        updated.name = name
                        updated.contextWindow = Int(contextWindow)
                        updated.maxTokens = Int(maxTokens)
                        onSave(updated)
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
            .task {
                guard !hasLoaded else { return }
                hasLoaded = true
                id = model.id
                name = model.name
                contextWindow = model.contextWindow.map(String.init) ?? ""
                maxTokens = model.maxTokens.map(String.init) ?? ""
            }
        }
    }
}
