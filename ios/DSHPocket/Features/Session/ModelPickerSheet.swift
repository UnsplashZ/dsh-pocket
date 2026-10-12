import DSHKit
import SwiftUI

/// 模型与推理强度。
///
/// 数据来自 `session/modelCatalog`，形状是 `groups[].models[]`（不是 `models[]`）——
/// 之前按 `models` 找，永远是空数组，于是这一页永远停在"正在读取模型清单…"。
///
/// 推理强度**按模型取**：实测不同模型的可选项不一样
/// （`hy4-preview-f` 只有 high，`deepseek-v4.1-flash` 有 low/high/max），
/// 所以不能写死一组选项。
struct ModelPickerSheet: View {
    let session: SessionModel

    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case loading
        case ready(ModelCatalog)
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var provider: String = ""
    @State private var model: String = ""
    @State private var effort: String = ""
    @State private var isApplying = false
    @State private var applyError: String?

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    // 居中的加载态。之前是 List 里一行的 ProgressView，
                    // 视觉上偏在左上角，看起来像卡住了。
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
                    if catalog.isEmpty {
                        ContentUnavailableView {
                            Label("这台电脑上没有可用模型", systemImage: "cpu")
                        } description: {
                            Text(catalog.failures.isEmpty
                                 ? "先在你电脑上的 DSH 里登录一个模型服务。"
                                 : catalog.failures.joined(separator: "\n"))
                        }
                    } else {
                        picker(catalog)
                    }
                }
            }
            .navigationTitle("模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isApplying { ProgressView().controlSize(.small) }
                }
            }
            .task { await load() }
            .alert("切换失败", isPresented: Binding(
                get: { applyError != nil },
                set: { if !$0 { applyError = nil } }
            )) {
                Button("知道了", role: .cancel) { applyError = nil }
            } message: {
                Text(applyError ?? "")
            }
        }
    }

    // MARK: 主体

    @ViewBuilder
    private func picker(_ catalog: ModelCatalog) -> some View {
        List {
            ForEach(catalog.groups) { group in
                Section {
                    ForEach(group.models) { entry in
                        Button {
                            select(provider: group.id, model: entry.id, in: catalog)
                        } label: {
                            row(entry, isCurrent: isCurrent(provider: group.id, model: entry.id))
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(group.name)
                }
            }

            let efforts = catalog.reasoningEfforts(provider: provider, model: model)
            if !efforts.isEmpty {
                Section {
                    Picker("推理强度", selection: $effort) {
                        ForEach(efforts) { option in
                            Text(option.name).tag(option.id)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .onChange(of: effort) { _, _ in apply() }
                } header: {
                    Text("推理强度")
                } footer: {
                    Text("只列出当前模型支持的档位 —— 不同模型的可选项不一样。")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func row(_ entry: ModelCatalogModel, isCurrent: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Token.Spacing.tight) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(entry.id)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: Token.Spacing.tight)
            if isCurrent {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .accessibilityLabel(Text("当前模型"))
            }
        }
        .frame(minHeight: Token.minimumHitTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(entry.name))
        .accessibilityValue(Text(isCurrent ? String(localized: "当前模型") : ""))
    }

    // MARK: 状态

    private func isCurrent(provider candidateProvider: String, model candidateModel: String) -> Bool {
        provider == candidateProvider && model == candidateModel
    }

    // MARK: 动作

    private func load(force: Bool = false) async {
        if case .ready = phase, !force { return }
        phase = .loading
        do {
            let catalog = try await session.loadModelCatalog()
            // 用会话当前的选择作为初始值；没有就用 catalog 的默认值。
            let current = session.modelSelection
            provider = current?.provider ?? catalog.defaultSelection?.provider ?? ""
            model = current?.model ?? catalog.defaultSelection?.model ?? ""
            effort = current?.reasoningEffort
                ?? catalog.reasoningEfforts(provider: provider, model: model).first?.id
                ?? ""
            phase = .ready(catalog)
        } catch {
            phase = .failed((error as? DSHClientError)?.displayMessage ?? error.localizedDescription)
        }
    }

    private func select(provider newProvider: String, model newModel: String, in catalog: ModelCatalog) {
        provider = newProvider
        model = newModel
        // 换模型时把推理强度收敛到新模型支持的档位之一，
        // 否则会把上一个模型的档位（比如 max）发给一个只支持 high 的模型。
        let efforts = catalog.reasoningEfforts(provider: newProvider, model: newModel)
        if !efforts.contains(where: { $0.id == effort }) {
            effort = efforts.first?.id ?? ""
        }
        apply()
    }

    private func apply() {
        guard !provider.isEmpty, !model.isEmpty else { return }
        isApplying = true
        Task {
            do {
                try await session.selectModel(
                    provider: provider,
                    model: model,
                    reasoningEffort: effort.isEmpty ? nil : effort
                )
            } catch {
                applyError = (error as? DSHClientError)?.displayMessage ?? error.localizedDescription
            }
            isApplying = false
        }
    }
}
