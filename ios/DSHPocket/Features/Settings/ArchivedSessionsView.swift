import DSHKit
import SwiftUI

/// 已归档会话的管理页。
///
/// 为什么归档要单独一页（而不是像以前那样留在列表里）：本机实测有 **32 个**归档会话，
/// 混在对话列表里会把真正在用的那几个淹掉。归档的语义本来就是"收起来"，
/// 那就该有个明确的"放东西的地方"，而不是"变灰但仍然占位置"。
struct ArchivedSessionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var query = ""
    @State private var pendingUnarchive: SessionSummary?
    @State private var isWorking = false

    var body: some View {
        List {
            if filtered.isEmpty {
                ContentUnavailableView(
                    "没有归档的会话",
                    systemImage: "archivebox",
                    description: Text("左滑会话列表里的行就能把它归档到这里。")
                )
            } else {
                ForEach(filtered) { summary in
                    row(summary)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button {
                                unarchive(summary)
                            } label: {
                                Label("恢复", systemImage: "tray.and.arrow.up")
                            }
                            .tint(.accentColor)
                        }
                        .contextMenu {
                            Button {
                                unarchive(summary)
                            } label: {
                                Label("恢复到对话列表", systemImage: "tray.and.arrow.up")
                            }
                            Button {
                                UIPasteboard.general.string = summary.sessionId
                            } label: {
                                Label("复制会话 ID", systemImage: "doc.on.doc")
                            }
                        }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: Text("搜索已归档的会话"))
        .navigationTitle("已归档")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.refreshSessions() }
        .overlay {
            if isWorking {
                ProgressView().controlSize(.large)
            }
        }
        .confirmationDialog(
            "恢复这个会话？",
            isPresented: Binding(get: { pendingUnarchive != nil }, set: { if !$0 { pendingUnarchive = nil } }),
            titleVisibility: .visible
        ) {
            Button("恢复到对话列表") {
                if let target = pendingUnarchive { unarchive(target) }
                pendingUnarchive = nil
            }
            Button("取消", role: .cancel) { pendingUnarchive = nil }
        } message: {
            Text(pendingUnarchive?.title ?? "")
        }
        .task { await model.refreshSessions() }
    }

    private func row(_ summary: SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: Token.Spacing.hairline) {
            Text(summary.title)
                .font(.headline)
                .lineLimit(1)
            if !summary.subtitle.isEmpty {
                Text(summary.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 1 : 2)
            }
            HStack(spacing: Token.Spacing.tight) {
                Text(summary.workspaceName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(Format.relativeTime(summary.updatedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, Token.Spacing.hairline)
        .accessibilityElement(children: .combine)
        // 先在 String 里拼好：插值字面量会被当成 LocalizedStringKey，
        // 生成一条 `%@，%@，%@` 这种毫无意义的 key。
        .accessibilityLabel(Text(accessibilityLabel(for: summary)))
        .accessibilityHint(Text("左滑可恢复到对话列表"))
    }

    private var filtered: [SessionSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return model.archivedSessions }
        return model.archivedSessions.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed)
                || $0.subtitle.localizedCaseInsensitiveContains(trimmed)
                || $0.workspaceName.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private func accessibilityLabel(for summary: SessionSummary) -> String {
        "\(summary.title)，\(summary.workspaceName)，\(Format.relativeTime(summary.updatedAt))"
    }

    private func unarchive(_ summary: SessionSummary) {
        isWorking = true
        Task {
            await model.unarchive(summary.sessionId)
            isWorking = false
        }
    }
}
