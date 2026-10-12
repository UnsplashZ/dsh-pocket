import DSHKit
import SwiftUI

/// S2 会话时间线。
///
/// 结构：`ScrollViewReader` + `ScrollView` + **`LazyVStack`**（不用 List：需要自定义排版与流式追加）。
/// 滚动策略：默认贴底；用户手动上滑即暂停自动滚动并出现「跳到最新」；滚到底自动恢复。
struct SessionView: View {
    let summary: SessionSummary

    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var session: SessionModel?
    @State private var showFiles = false
    @State private var showSettings = false
    @State private var showRawEvents = false
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showModelPicker = false
    @State private var showPermissionPicker = false
    @State private var showShadowed = false
    @State private var isFollowingBottom = true
    @State private var lastKnownTailId: String?
    @State private var highlightId: String?

    private let bottomAnchor = "timeline-bottom"

    var body: some View {
        Group {
            if let session {
                content(session)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(session?.title ?? summary.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task {
            #if DEBUG
            // 调试用：`defaults write cc.zexa.dshpocket DSHShowModelPicker -bool YES`
            if UserDefaults.standard.bool(forKey: "DSHShowModelPicker") { showModelPicker = true }
            if UserDefaults.standard.bool(forKey: "DSHShowPermissionPicker") { showPermissionPicker = true }
            #endif
            if session == nil {
                let created = SessionModel(
                    sessionId: summary.sessionId,
                    title: summary.title,
                    appModel: model
                )
                session = created
                await created.open()
            }
        }
        .onDisappear { session?.close() }
        .sheet(isPresented: $showFiles) {
            if let session {
                FilesSheet(scopeId: session.sessionId)
            }
        }
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        .sheet(isPresented: $showModelPicker) {
            if let session {
                ModelPickerSheet(session: session)
            }
        }
        .sheet(isPresented: $showPermissionPicker) {
            if let session {
                PermissionPickerSheet(session: session)
            }
        }
        .alert("重命名会话", isPresented: $showRename) {
            TextField("标题", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("保存") { Task { await session?.rename(to: renameText) } }
        }
    }

    // MARK: 主体

    @ViewBuilder
    private func content(_ session: SessionModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Token.Spacing.compact) {
                    if session.phase == .loading, session.items.isEmpty {
                        skeleton
                    }

                    if session.hasMoreHistory {
                        historyLoader(session)
                    }

                    if showShadowed, !session.shadowedItems.isEmpty {
                        shadowedSection(session)
                    }

                    ForEach(session.items.filter { !$0.isShadowed }) { item in
                        TimelineRow(item: item, session: session)
                            .id(item.id)
                            .padding(.horizontal, Token.Spacing.gutter)
                            .background(
                                RoundedRectangle(cornerRadius: Token.Radius.card, style: .continuous)
                                    .fill(highlightId == item.id ? Color.accentColor.opacity(0.12) : .clear)
                            )
                    }

                    // 排队中的消息放在最后。
                    //
                    // 它们**不在会话日志里**（只存在于 `inbox` 投影），所以不能靠
                    // 时间线条目渲染。不画出来的话，你在电脑上排队发的那条在手机上
                    // 完全看不到；而自己排队发的那条会一直显示成"发送中…"，
                    // 看起来像已经发出去了。
                    if !session.queuedMessages.isEmpty {
                        QueuedMessagesRow(messages: session.queuedMessages)
                            .padding(.horizontal, Token.Spacing.gutter)
                            .id("queued-messages")
                    }

                    if session.items.filter({ !$0.isShadowed }).isEmpty, session.phase != .loading {
                        ContentUnavailableView(
                            "这个会话还是空的",
                            systemImage: "text.bubble",
                            description: Text("在下面输入第一句话。")
                        )
                        .padding(.top, Token.Spacing.section)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchor)
                        .onAppear { isFollowingBottom = true }
                        .onDisappear { isFollowingBottom = false }
                }
                .padding(.vertical, Token.Spacing.compact)
                .textSelection(.enabled)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    PendingBanner()
                    statusBar(session)
                }
            }
            // 「跳到最新」要在**输入区之上**：overlay 必须先于 bottom inset 应用，
            // 否则它会贴在屏幕底边、压住发送按钮。
            .overlay(alignment: .bottomTrailing) {
                if !isFollowingBottom {
                    jumpToLatest(proxy)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Composer(session: session)
            }
            .onChange(of: session.items.last?.id) { _, newValue in
                guard isFollowingBottom, let newValue else { return }
                lastKnownTailId = newValue
                scrollToBottom(proxy, animated: true)
            }
            // 模型显式要求"滚到底"（快照分完、自己发了消息）：这时候布局已经稳定。
            .onChange(of: session.scrollToBottomTicket) { _, _ in
                isFollowingBottom = true
                scrollToBottom(proxy, animated: false)
            }
            .onChange(of: model.focusedApprovalId) { _, newValue in
                guard let newValue else { return }
                scroll(to: newValue, proxy: proxy)
            }
        }
    }

    // MARK: 局部

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: Token.Spacing.compact) {
            ForEach(0..<6, id: \.self) { index in
                Card {
                    VStack(alignment: .leading, spacing: Token.Spacing.tight) {
                        Text(String(repeating: "正在读取这条会话的内容 ", count: 2))
                            .font(.body)
                        Text(String(repeating: "从电脑上把历史取回来 ", count: 3))
                            .font(.footnote)
                    }
                    .redacted(reason: .placeholder)
                    .opacity(1 - Double(index) * 0.12)
                }
                .padding(.horizontal, Token.Spacing.gutter)
            }
        }
        .accessibilityLabel(Text("正在读取会话内容"))
    }

    private func historyLoader(_ session: SessionModel) -> some View {
        HStack {
            Spacer()
            if session.isLoadingHistory {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await session.loadOlderHistoryIfNeeded() }
                } label: {
                    Label("载入更早的内容", systemImage: "arrow.up.circle")
                }
                .buttonStyle(.bordered)
            }
            Spacer()
        }
        .padding(.vertical, Token.Spacing.tight)
        .onAppear { Task { await session.loadOlderHistoryIfNeeded() } }
    }

    private func shadowedSection(_ session: SessionModel) -> some View {
        DisclosureGroup(isExpanded: $showShadowed) {
            ForEach(session.shadowedItems) { item in
                TimelineRow(item: item, session: session)
                    .opacity(0.6)
            }
        } label: {
            Label("已被压缩取代的 \(session.shadowedItems.count) 条内容", systemImage: "arrow.triangle.merge")
                .font(.footnote)
        }
        .padding(.horizontal, Token.Spacing.gutter)
    }

    /// 顶栏状态条：连接中 / 已断开（可重试）/ 正在补历史 —— 三态必须分得清。
    @ViewBuilder
    private func statusBar(_ session: SessionModel) -> some View {
        if case .reconnecting(let reason) = session.phase {
            statusStrip(
                symbol: "arrow.clockwise",
                tone: .warning,
                title: String(localized: "连接断了，正在重连"),
                detail: reason
            )
        } else if case .failed(let message) = session.phase {
            statusStrip(
                symbol: "exclamationmark.triangle.fill",
                tone: .failure,
                title: String(localized: "连不上电脑"),
                detail: message,
                action: (String(localized: "重试"), { Task { await session.open() } })
            )
        } else if let failure = session.failureMessage {
            statusStrip(
                symbol: "exclamationmark.circle.fill",
                tone: .failure,
                title: String(localized: "上一步没成功"),
                detail: failure,
                action: (String(localized: "知道了"), { session.clearFailure() })
            )
        } else if session.isLoadingHistory {
            statusStrip(
                symbol: "clock.arrow.circlepath",
                tone: .info,
                title: String(localized: "正在补更早的内容"),
                detail: nil
            )
        }
    }

    private func statusStrip(
        symbol: String,
        tone: StatusTone,
        title: String,
        detail: String?,
        action: (String, () -> Void)? = nil
    ) -> some View {
        HStack(spacing: Token.Spacing.tight) {
            Image(systemName: symbol)
                .foregroundStyle(tone.color)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.footnote.weight(.semibold))
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        // 换行而不是截断：状态条的高度跟着文字长，按钮不会被挤出去。
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Token.Spacing.tight)
            if let action {
                Button(action.0, action: action.1)
                    .font(.footnote)
                    .buttonStyle(.bordered)
                    .fixedSize()
            }
        }
        .padding(.horizontal, Token.Spacing.gutter)
        .padding(.vertical, Token.Spacing.tight)
        .background(.regularMaterial)
        .accessibilityElement(children: .combine)
    }

    private func jumpToLatest(_ proxy: ScrollViewProxy) -> some View {
        Button {
            isFollowingBottom = true
            scrollToBottom(proxy, animated: true)
        } label: {
            Label("跳到最新", systemImage: "arrow.down.circle.fill")
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, Token.Spacing.compact)
                .padding(.vertical, Token.Spacing.tight)
                .background(.regularMaterial, in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(Token.Spacing.gutter)
        .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .bottom)))
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        if reduceMotion || !animated {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        } else {
            withAnimation(.default) { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
        }
    }

    private func scroll(to id: String, proxy: ScrollViewProxy) {
        withAnimation(reduceMotion ? nil : .default) {
            proxy.scrollTo(id, anchor: .center)
        }
        highlightId = id
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            highlightId = nil
        }
    }

    private func permissionMenuTitle(_ session: SessionModel) -> String {
        switch session.currentPermission {
        case "read-only": return String(localized: "权限：仅可查看")
        case "workspace-write": return String(localized: "权限：工作区内修改")
        case "danger-full-access": return String(localized: "权限：完全权限")
        case .some(let other): return String(localized: "权限：\(other)")
        case nil: return String(localized: "权限")
        }
    }

    // MARK: 工具栏

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let session {
                    Button {
                        renameText = session.title
                        showRename = true
                    } label: {
                        Label("重命名", systemImage: "pencil")
                    }
                    Button {
                        UIPasteboard.general.string = session.sessionId
                    } label: {
                        Label("复制会话 ID", systemImage: "doc.on.doc")
                    }
                    Button {
                        showPermissionPicker = true
                    } label: {
                        Label(permissionMenuTitle(session), systemImage: "lock.shield")
                    }
                    Button {
                        showModelPicker = true
                    } label: {
                        Label("切换模型", systemImage: "cpu")
                    }
                    Divider()
                    Button {
                        showFiles = true
                    } label: {
                        Label("工作区文件", systemImage: "folder")
                    }
                    Button {
                        showShadowed.toggle()
                    } label: {
                        Label(showShadowed ? "隐藏被取代的内容" : "显示被取代的内容", systemImage: "arrow.triangle.merge")
                    }
                    Toggle(isOn: Bindable(model.settings).showRawEvents) {
                        Label("显示模型可见的原始事件", systemImage: "curlybraces")
                    }
                    Divider()
                    ShareLink(item: session.exportTranscript()) {
                        Label("分享这轮对话", systemImage: "square.and.arrow.up")
                    }
                }
            } label: {
                Label("会话操作", systemImage: "ellipsis.circle")
            }
        }
    }
}
