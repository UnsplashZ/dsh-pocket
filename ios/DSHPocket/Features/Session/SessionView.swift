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
    @State private var showPermissionSheetForDebug = false
    @State private var canAutoLoadHistory = false
    @State private var showJobs = false
    @State private var showGoal = false
    @State private var showShadowed = false
    @FocusState private var composerFocused: Bool
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
            if UserDefaults.standard.bool(forKey: "DSHShowPermissionPicker") { showPermissionSheetForDebug = true }
            #endif
            if session == nil {
                let created = SessionModel(
                    sessionId: summary.sessionId,
                    title: summary.title,
                    isRunning: summary.isRunning,
                    appModel: model
                )
                session = created
                await created.open()
                #if DEBUG
                // 调试用：预填输入框，好核对 `/` 命令菜单和 `@` 引用条。
                // 模拟器里打不了字，只能这样看。**必须在 open 之后** ——
                // open 会重置草稿。
                if let seed = UserDefaults.standard.string(forKey: "DSHSeedDraft"), !seed.isEmpty {
                    created.draft = seed
                    UserDefaults.standard.removeObject(forKey: "DSHSeedDraft")
                }
                #endif
            }
        }
        .onAppear { model.activeSessionId = summary.sessionId }
        .onDisappear {
            if model.activeSessionId == summary.sessionId { model.activeSessionId = nil }
            session?.close()
        }
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
        .popover(isPresented: $showPermissionPicker) {
            if let session {
                PermissionPopover(session: session)
                    // iPhone 上默认会摊成 sheet，显式要求真正的 popover。
                    .presentationCompactAdaptation(.popover)
            }
        }
        .sheet(isPresented: $showJobs) {
            if let session { JobsSheet(session: session) }
        }
        .sheet(isPresented: $showGoal) {
            if let session { GoalSheet(session: session) }
        }
        #if DEBUG
        // 调试用：`.task` 里设状态**弹不出 popover**（它需要锚点已经布局好），
        // 所以另开一个 sheet 路径，只为了核对内容渲染。
        .sheet(isPresented: $showPermissionSheetForDebug) {
            if let session {
                NavigationStack {
                    VStack {
                        PermissionPopover(session: session)
                        Spacer()
                    }
                    .navigationTitle("权限")
                    .navigationBarTitleDisplayMode(.inline)
                }
                .presentationDetents([.medium])
            }
        }
        #endif
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
                        // 顶部哨兵：**往上滑到顶就自动补**，不用非得点按钮。
                        // 用 GeometryReader 报坐标（iOS 17 兼容），
                        // 不用 `onScrollGeometryChange`（那是 iOS 18+）。
                        Color.clear
                            .frame(height: 1)
                            .background(
                                GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: TimelineTopOffsetKey.self,
                                        value: geometry.frame(in: .named(Self.timelineSpace)).minY
                                    )
                                }
                            )

                        historyLoader(session)
                    }

                    if showShadowed, !session.shadowedItems.isEmpty {
                        shadowedSection(session)
                    }

                    // **兜底：分组为空但条目还在，就直接渲染条目。**
                    // 正常情况下走不到这里；但真走到了，宁可排版差一点，
                    // 也不能给用户一片空白（实测重连时偶尔出现）。
                    if session.timelineBlocks.isEmpty, !session.items.filter({ !$0.isShadowed }).isEmpty {
                        ForEach(session.items.filter { !$0.isShadowed }) { item in
                            TimelineRow(item: item, session: session)
                                .id(item.id)
                                .padding(.horizontal, Token.Spacing.gutter)
                        }
                    }

                    // 按轮次分组渲染：跑完的轮次收拢成一行摘要 + 最终结论。
                    ForEach(session.timelineBlocks) { block in
                        switch block {
                        case .turn(let turn):
                            TurnGroupView(turn: turn, session: session)
                        case .item(let item):
                            TimelineRow(item: item, session: session)
                                .id(item.id)
                                .padding(.horizontal, Token.Spacing.gutter)
                                .background(
                                    RoundedRectangle(cornerRadius: Token.Radius.card, style: .continuous)
                                        .fill(highlightId == item.id ? Color.accentColor.opacity(0.12) : .clear)
                                )
                        }
                    }

                    // 排队消息**不在这里** —— 它是输入框上方那块可展开的面板
                    // （见 Composer.queuePanel）。放在时间线末尾会跟"已经聊了什么"混在一起。

                    // 空态跟着**实际渲染的东西**走，不跟 `items` 走 ——
                    // 否则"条目在但一条都渲染不出来"时会变成一片空白。
                    if session.timelineBlocks.isEmpty,
                       session.items.filter({ !$0.isShadowed }).isEmpty,
                       session.phase != .loading {
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
                // **不要**在这里开 `.textSelection(.enabled)`。
                // 它会给每个文本挂上选择手势，长列表滚动时是实打实的开销。
                // 需要复制的地方各自开：代码块有复制按钮，审批参数与展开的
                // 推理内容各自带了 `.textSelection(.enabled)`。
            }
            // **`.immediately`，不是 `.interactively`。**
            // `.interactively` 只在"往下拖"（往回翻旧消息）时跟着手势收键盘，
            // 往上滑看新消息时纹丝不动 —— 而手机上键盘一占就是小半屏，
            // 想腾地方的人恰恰是在往上滑。改成一开始滚动就收。
            .scrollDismissesKeyboard(.immediately)
            // 点消息区也收键盘。
            //
            // `.scrollDismissesKeyboard` 只在**真的滚动**时生效 —— 内容不够长、
            // 或者已经贴底时滑不动，键盘就赖着不走。而手机上它一占就是小半屏，
            // 用户只是想看看内容却腾不出地方。
            //
            // **必须挂在 `ScrollView` 自己身上**（也就是两个 `safeAreaInset` 之前）：
            // 挂到后面会连输入框一起覆盖，点一下输入框立刻失焦，根本没法打字。
            // 用 `simultaneousGesture` 而不是 `gesture`：不抢子视图的手势，
            // 点工具行、点展开都照常工作，只是顺手把键盘收了。
            .simultaneousGesture(
                TapGesture().onEnded { composerFocused = false }
            )
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
                Composer(
                    onRequestModelPicker: { showModelPicker = true },
                    session: session,
                    isFocused: $composerFocused
                )
            }
            .onChange(of: session.items.last?.id) { _, newValue in
                guard isFollowingBottom, let newValue else { return }
                lastKnownTailId = newValue
                // **跟随底部不加动画。**
                // 内容是连续长出来的，每次都起一段 `.default` 动画会互相叠加，
                // 手感变成一顿一顿的；而且动画期间又来一次更新，滚动位置会打架。
                // 动画只留给"跳转"这类离散动作（跳到最新、补历史）。
                scrollToBottom(proxy, animated: false)
            }
            // 模型显式要求"滚到底"（快照分完、自己发了消息）。
            .onChange(of: session.scrollToBottomTicket) { _, _ in
                isFollowingBottom = true
                scrollToBottom(proxy, animated: false)
                // **再补一次。** `LazyVStack` 是惰性的：第一次 `scrollTo` 时
                // 下面几屏还没布局出来，落点会偏短，看起来像"停在半路"——
                // 点进一个积压了很多新消息的会话时最明显。
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(60))
                    guard isFollowingBottom else { return }
                    scrollToBottom(proxy, animated: false)
                }
            }
            // 键盘弹出会把输入区顶上去、视口矮一截 —— 不重新贴底的话，
            // 最新内容会被挡在键盘后面（用户："看不到最新的内容"）。
            .onChange(of: composerFocused) { _, focused in
                guard focused else { return }
                isFollowingBottom = true
                // 立刻滚一次，再等键盘动画落定后补一次 ——
                // 键盘高度是动画出来的，只滚一次会停在半路。
                scrollToBottom(proxy, animated: false)
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(280))
                    guard composerFocused, isFollowingBottom else { return }
                    scrollToBottom(proxy, animated: true)
                }
            }
            // 轮次跑完 → 过程消息收起 → 内容骤减。
            // 不重新贴底的话滚动位置会落到内容之外（一片空白）；
            // 顺带这也是用户要的"触发折叠时自动滚动收缩"。
            .onChange(of: session.completedTurns.count) { old, new in
                guard new > old, isFollowingBottom else { return }
                Task { @MainActor in
                    // 等折叠动画落定再滚，否则滚的是旧布局。
                    try? await Task.sleep(for: .milliseconds(120))
                    guard isFollowingBottom else { return }
                    scrollToBottom(proxy, animated: true)
                }
            }
            .onChange(of: model.focusedApprovalId) { _, newValue in
                guard let newValue else { return }
                scroll(to: newValue, proxy: proxy)
            }
            // 补完历史：滚到**新进来的第一条**。
            // 不做这一步的话，新内容全插在视口上方，屏幕上毫无变化 ——
            // 用户会以为"点了没反应"（实测就是）。
            .onChange(of: session.historyScrollTicket) { _, _ in
                guard let target = session.historyScrollTarget else { return }
                // 补历史时用户本来就在往上翻，所以**不要**恢复贴底。
                isFollowingBottom = false
                withAnimation(.default) { proxy.scrollTo(target, anchor: .top) }
            }
            .task {
                #if DEBUG
                // 调试用：`defaults write cc.zexa.dshpocket DSHLoadEarlier -bool YES`
                // 打开后延迟几秒自动补一页历史，便于核对"补完会不会滚到新内容"。
                if UserDefaults.standard.bool(forKey: "DSHLoadEarlier") {
                    try? await Task.sleep(for: .seconds(6))
                    await session.loadOlderHistoryIfNeeded()
                }
                #endif
            }
            .coordinateSpace(name: Self.timelineSpace)
            .onPreferenceChange(TimelineTopOffsetKey.self) { offset in
                // **打开会话时不要自动补历史。**
                //
                // 刚进来时内容还短（或还没贴到底），哨兵本来就在视口里 ——
                // 一触发就补，更早的内容插到**上方**，视图一下子跳到中间某条消息
                //（用户录屏："一开始在最底部，然后会突然跳转到某条消息记录"）。
                //
                // 等首次贴底落定之后才允许自动补。
                guard canAutoLoadHistory else { return }
                guard offset > -120 else { return }
                Task { await session.loadOlderHistoryIfNeeded() }
            }
            .task {
                // 给首次布局 + 贴底留出时间，之后才开放"往上滑自动补"。
                try? await Task.sleep(for: .milliseconds(1200))
                canAutoLoadHistory = true
            }
        }
    }

    /// 滚动坐标空间的名字（顶部哨兵用它算自己在视口里的位置）。
    private static let timelineSpace = "dsh-timeline"

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
        // **先滚到最后一块内容的 id**，再补一次末尾哨兵。
        //
        // 只滚哨兵会"经常失效"（用户反馈）：LazyVStack 里末尾那个零高度的
        // `Color.clear` 常常还没被实体化，`scrollTo` 就静默什么也不做。
        // 有真实内容的那一块才是稳的锚点。
        let last = session?.timelineBlocks.last?.id
        let apply = {
            if let last { proxy.scrollTo(last, anchor: .bottom) }
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        }
        if reduceMotion || !animated {
            apply()
        } else {
            withAnimation(.default) { apply() }
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
                        showModelPicker = true
                    } label: {
                        Label("切换模型", systemImage: "cpu")
                    }
                    Divider()
                    Button {
                        showFiles = true
                    } label: {
                        Button {
                            showJobs = true
                        } label: {
                            Label(
                                session.jobs.contains(where: \.isRunning)
                                    ? String(format: String(localized: "后台任务（%lld 个运行中）"), session.jobs.filter(\.isRunning).count)
                                    : "后台任务",
                                systemImage: "clock.arrow.circlepath"
                            )
                        }
                        Button {
                            showGoal = true
                        } label: {
                            Label(
                                session.goal?.isActive == true ? "目标（进行中）" : "目标",
                                systemImage: "target"
                            )
                        }
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


/// 时间线顶部哨兵在视口里的位置。用来做"上滑到底自动补历史"。
private struct TimelineTopOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}
