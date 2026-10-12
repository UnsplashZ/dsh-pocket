import DSHKit
import SwiftUI

/// 模型切换。数据来自 `session/modelCatalog`。
struct ModelPickerSheet: View {
    let session: SessionModel

    @Environment(\.dismiss) private var dismiss
    @State private var catalog: JSONValue?
    @State private var error: String?
    @State private var isWorking = false
    @State private var effort: String = ""

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Section {
                        ContentUnavailableView {
                            Label("读不到模型清单", systemImage: "cpu")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("重试") { Task { await load() } }
                        }
                    }
                } else if models.isEmpty {
                    Section {
                        ProgressView("正在读取模型清单…")
                    }
                } else {
                    Section {
                        ForEach(models) { model in
                            Button {
                                select(model)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(model.name).font(.body).foregroundStyle(.primary)
                                        Text(model.provider)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                    if model.name == currentModel {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("可用模型")
                    } footer: {
                        Text("切换只影响这个会话。")
                    }

                    Section("推理强度") {
                        Picker("推理强度", selection: $effort) {
                            Text("跟随默认").tag("")
                            Text("低").tag("low")
                            Text("中").tag("medium")
                            Text("高").tag("high")
                            Text("最高").tag("max")
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
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
                    if isWorking { ProgressView().controlSize(.small) }
                }
            }
            .task { await load() }
        }
    }

    private var currentModel: String { session.modelLabel }

    private struct Model: Identifiable {
        var id: String { "\(provider)/\(name)" }
        var provider: String
        var name: String
    }

    /// `modelCatalog` 的形状在不同版本里变过，所以按"尽量多认几种"来解。
    private var models: [Model] {
        guard let catalog else { return [] }
        let entries = catalog.array("models")
            ?? catalog.array("catalog")
            ?? catalog.array("providers")
            ?? []
        var seen = Set<String>()
        var result: [Model] = []
        for entry in entries {
            let provider = entry.string("provider") ?? entry.string("id") ?? entry.string("name") ?? ""
            let nested = entry.array("models") ?? entry.array("items")
            if let nested {
                for item in nested {
                    let name = item.string("id") ?? item.string("model") ?? item.string("name") ?? ""
                    guard !name.isEmpty else { continue }
                    let model = Model(provider: provider, name: name)
                    if seen.insert(model.id).inserted { result.append(model) }
                }
            } else {
                let name = entry.string("id") ?? entry.string("model") ?? entry.string("name") ?? ""
                guard !name.isEmpty else { continue }
                let model = Model(provider: provider, name: name)
                if seen.insert(model.id).inserted { result.append(model) }
            }
        }
        return result
    }

    private func load() async {
        catalog = await session.loadModelCatalog()
        if catalog == nil { error = String(localized: "电脑没有返回模型清单。") }
    }

    private func select(_ model: Model) {
        isWorking = true
        Task {
            await session.selectModel(
                provider: model.provider,
                model: model.name,
                reasoningEffort: effort.isEmpty ? nil : effort
            )
            isWorking = false
            dismiss()
        }
    }
}
