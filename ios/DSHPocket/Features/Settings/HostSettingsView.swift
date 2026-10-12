import DSHKit
import SwiftUI

/// 主机设置。
///
/// 这里改的是**电脑上的**配置，不是 App 自己的 —— 所以每一项都走 DSH 的协议：
///   · 插件开关：`pluginManager/listPlugins` + `pluginManager/setPluginEnabled`
///   · 默认模型/思考等级：`settings/describe` + `settings/mutate`（命名空间 `agent-default-model`）
///
/// 刻意只做"少量设置"：能在这两个端点里安全表达的才放上来。
/// 主机的其余设置（密钥、沙箱、搜索……）在电脑上改更合适，手机上改反而危险。
struct HostSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var showModelPicker = false
    @State private var pendingDisable: HostPlugin?
    @State private var workingPluginId: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if !model.connection.isConnected {
                    Section {
                        Label("先连上电脑才能改这些。", systemImage: "wifi.slash")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    modelSection
                    pluginsSection
                }
            }
            .navigationTitle("电脑设置")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text("搜索插件")
            )
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if model.isLoadingHostSettings { ProgressView().controlSize(.small) }
                }
            }
            .task { await model.refreshHostSettings(); await model.refreshHostPlugins() }
            .refreshable { await model.refreshHostSettings(); await model.refreshHostPlugins() }
            .sheet(isPresented: $showModelPicker) {
                DefaultModelPickerSheet()
            }
            .confirmationDialog(
                "停用这个插件？",
                isPresented: Binding(get: { pendingDisable != nil }, set: { if !$0 { pendingDisable = nil } }),
                titleVisibility: .visible
            ) {
                Button("停用", role: .destructive) {
                    if let plugin = pendingDisable { toggle(plugin, to: false) }
                    pendingDisable = nil
                }
                Button("取消", role: .cancel) { pendingDisable = nil }
            } message: {
                Text("停用后，依赖它的功能会立刻失效（比如 IM 插件停掉之后频道会话就不再更新）。在电脑上重启 DSH 也能恢复。")
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

    // MARK: 默认模型

    @ViewBuilder
    private var modelSection: some View {
        Section {
            if let namespace = model.hostSettings?.namespace("agent-default-model") {
                Button {
                    showModelPicker = true
                } label: {
                    LabeledContent {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(modelLabel(namespace))
                                .foregroundStyle(.primary)
                            if let effort = namespace.value.string("reasoningEffort"), !effort.isEmpty {
                                Text(effort).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    } label: {
                        Label("默认模型", systemImage: "cpu")
                    }
                }
                .disabled(!namespace.isWritable)
            } else {
                Text(model.hostSettings == nil ? String(localized: "正在读取…") : String(localized: "这台电脑没有暴露默认模型设置。"))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("新会话的默认值")
        } footer: {
            Text("只影响**之后新建**的会话；已经在跑的会话各自保留自己的模型（那个在会话菜单里改）。")
        }
    }

    private func modelLabel(_ namespace: SettingsNamespace) -> String {
        let model = namespace.value.string("model") ?? ""
        let provider = namespace.value.string("provider") ?? ""
        guard !model.isEmpty else { return String(localized: "未设置") }
        return provider.isEmpty ? model : "\(provider) / \(model)"
    }

    // MARK: 插件

    @ViewBuilder
    private var pluginsSection: some View {
        if model.hostPlugins.isEmpty {
            Section {
                Text("没有读到插件清单。")
                    .foregroundStyle(.secondary)
            } header: {
                Text("插件")
            }
        } else {
            Section {
                ForEach(enabledPlugins) { plugin in
                    pluginRow(plugin)
                }
            } header: {
                Text("已启用 · \(enabledPlugins.count)")
            }

            if !disabledPlugins.isEmpty {
                Section {
                    ForEach(disabledPlugins) { plugin in
                        pluginRow(plugin)
                    }
                } header: {
                    Text("已停用 · \(disabledPlugins.count)")
                }
            }
        }
    }

    private func pluginRow(_ plugin: HostPlugin) -> some View {
        HStack(alignment: .top, spacing: Token.Spacing.tight) {
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.title)
                    .font(.body)
                    .lineLimit(1)
                // 大部分插件的 title 就等于 moduleName —— 那就别显示两遍。
                if plugin.title != plugin.moduleName {
                    Text(plugin.moduleName)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let reason = plugin.readOnlyExplanation {
                    Text(reason).font(.caption2).foregroundStyle(.tertiary)
                } else if plugin.enabled, plugin.fiberPhase != "active" {
                    Text(plugin.statusLabel).font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: Token.Spacing.tight)

            if workingPluginId == plugin.entryId {
                ProgressView().controlSize(.small)
            } else if plugin.isToggleable {
                Toggle("", isOn: Binding(
                    get: { plugin.enabled },
                    set: { newValue in
                        // 停用比启用危险得多（可能把正在用的能力掐掉），所以停用要确认；
                        // 启用是"恢复"，直接生效。
                        if newValue { toggle(plugin, to: true) } else { pendingDisable = plugin }
                    }
                ))
                .labelsHidden()
                .accessibilityLabel(Text(plugin.title))
                .accessibilityHint(Text(plugin.enabled ? "停用这个插件" : "启用这个插件"))
            } else {
                // 不能开关的要说明为什么，而不是摆一个灰开关让人猜。
                Image(systemName: "lock")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(Text(plugin.readOnlyExplanation ?? String(localized: "不可修改")))
            }
        }
        .frame(minHeight: Token.minimumHitTarget)
    }

    private func toggle(_ plugin: HostPlugin, to enabled: Bool) {
        workingPluginId = plugin.entryId
        Task {
            errorMessage = await model.setPluginEnabled(id: plugin.entryId, enabled: enabled)
            workingPluginId = nil
        }
    }

    private var filteredPlugins: [HostPlugin] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return model.hostPlugins }
        return model.hostPlugins.filter {
            $0.moduleName.localizedCaseInsensitiveContains(trimmed)
                || $0.title.localizedCaseInsensitiveContains(trimmed)
                || ($0.summary?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    private var enabledPlugins: [HostPlugin] {
        filteredPlugins.filter(\.enabled).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private var disabledPlugins: [HostPlugin] {
        filteredPlugins.filter { !$0.enabled }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

/// 改主机上的**默认模型**（新会话用哪个）。
///
/// 与 `ModelPickerSheet` 的区别：那个改的是**当前会话**（`session/selectModel`），
/// 这个改的是主机的设置命名空间（`settings/mutate` → `agent-default-model`）。
/// 两个都很容易被误解成对方，所以文案里各说清各的。
struct DefaultModelPickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case loading
        case ready(ModelCatalog)
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var provider = ""
    @State private var chosenModel = ""
    @State private var effort = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView("正在读取模型清单…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("读不到模型清单", systemImage: "cpu")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("重试") { Task { await load(force: true) } }
                            .buttonStyle(.borderedProminent)
                    }
                case .ready(let catalog):
                    picker(catalog)
                }
            }
            .navigationTitle("默认模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isSaving { ProgressView().controlSize(.small) }
                }
            }
            .task { await load() }
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

    @ViewBuilder
    private func picker(_ catalog: ModelCatalog) -> some View {
        List {
            ForEach(catalog.groups) { group in
                Section {
                    ForEach(group.models) { entry in
                        Button {
                            select(provider: group.id, model: entry.id, in: catalog)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: Token.Spacing.tight) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name)
                                    Text(entry.id).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: Token.Spacing.tight)
                                if provider == group.id, chosenModel == entry.id {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                            .frame(minHeight: Token.minimumHitTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(group.name)
                }
            }

            let efforts = catalog.reasoningEfforts(provider: provider, model: chosenModel)
            if !efforts.isEmpty {
                Section("思考等级") {
                    Picker("思考等级", selection: $effort) {
                        ForEach(efforts) { option in
                            Text(option.name).tag(option.id)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .onChange(of: effort) { _, _ in save() }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func load(force: Bool = false) async {
        if case .ready = phase, !force { return }
        phase = .loading
        do {
            let catalog = try await model.modelCatalog()
            // 初始值取主机设置里的当前值（不是当前会话的）。
            let current = model.hostSettings?.namespace("agent-default-model")?.value
            provider = current?.string("provider") ?? catalog.defaultSelection?.provider ?? ""
            chosenModel = current?.string("model") ?? catalog.defaultSelection?.model ?? ""
            effort = current?.string("reasoningEffort")
                ?? catalog.reasoningEfforts(provider: provider, model: chosenModel).first?.id
                ?? ""
            phase = .ready(catalog)
        } catch {
            phase = .failed((error as? DSHClientError)?.displayMessage ?? error.localizedDescription)
        }
    }

    private func select(provider newProvider: String, model newModel: String, in catalog: ModelCatalog) {
        provider = newProvider
        chosenModel = newModel
        let efforts = catalog.reasoningEfforts(provider: newProvider, model: newModel)
        if !efforts.contains(where: { $0.id == effort }) {
            effort = efforts.first?.id ?? ""
        }
        save()
    }

    private func save() {
        guard !provider.isEmpty, !chosenModel.isEmpty else { return }
        isSaving = true
        Task {
            var operations: [(op: String, path: [String], value: JSONValue)] = [
                ("set", ["provider"], .string(provider)),
                ("set", ["model"], .string(chosenModel)),
            ]
            if !effort.isEmpty { operations.append(("set", ["reasoningEffort"], .string(effort))) }
            errorMessage = await model.mutateSettings(
                namespace: "agent-default-model",
                operations: operations,
                // 乐观并发控制：传我们读到的那版 revision，别人改过就会被拒，
                // 而不是悄悄把对方的改动覆盖掉。
                expectedRevision: model.hostSettings?.namespace("agent-default-model")?.revision
            )
            isSaving = false
        }
    }
}
