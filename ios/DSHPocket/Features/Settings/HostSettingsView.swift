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

    @State private var showModelPicker = false
    @State private var showAllPlugins = false
    @State private var showProviders = false
    @State private var pendingDisableBundle: HostBundle?
    @State private var workingBundleName: String?
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
                    providersSection
                    bundlesSection
                    // 一级页只放"包"。包里的单个插件（本机 202 条）挪到二级页，
                    // 那里有搜索 —— 平铺在一级页完全看不清。
                    Section {
                        Button {
                            showAllPlugins = true
                        } label: {
                            LabeledContent {
                                Text(String(model.hostPlugins.count))
                                    .foregroundStyle(.secondary)
                            } label: {
                                Label("全部插件", systemImage: "list.bullet.rectangle")
                            }
                        }
                        .disabled(model.hostPlugins.isEmpty)
                    } footer: {
                        Text("包里面的单个插件。平时不用管，排查问题时才需要看。")
                    }
                }
            }
            .navigationTitle("电脑设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if model.isLoadingHostSettings { ProgressView().controlSize(.small) }
                }
            }
            .task {
                await model.refreshHostSettings()
                await model.refreshHostPlugins(force: true)
                #if DEBUG
                if UserDefaults.standard.bool(forKey: "DSHShowProviders") { showProviders = true }
                #endif
            }
            .refreshable { await model.refreshHostSettings(); await model.refreshHostPlugins(force: true) }
            .sheet(isPresented: $showModelPicker) {
                DefaultModelPickerSheet()
            }
            .sheet(isPresented: $showAllPlugins) {
                PluginDetailView()
            }
            .sheet(isPresented: $showProviders) {
                ModelProvidersView()
            }
            .confirmationDialog(
                "停用这个插件包？",
                isPresented: Binding(get: { pendingDisableBundle != nil }, set: { if !$0 { pendingDisableBundle = nil } }),
                titleVisibility: .visible
            ) {
                Button("停用", role: .destructive) {
                    if let bundle = pendingDisableBundle { toggle(bundle, to: false) }
                    pendingDisableBundle = nil
                }
                Button("取消", role: .cancel) { pendingDisableBundle = nil }
            } message: {
                Text("停用后，这个包里提供的功能会立刻失效（比如 IM Connect 停掉之后频道会话就不再更新）。在电脑上重启 DSH 也能恢复。")
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
                                Text(effort).font(Token.Typography.secondary).foregroundStyle(.secondary)
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

    // MARK: 模型提供商

    @ViewBuilder
    private var providersSection: some View {
        if model.hostSettings?.namespaces.contains(where: { $0.value["providers"]?.objectValue != nil }) == true {
            Section {
                Button {
                    showProviders = true
                } label: {
                    LabeledContent {
                        Text(String(providerCount))
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("提供商与模型", systemImage: "server.rack")
                    }
                }
            } footer: {
                Text("新增、删除、修改提供商与模型。密钥不在手机上 —— 提供商配的是环境变量名。")
            }
        }
    }

    private var providerCount: Int {
        guard let ns = model.hostSettings?.namespaces.first(where: { $0.value["providers"]?.objectValue != nil })
        else { return 0 }
        return decodeProviders(ns).count
    }

    // MARK: 插件（包级别）

    /// 只展示**包**，不展示包里的单个插件。
    ///
    /// `listPlugins` 在本机是 202 条（`dsh-base` 一个包就 94 行），平铺出来完全看不清。
    /// 桌面端的「插件」页展示的就是这一层（本机 17 个包），每个带人类可读的标题与说明。
    @ViewBuilder
    private var bundlesSection: some View {
        if model.hostBundles.isEmpty {
            Section {
                Text(model.connection.isConnected
                     ? String(localized: "正在读取插件包…")
                     : String(localized: "先连上电脑才能改这些。"))
                    .foregroundStyle(.secondary)
            } header: {
                Text("插件")
            }
        } else {
            if !officialBundles.isEmpty {
                Section {
                    ForEach(officialBundles) { bundle in
                        bundleRow(bundle)
                    }
                } header: {
                    Text(String(format: String(localized: "官方 · %lld"), officialBundles.count))
                }
            }
            if !installedBundles.isEmpty {
                Section {
                    ForEach(installedBundles) { bundle in
                        bundleRow(bundle)
                    }
                } header: {
                    Text(String(format: String(localized: "已安装 · %lld"), installedBundles.count))
                }
            }
            if !systemBundles.isEmpty {
                Section {
                    ForEach(systemBundles) { bundle in
                        bundleRow(bundle)
                    }
                } header: {
                    Text("系统")
                } footer: {
                    Text("这些是组成 DSH 本身的层，不能单独关掉。")
                }
            }
        }
    }

    private func bundleRow(_ bundle: HostBundle) -> some View {
        HStack(alignment: .top, spacing: Token.Spacing.tight) {
            Image(systemName: bundle.isOfficial ? "shippingbox" : "puzzlepiece.extension")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Token.Spacing.hairline) {
                    Text(bundle.title)
                        .font(.body)
                        .lineLimit(1)
                    if bundle.optional {
                        Text("实验性")
                            .font(Token.Typography.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                // 说明是这一层最有价值的东西 —— 标题之外得知道它是干嘛的。
                if let summary = bundle.summary, !summary.isEmpty {
                    Text(summary)
                        .font(Token.Typography.secondary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if bundle.title != bundle.name {
                    Text(bundle.name)
                        .font(Token.Typography.identifier)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: Token.Spacing.tight)

            if workingBundleName == bundle.name {
                ProgressView().controlSize(.small)
            } else if bundle.isToggleable {
                Toggle("", isOn: Binding(
                    get: { bundle.enabled },
                    set: { newValue in
                        // 停用比启用危险得多（可能把正在用的能力掐掉），所以要确认；
                        // 启用是"恢复"，直接生效。
                        if newValue { toggle(bundle, to: true) } else { pendingDisableBundle = bundle }
                    }
                ))
                .labelsHidden()
                .accessibilityLabel(Text(bundle.title))
            } else {
                Image(systemName: "lock")
                    .font(Token.Typography.secondary)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(Text(bundle.readOnlyExplanation ?? String(localized: "不可修改")))
            }
        }
        .frame(minHeight: Token.minimumHitTarget)
    }

    /// 官方（随应用分发）、可选。
    private var officialBundles: [HostBundle] {
        model.hostBundles
            .filter { $0.isOfficial && $0.optional }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// 用户自己装的。
    private var installedBundles: [HostBundle] {
        model.hostBundles
            .filter { !$0.isOfficial && $0.installed }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// 组成 DSH 本身的层，以及别的不可开关的包。
    private var systemBundles: [HostBundle] {
        model.hostBundles
            .filter { !$0.isToggleable || (!$0.optional && !$0.installed) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func toggle(_ bundle: HostBundle, to enabled: Bool) {
        workingBundleName = bundle.name
        Task {
            errorMessage = await model.setBundleEnabled(name: bundle.name, enabled: enabled)
            workingBundleName = nil
        }
    }
}

/// 二级页：**全部插件**（包里的单个插件）。
///
/// 一级页只展示包（17 个）。这一层有 202 条，只有按需查阅才有意义，
/// 所以单独一页 + 搜索，不挤在一级页里。
struct PluginDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var pendingDisable: HostPlugin?
    @State private var workingPluginId: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(enabledPlugins) { plugin in
                        row(plugin)
                    }
                } header: {
                    Text(String(format: String(localized: "已启用 · %lld"), enabledPlugins.count))
                }

                if !disabledPlugins.isEmpty {
                    Section {
                        ForEach(disabledPlugins) { plugin in
                            row(plugin)
                        }
                    } header: {
                        Text(String(format: String(localized: "已停用 · %lld"), disabledPlugins.count))
                    }
                }
            }
            .navigationTitle("全部插件")
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
                Text("停用后，依赖它的功能会立刻失效。在电脑上重启 DSH 也能恢复。")
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

    private func row(_ plugin: HostPlugin) -> some View {
        HStack(alignment: .top, spacing: Token.Spacing.tight) {
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.title)
                    .font(.body)
                    .lineLimit(1)
                // 大部分插件的 title 就等于 moduleName —— 那就别显示两遍。
                if plugin.title != plugin.moduleName {
                    Text(plugin.moduleName)
                        .font(Token.Typography.identifier)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let reason = plugin.readOnlyExplanation {
                    Text(reason).font(Token.Typography.secondary).foregroundStyle(.tertiary)
                } else if plugin.enabled, plugin.fiberPhase != "active" {
                    Text(plugin.statusLabel).font(Token.Typography.secondary).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: Token.Spacing.tight)

            if workingPluginId == plugin.entryId {
                ProgressView().controlSize(.small)
            } else if plugin.isToggleable {
                Toggle("", isOn: Binding(
                    get: { plugin.enabled },
                    set: { newValue in
                        if newValue { toggle(plugin, to: true) } else { pendingDisable = plugin }
                    }
                ))
                .labelsHidden()
                .accessibilityLabel(Text(plugin.title))
            } else {
                Image(systemName: "lock")
                    .font(Token.Typography.secondary)
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

    private var filtered: [HostPlugin] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return model.hostPlugins }
        return model.hostPlugins.filter {
            $0.moduleName.localizedCaseInsensitiveContains(trimmed)
                || $0.title.localizedCaseInsensitiveContains(trimmed)
                || ($0.summary?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    private var enabledPlugins: [HostPlugin] {
        filtered.filter(\.enabled).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private var disabledPlugins: [HostPlugin] {
        filtered.filter { !$0.enabled }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
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
                                    Text(entry.id).font(Token.Typography.identifier).foregroundStyle(.tertiary)
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
