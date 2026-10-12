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
    /// 正在跑、需要先停下来才能归档的会话。
    @State private var archivingRunning: SessionSummary?
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
                            SessionRow(
                                summary: summary,
                                isPinned: model.pinnedSessionIds.contains(summary.sessionId)
                            )
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                requestArchive(summary)
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
                                requestArchive(summary)
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
        // 归档一个正在跑的会话：宿主会拒绝（workspace/session-active），
        // 所以先问清楚 —— 同意的话我们会带 stopActivity 一起提交。
        .confirmationDialog(
            "这个会话正在跑",
            isPresented: Binding(
                get: { archivingRunning != nil },
                set: { if !$0 { archivingRunning = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("停止并归档", role: .destructive) {
                if let target = archivingRunning {
                    Task { await model.archive(target.sessionId, stopActivity: true) }
                }
                archivingRunning = nil
            }
            Button("取消", role: .cancel) { archivingRunning = nil }
        } message: {
            Text("归档会先把这一轮停掉。已经跑出来的内容会保留。")
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

    /// 归档请求的入口：正在跑的会话先确认，其余直接归档。
    private func requestArchive(_ summary: SessionSummary) {
        if summary.isRunning {
            archivingRunning = summary
        } else {
            Task { await model.archive(summary.sessionId) }
        }
    }

    // MARK: 分组

    private var filtered: [SessionSummary] {
        // 已归档的会话统一去「设置 → 已归档」管理，不混进对话列表（否则本机 32 个归档
        // 会把列表彻底淹没）。
        let active = model.activeSessions
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return active }
        return active.filter { summary in
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
            HStack(spacing: Token.Spacing.tight) {
                Image(systemName: disconnectedSymbol)
                    .font(.title3)
                    .foregroundStyle(disconnectedTone.color)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.connection.label)
                        .font(.headline)
                    Text(disconnectedDetail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, Token.Spacing.hairline)
            .accessibilityElement(children: .combine)

            if case .failed = model.connection {
                // 失败不能只有一句"失败了"：给一条用户当下能做的事。
                VStack(alignment: .leading, spacing: 2) {
                    Text("先试这三件事")
                        .font(.footnote.weight(.semibold))
                    Text("1. 确认电脑上的 DSH 开着、插件已加载；\n2. 手机设置里允许本 App 使用「本地网络」；\n3. 关掉手机上的代理/VPN 再连一次（它会接管 UDP，打洞会失败）。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, Token.Spacing.hairline)
                .accessibilityElement(children: .combine)
            }

            // 行样式而不是大胶囊：List 里 `.borderedProminent` 会被撑成整行宽，
            // 视觉上像个横幅而不是一个动作。
            Button {
                if let hostId = model.settings.activeHostId, !hostId.isEmpty {
                    Task { await model.connect(hostId: hostId, pairingCode: nil) }
                } else {
                    onPair()
                }
            } label: {
                Label(disconnectedActionTitle, systemImage: disconnectedActionSymbol)
            }
            .disabled(isConnecting)
        }
    }

    private var isConnecting: Bool {
        if case .connecting = model.connection { return true }
        return false
    }

    private var disconnectedSymbol: String {
        switch model.connection {
        case .connecting: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "bolt.horizontal.circle"
        }
    }

    private var disconnectedTone: StatusTone {
        switch model.connection {
        case .connecting: return .info
        case .failed: return .failure
        default: return .neutral
        }
    }

    private var disconnectedDetail: String {
        switch model.connection {
        case .connecting: return String(localized: "正在和电脑握手，第一次可能要几秒。")
        case .failed(let message): return message
        default: return String(localized: "配对一次之后，手机会记住这台电脑。")
        }
    }

    private var disconnectedActionTitle: String {
        if isConnecting { return String(localized: "正在连接…") }
        if let hostId = model.settings.activeHostId, !hostId.isEmpty {
            return String(localized: "重新连接")
        }
        return String(localized: "连接电脑")
    }

    private var disconnectedActionSymbol: String {
        if let hostId = model.settings.activeHostId, !hostId.isEmpty { return "arrow.clockwise" }
        return "qrcode"
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

/// 顶栏连接状态。
///
/// 工具栏里空间很窄，"已连接"三个字在中文下会被挤成竖排（实测过）——
/// 所以这里**只放一个圆点**，把文字放进无障碍标签与长按提示里。
/// 状态本身在列表首行也有完整表述，不需要在顶栏重复。
struct ConnectionIndicator: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        StatusDot(tone: tone, label: label)
            .frame(width: Token.minimumHitTarget, height: Token.minimumHitTarget)
            .accessibilityElement()
            .accessibilityLabel(Text(label))
            .accessibilityAddTraits(.isStaticText)
    }

    private var tone: StatusTone {
        switch model.connection {
        case .connected: return model.muxState.isHealthy ? .success : .warning
        case .connecting: return .info
        case .failed: return .failure
        case .idle: return .neutral
        }
    }

    private var label: String {
        switch model.connection {
        case .connected:
            return model.muxState.isHealthy
                ? String(localized: "已连接到电脑")
                : String(localized: "已连接，正在重连会话流")
        case .connecting:
            return String(localized: "正在连接电脑")
        case .failed(let message):
            return String(localized: "连接失败：\(message)")
        case .idle:
            return String(localized: "未连接")
        }
    }
}
