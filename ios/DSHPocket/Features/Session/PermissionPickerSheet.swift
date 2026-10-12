import DSHKit
import SwiftUI

/// 文件读写 / 审批权限档位。
///
/// 这是 DSH 客户端协议里**唯一**能改权限的入口：
///   · 读：`permissionPresets/catalog`（只有 `catalog`，没有写方法）
///   · 写：跑斜杠命令 `/permission <preset>` —— `dsh-permission-presets` 注册的命令
///
/// 直接改 `settings/*` 也能改，但那是"**新会话的默认值**"，不是当前这个会话 ——
/// 用户要的是"我现在这个会话怎么跑"，所以走命令。
struct PermissionPickerSheet: View {
    let session: SessionModel

    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case loading
        case ready(PermissionPresetCatalog)
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var isApplying = false
    @State private var applyError: String?
    @State private var confirmRisky: PermissionPreset?

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView("正在读取权限档位…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .failed(let message):
                    ContentUnavailableView {
                        Label("读不到权限档位", systemImage: "lock")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("重试") { Task { await load(force: true) } }
                            .buttonStyle(.borderedProminent)
                    }

                case .ready(let catalog):
                    list(catalog)
                }
            }
            .navigationTitle("权限")
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
            .confirmationDialog(
                "启用完全权限？",
                isPresented: Binding(get: { confirmRisky != nil }, set: { if !$0 { confirmRisky = nil } }),
                titleVisibility: .visible
            ) {
                Button("我已了解风险，仍然启用", role: .destructive) {
                    if let preset = confirmRisky { apply(preset) }
                    confirmRisky = nil
                }
                Button("取消", role: .cancel) { confirmRisky = nil }
            } message: {
                Text("完全权限会读写不受工作区限制，并减少确认步骤 —— 包括敏感操作、文件修改和外部命令。仅在你信任接下来的任务时使用。")
            }
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

    @ViewBuilder
    private func list(_ catalog: PermissionPresetCatalog) -> some View {
        List {
            Section {
                ForEach(catalog.options) { preset in
                    Button {
                        choose(preset)
                    } label: {
                        row(preset)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("当前会话")
            } footer: {
                Text("只影响这个会话。改完电脑端会记一条权限变更，时间线上也看得到。")
            }

            if let current = session.currentPermission {
                Section("现在") {
                    LabeledContent("档位", value: label(for: current, in: catalog))
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func row(_ preset: PermissionPreset) -> some View {
        let isCurrent = session.currentPermission == preset.value
        return HStack(alignment: .top, spacing: Token.Spacing.tight) {
            Image(systemName: preset.symbol)
                .font(.body)
                .foregroundStyle(preset.isRisky ? Color.orange : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(label(for: preset.value, in: currentCatalog))
                    .font(.body)
                    .foregroundStyle(.primary)
                if let explanation = preset.explanation {
                    Text(explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Token.Spacing.tight)
            if isCurrent {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .accessibilityLabel(Text("当前档位"))
            }
        }
        .frame(minHeight: Token.minimumHitTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(label(for: preset.value, in: currentCatalog)))
        .accessibilityValue(Text(isCurrent ? String(localized: "当前档位") : ""))
    }

    private var currentCatalog: PermissionPresetCatalog {
        if case .ready(let catalog) = phase { return catalog }
        return PermissionPresetCatalog()
    }

    /// 档位的中文名。用 DSH 自己的措辞（`permission.access` 词典）而不是直译，
    /// 这样手机和电脑上是同一套说法。
    private func label(for value: String, in catalog: PermissionPresetCatalog) -> String {
        switch value {
        case "read-only": return String(localized: "仅可查看")
        case "workspace-write": return String(localized: "工作区内修改")
        case "danger-full-access": return String(localized: "完全权限")
        default: return catalog.options.first { $0.value == value }?.name ?? value
        }
    }

    // MARK: 动作

    private func load(force: Bool = false) async {
        if case .ready = phase, !force { return }
        phase = .loading
        do {
            phase = .ready(try await session.loadPermissionPresets())
        } catch {
            phase = .failed((error as? DSHClientError)?.displayMessage ?? error.localizedDescription)
        }
    }

    private func choose(_ preset: PermissionPreset) {
        guard session.currentPermission != preset.value else { return }
        if preset.isRisky {
            confirmRisky = preset
        } else {
            apply(preset)
        }
    }

    private func apply(_ preset: PermissionPreset) {
        isApplying = true
        Task {
            do {
                try await session.selectPermissionPreset(preset.value)
            } catch {
                applyError = (error as? DSHClientError)?.displayMessage ?? error.localizedDescription
            }
            isApplying = false
        }
    }
}
