import DSHKit
import SwiftUI

/// 新建会话：选一个工作区。
///
/// 为什么不是 `confirmationDialog`：那是给"两三个动作"用的。本机有 8 个工作区，
/// 渲染出来是一串大灰胶囊、挤在没有滚动区的 action sheet 里（实测截图就是这个样子），
/// 而且**看不到路径** —— 两个同名目录根本分不出来。
///
/// 改成一个正经的 sheet：`List` 有滚动、可搜索、每行带完整路径、
/// 最近用过的排在前面。
struct NewSessionSheet: View {
    /// 会话建好之后交回给调用方去打开。
    let onCreated: (String, String?) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var creatingWorkspaceId: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if model.workspaceTargets.isEmpty {
                    ContentUnavailableView {
                        Label("还没有工作区", systemImage: "folder.badge.plus")
                    } description: {
                        Text("先在电脑上的 DSH 里添加一个工作区，然后再来这里新建会话。")
                    }
                } else {
                    list
                }
            }
            .navigationTitle("新建会话")
            .navigationBarTitleDisplayMode(.inline)
            // 必须显式指定 `.navigationBarDrawer`：不指定的话 iOS 26+ 会把它放到
            // **列表下方**（新的底部搜索位），在 sheet 里看起来像掉出来的控件。
            // 会话列表页用的是同一个 placement，所以两处观感一致。
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text("搜索工作区")
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if creatingWorkspaceId != nil { ProgressView().controlSize(.small) }
                }
            }
            .alert("建不了会话", isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            )) {
                Button("知道了", role: .cancel) { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(filtered) { target in
                    Button {
                        create(in: target)
                    } label: {
                        row(target)
                    }
                    .buttonStyle(.plain)
                    .disabled(creatingWorkspaceId != nil)
                }
            } footer: {
                Text("新建的会话会挂在这个工作区下面；选了工作区之后直接进会话页。")
            }
        }
        .listStyle(.insetGrouped)
    }

    private func row(_ target: AppModel.WorkspaceTarget) -> some View {
        HStack(alignment: .top, spacing: Token.Spacing.tight) {
            Image(systemName: "folder")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(target.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                // 完整路径：同名目录靠它区分，也让人确认到底建在哪。
                Text(target.cwd)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: Token.Spacing.tight)

            if creatingWorkspaceId == target.workspaceId {
                ProgressView().controlSize(.small)
            } else if target.sessionCount > 0 {
                Text(String(target.sessionCount))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(minHeight: Token.minimumHitTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(target.name))
        .accessibilityHint(Text(target.cwd))
    }

    /// 最近用过的工作区排在前面，其次按名字。
    private var filtered: [AppModel.WorkspaceTarget] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = trimmed.isEmpty
            ? model.workspaceTargets
            : model.workspaceTargets.filter {
                $0.name.localizedCaseInsensitiveContains(trimmed)
                    || $0.cwd.localizedCaseInsensitiveContains(trimmed)
            }
        // 最近用过的排前面：`WorkspaceView.updatedAt` 是 ISO 字符串，解析在 DSHKit 里做了。
        let recency = model.workspaces.reduce(into: [String: Date]()) { partial, workspace in
            partial[workspace.id] = workspace.updatedAt ?? .distantPast
        }
        return matches.sorted { lhs, rhs in
            let lhsDate = recency[lhs.workspaceId] ?? .distantPast
            let rhsDate = recency[rhs.workspaceId] ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func create(in target: AppModel.WorkspaceTarget) {
        creatingWorkspaceId = target.workspaceId
        Task {
            // 传 workspaceId：会话才会落在这个工作区下，而不是电脑端的「未分组」。
            let id = await model.createSession(workspaceId: target.workspaceId, cwd: target.cwd)
            creatingWorkspaceId = nil
            guard let id else {
                error = model.sessionListError ?? String(localized: "电脑没有返回新建的会话。")
                return
            }
            onCreated(id, target.cwd)
            dismiss()
        }
    }
}
