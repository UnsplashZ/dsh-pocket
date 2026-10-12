import DSHKit
import SwiftUI

/// S1 会话列表。
///
/// 数据只来自 `session/list` 的 projections —— **不打开任何流**（省电省流，DESIGN §9）。
struct SessionListView: View {
    let onSelect: (SessionSummary) -> Void
    let onPair: () -> Void
    let onSettings: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var query = ""
    @State private var renaming: SessionSummary?
    @State private var renameText = ""
    @State private var showNewSession = false

    var body: some View {
        List {
            if !model.connection.isConnected {
                disconnectedSection
            }

            ForEach(groups, id: \.key) { group in
                Section {
                    ForEach(group.sessions) { summary in
                        Button {
                            onSelect(summary)
                        } label: {
                            SessionRow(summary: summary)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                Task { await model.archive(summary.sessionId) }
                            } label: {
                                Label("归档", systemImage: "archivebox")
                            }
                        }
                        .contextMenu {
                            Button {
                                renaming = summary
                                renameText = summary.title
                            } label: {
                                Label("重命名", systemImage: "pencil")
                            }
                            Button {
                                UIPasteboard.general.string = summary.sessionId
                            } label: {
                                Label("复制会话 ID", systemImage: "doc.on.doc")
                            }
                            Divider()
                            Button(role: .destructive) {
                                Task { await model.archive(summary.sessionId) }
                            } label: {
                                Label("归档", systemImage: "archivebox")
                            }
                        }
                    }
                } header: {
                    SectionHeader(group.key)
                } footer: {
                    if group.sessions.count > 1 {
                        Text("\(group.sessions.count) 个会话")
                            .font(.caption2)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("搜索标题或摘要"))
        .refreshable { await model.refreshSessions() }
        .navigationTitle("会话")
        .toolbar { toolbar }
        .overlay { emptyOverlay }
        .alert("重命名会话", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("标题", text: $renameText)
            Button("取消", role: .cancel) { renaming = nil }
            Button("保存") {
                if let target = renaming {
                    Task { await model.rename(target.sessionId, title: renameText) }
                }
                renaming = nil
            }
        }
        .confirmationDialog("新建会话", isPresented: $showNewSession, titleVisibility: .visible) {
            ForEach(workspaces, id: \.self) { workspace in
                Button(workspace) {
                    Task {
                        if let id = await model.createSession(cwd: workspace) {
                            await model.refreshSessions()
                            if let summary = model.sessions.first(where: { $0.sessionId == id }) {
                                onSelect(summary)
                            }
                        }
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会话会在所选工作区里创建。")
        }
    }

    // MARK: 分组

    private var filtered: [SessionSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return model.sessions }
        return model.sessions.filter { summary in
            summary.title.localizedCaseInsensitiveContains(trimmed)
                || summary.subtitle.localizedCaseInsensitiveContains(trimmed)
                || summary.workspaceName.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private struct Group: Identifiable {
        var id: String { key }
        let key: String
        let sessions: [SessionSummary]
    }

    private var groups: [Group] {
        let grouped = Dictionary(grouping: filtered) { $0.workspaceName }
        return grouped
            .map { Group(key: $0.key, sessions: $0.value.sorted { $0.updatedAt > $1.updatedAt }) }
            .sorted { lhs, rhs in
                let lhsDate = lhs.sessions.first?.updatedAt ?? .distantPast
                let rhsDate = rhs.sessions.first?.updatedAt ?? .distantPast
                return lhsDate > rhsDate
            }
    }

    private var workspaces: [String] {
        let paths = Set(model.sessions.compactMap(\.cwd))
        return paths.sorted()
    }

    // MARK: 状态

    @ViewBuilder
    private var disconnectedSection: some View {
        Section {
            VStack(alignment: .leading, spacing: Token.Spacing.tight) {
                Label {
                    Text(model.connection.label)
                        .font(.headline)
                } icon: {
                    Image(systemName: model.connection.isConnected ? "checkmark.circle.fill" : "bolt.horizontal.circle")
                }
                .foregroundStyle(model.connection.isConnected ? Color.green : Color.secondary)

                if case .failed(let message) = model.connection {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // 失败必须有可执行动作，不能只有一句"失败了"
                if let hostId = model.settings.activeHostId, !hostId.isEmpty {
                    Button {
                        Task { await model.connect(hostId: hostId, pairingCode: nil) }
                    } label: {
                        Label("重新连接", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        onPair()
                    } label: {
                        Label("连接电脑", systemImage: "qrcode")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.vertical, Token.Spacing.hairline)
        }
    }

    @ViewBuilder
    private var emptyOverlay: some View {
        if model.isLoadingSessions, model.sessions.isEmpty {
            ProgressView("正在读取会话…")
        } else if let error = model.sessionListError, model.sessions.isEmpty {
            ContentUnavailableView {
                Label("读不到会话", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("重试") { Task { await model.refreshSessions() } }
                    .buttonStyle(.borderedProminent)
            }
        } else if model.sessions.isEmpty, model.connection.isConnected {
            ContentUnavailableView {
                Label("还没有会话", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("在电脑上开一个会话，或者在这里新建一个。")
            } actions: {
                Button("新建会话") { showNewSession = true }
                    .buttonStyle(.borderedProminent)
            }
        } else if !query.isEmpty, filtered.isEmpty {
            ContentUnavailableView.search(text: query)
        }
    }

    // MARK: 工具栏

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            ConnectionIndicator()
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showNewSession = true
            } label: {
                Label("新建会话", systemImage: "square.and.pencil")
            }
            .disabled(!model.connection.isConnected)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                onSettings()
            } label: {
                Label("设置", systemImage: "gearshape")
            }
        }
    }
}

/// 顶栏连接状态：**小圆点 + 文字**，不做"假在线"。
struct ConnectionIndicator: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Token.Spacing.hairline) {
            StatusDot(tone: tone, label: model.connection.label)
            if case .connected = model.connection {
                Text(shortLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(model.connection.label))
    }

    private var tone: StatusTone {
        switch model.connection {
        case .connected: return model.muxState.isHealthy ? .success : .warning
        case .connecting: return .info
        case .failed: return .failure
        case .idle: return .neutral
        }
    }

    private var shortLabel: String {
        if case .failed = model.connection { return String(localized: "断开") }
        return model.muxState.isHealthy ? String(localized: "已连接") : String(localized: "重连中")
    }
}
