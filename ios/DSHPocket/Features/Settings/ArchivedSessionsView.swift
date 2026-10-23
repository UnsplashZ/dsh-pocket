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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    clearArchivedCache()
                } label: {
                    Label("清缓存", systemImage: "trash.slash")
                }
                .disabled(model.archivedSessions.isEmpty)
                .help("清掉已归档会话的本地缓存（不影响未归档的）")
            }
        }
        // 同列表页：下拉是显式动作，绕过 15 秒节流。
        .refreshable { await model.refreshSessions(force: true) }
        .overlay {
            if isWorking {
                // 阻塞式加载态要有底衬，否则转圈浮在列表上像是渲染错位。
                ZStack {
                    Color(.systemBackground).opacity(0.5).ignoresSafeArea()
                    ProgressView().controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    .font(Token.Typography.sectionTitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 1 : 2)
            }
            HStack(spacing: Token.Spacing.tight) {
                Text(summary.workspaceName)
                    .font(Token.Typography.secondary)
                    .foregroundStyle(.tertiary)
                Text(Format.relativeTime(summary.updatedAt))
                    .font(Token.Typography.secondary)
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

    /// 清掉所有归档会话的本地缓存（保留未归档的）。
    private func clearArchivedCache() {
        isWorking = true
        Task {
            await model.clearArchivedSessionCache()
            isWorking = false
        }
    }
}
