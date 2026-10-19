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
    /// 用户**手动**接管了滚动位置（往上拖过）。
    ///
    /// 跟 `isFollowingBottom` 不是一回事，也不能拿它代替：`isFollowingBottom` 是
    /// "末尾哨兵现在在不在视口里"，而内容增长、轮次收拢、LazyVStack 换一批实体化的行
    /// 都会让它短暂变 false —— 拿它当"用户滚走了"用，初始加载时就会误判，
    /// 底部锚点被撤掉，落点停在内容中间（实测）。这个标志只由**真实手势**置位。
    @State private var userTookOverScroll = false
    @State private var lastKnownTailId: String?
    @State private var highlightId: String?
    /// 正在跑的那次"补滚"任务（见 `scrollToBottomTicket` 的 onChange）。
    ///
    /// 存在的理由：长对话冷启动时快照是**分片**折进来的（每 120 条一次
    /// `requestScrollToBottom`），一个 3000 条的会话能连发几十次。每次都起一个
    /// 60ms 后补滚的 Task，它们会一起醒来互相拉扯，落点被甩到内容之外 ——
    /// 用户看到的就是"打开长对话先往下滚、然后一片白"。
    /// 所以补滚**单飞**：新请求直接作废旧的那次，只保留最后一次。
    @State private var settleScrollTask: Task<Void, Never>?
    /// 上一次自动补历史时时间线最老那条的 seq。
    ///
    /// 作用是节流：补齐之后顶部哨兵仍然在视口里，如果只靠 `offset > -120`
    /// 判断，会一页接一页地拉取。只有用户继续上翻、最老那条真的变了，
    /// 才补下一页。
    @State private var lastAutoLoadedSeq: Double?

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
            // 调试用：`defaults write cc.unsplashz.dshpocket DSHShowModelPicker -bool YES`
            if UserDefaults.standard.bool(forKey: "DSHShowModelPicker") { showModelPicker = true }
            if UserDefaults.standard.bool(forKey: "DSHShowPermissionPicker") { showPermissionSheetForDebug = true }
            #endif
            if session == nil {
                let created = SessionModel(
                    sessionId: summary.sessionId,
                    title: summary.title,
                    isRunning: summary.isRunning,
                    isSubagent: summary.category.isSubagent,
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
            // 补滚任务持有 view 的 proxy，视图走了没有再跑的道理（也会白等 60ms）。
            settleScrollTask?.cancel()
            settleScrollTask = nil
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
                    // **加载态不能跟"有没有条目"绑在一起。**
                    //
                    // 以前是 `phase == .loading && items.isEmpty` 才画骨架。
                    // 而真机上最难受的那几秒恰恰是 `phase == .loading` 但
                    // `items` **非空**（缓存恢复出 101 条）：骨架被跳过、内容
                    // 又因为快照还在折/会话流正在重订阅而没渲染出来 ——
                    // 两个分支都不画，屏幕就是纯空白，要等好几秒。
                    //（用户 2026-10-19："手机上又出现点击会话一片空白的情况了，
                    //  等了好几秒才正常"，截图里空白 + 「跳到最新」可见。）
                    //
                    // 现在的判据是"**屏幕上真的有东西可看吗**"：
                    // 还在 loading、而且既没有可渲染的块也没有非隐藏条目 ——
                    // 那才是"什么都没有"的时刻，画骨架。
                    // 有缓存内容时它照常渲染，骨架不插队（不制造跳动）。
                    if session.phase == .loading, !hasConversation(session),
                       session.items.filter({ !$0.isShadowed }).isEmpty {
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
                    if fallbackActive(session) {
                        ForEach(session.items.filter { !$0.isShadowed }) { item in
                            TimelineRow(item: item, session: session)
                                .id(item.id)
                                .padding(.horizontal, Token.Spacing.gutter)
                        }
                    }

                    // **只挂了一串控制 note 的会话，按"空会话"呈现。**
                    //
                    // 真实案例：新会话里只切过一次权限，主机日志里只有
                    // permission/preset、sandbox/mode、approval/policy、model/selection
                    // 这些控制事件，一条对话都没有。把它们逐条画出来（workspace-write、
                    // ask…）配着大片空白，看起来就是"页面坏了"（实测截图）。
                    // 这些 note 是**配置现状**，输入框的权限胶囊和模型标签本来
                    // 就在显示，藏掉不丢信息。
                    if hasConversation(session) {
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
                    }

                    // 排队消息**不在这里** —— 它是输入框上方那块可展开的面板
                    // （见 Composer.queuePanel）。放在时间线末尾会跟"已经聊了什么"混在一起。

                    // 空态跟着**实际渲染的东西**走，不跟 `items` 走 ——
                    // 否则"条目在但一条都渲染不出来"时会变成一片空白。
                    // `!hasConversation` 覆盖"只有控制 note"的情形（见上面的注释）；
                    // 兜底分支正在直接渲染条目时不叠一个空态上去。
                    if !hasConversation(session), !fallbackActive(session),
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
                        // **`onDisappear` 不能把 `isFollowingBottom` 置 false。**
                        //
                        // `LazyVStack` 会**回收**滚出视口的子视图 —— 那个哨兵消失
                        // 只说明"它被回收了"，不说明"用户离开了底部"。可它一旦把
                        // 标志打成 false，就再没有任何东西会把它变回 true
                        // （哨兵已经被回收、不会再 onAppear），于是：
                        //   · 视图不再跟随新内容；
                        //   · 「跳到最新」按钮冒出来；
                        //   · 滚动位置停在内容之外 —— 屏幕一片空白，等好几秒才恢复
                        //（用户 2026-10-19 截图：空白 + 「跳到最新」可见）。
                        //
                        // "用户是不是接管了滚动"由真实手势（`userTookOverScroll`）判断，
                        // 那是唯一可靠的信号；视图回收不是。
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
            // **让系统把内容锚在底部**，而不是靠 `scrollTo` 去"猜"末尾在哪。
            //
            // `scrollTo(bottomAnchor, anchor: .bottom)` 打在 `LazyVStack` 上是不可靠的：
            // 内容高度是按"已实体化的行 + 其余估算"算出来的，`scrollTo` 一动、
            // 实体化的行就换一批、高度估计又变，落点于是越漂越远。实测这个会话上
            // 内容高度在 3155 → 4408 → 3549 → **1272** → 7076 之间来回跳，
            // 最后偏移停在 2829 而内容只剩 1272 —— 落在内容之外，屏幕上**一片空白**。
            //
            // 交给系统锚点就没有这个问题：初始位置由系统按锚点定，不依赖任何"估算末尾"。
            .modifier(BottomScrollAnchor(followsContentChanges: !userTookOverScroll))
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
            // 用户真的用手拖过时间线 = 他接管了滚动位置。
            // 用 `simultaneousGesture` 而不是 `gesture`：不抢 ScrollView 自己的
            // 拖动，只是顺带记一笔。`minimumDistance` 是为了别把点击也算成拖动。
            .simultaneousGesture(
                DragGesture(minimumDistance: 12).onChanged { _ in
                    if !userTookOverScroll { userTookOverScroll = true }
                }
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
                //
                // **单飞**：分片折叠会连发几十次 ticket，原先每次都起一个 Task，
                // 它们同时醒来会互相拉扯，把落点推到内容之外（"打开长对话先往下滚、
                // 然后一片空白"）。这里先作废旧的那次，只保留最新一次的补滚。
                settleScrollTask?.cancel()
                settleScrollTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(60))
                    guard !Task.isCancelled, isFollowingBottom else { return }
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
            // 补完历史：滚到**新进来的那一块**（`TimelineBlock.id`）。
            // 不做这一步的话，新内容全插在视口上方，屏幕上毫无变化 ——
            // 用户会以为"点了没反应"（实测就是）。
            // 目标给的是**块**而不是条目：新进来的第一条常常已经被收进一个收拢的
            // 轮次里，条目自己的 `.id` 那时不在视图里，`scrollTo` 会静默失效。
            .onChange(of: session.historyScrollTicket) { _, _ in
                guard let target = session.historyScrollTarget else { return }
                // 补历史时用户本来就在往上翻，所以**不要**恢复贴底。
                isFollowingBottom = false
                // 这次是我们主动把视图挪走的（不是跟着内容走），底部锚点得让开，
                // 否则系统锚点会和这次 `scrollTo` 互相拉扯。
                userTookOverScroll = true
                withAnimation(.default) { proxy.scrollTo(target, anchor: .top) }
            }
            .task {
                #if DEBUG
                // 调试用：`defaults write cc.unsplashz.dshpocket DSHLoadEarlier -bool YES`
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
                // **必须是用户自己滑上去的**（`userTookOverScroll`），
                // 而不是"刚进会话、内容还短、哨兵恰好露头"。
                guard userTookOverScroll else { return }
                guard offset > -120 else { return }
                // **补过一页就别接着补**：补齐后哨兵仍在视口里，不加这道闸
                // 会一页接一页地拉，用户往上翻的时候内容一直在变。
                // 等用户继续上翻（`lastAutoLoadedSeq` 变化）再补下一页。
                guard session.items.first?.seq != lastAutoLoadedSeq else { return }
                // 静默补齐：不改变滚动位置，用户接着往上翻就是了。
                // **补完再记**：补进来之后最老那条会变小，记成"补完之后的值"
                // 才能挡住"同一条边界反复触发"。
                Task {
                    await session.loadOlderHistoryIfNeeded()
                    lastAutoLoadedSeq = session.items.first?.seq
                }
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
                        Text(String(repeating: String(localized: "正在读取这条会话的内容 "), count: 2))
                            .font(.body)
                        Text(String(repeating: String(localized: "从电脑上把历史取回来 "), count: 3))
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

    /// 时间线里有没有"真内容"（轮次或消息）—— 只有控制 note 的会话按空会话呈现。
    /// 判定本身在 DSHKit（`[TimelineBlock].hasConversation`），那里有单测。
    private func hasConversation(_ session: SessionModel) -> Bool {
        session.timelineBlocks.hasConversation
    }

    /// 兜底分支（分组为空但条目还在时直接渲染条目）此刻有没有生效。
    private func fallbackActive(_ session: SessionModel) -> Bool {
        session.timelineBlocks.isEmpty && !session.items.filter({ !$0.isShadowed }).isEmpty
    }

    private func historyLoader(_ session: SessionModel) -> some View {
        HStack {
            Spacer()
            if session.isLoadingHistory {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    // 用户明确要看更早的东西 —— 补完把这页的开头滚进视野。
                    Task { await session.loadOlderHistoryIfNeeded(revealInserted: true) }
                } label: {
                    Label("载入更早的内容", systemImage: "arrow.up.circle")
                }
                .buttonStyle(.bordered)
            }
            Spacer()
        }
        .padding(.vertical, Token.Spacing.tight)
        // **不要 `.onAppear { loadOlderHistoryIfNeeded() }`。**
        //
        // 这个加载器在时间线**最顶部**，进会话时内容较短，它本来就落在视口里 ——
        // 于是"打开会话"这个动作会立刻触发补历史，把更早的内容插到上方、
        // 再把视图拽过去，同时底部的贴底逻辑还在往下拉。用户看到的就是
        // "一边往上滚补历史、一边往下滚去最新消息"（真机反馈）。
        // 自动补齐改由"用户真的滑到顶部"那条 `onPreferenceChange` 触发。
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
            // 交还控制权：底部锚点重新生效，之后内容增长继续跟着走。
            userTookOverScroll = false
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
                    // 「显示模型可见的原始事件」**不在这里** —— 设置页 → 外观里
                    // 已经有同一个开关（`settings.showRawEvents`），会话菜单里再放一份
                    // 属于重复入口，还占着常用操作的位置。
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


/// 时间线的**底部锚点**。
///
/// 背景：打开一个积压了很多轮的会话时，时间线经常是**一片空白**，只剩一个
/// 「跳到最新」。根因不在数据，而在"把内容滚到底"这件事上 ——
/// `scrollTo(bottomAnchor, anchor: .bottom)` 打在 `LazyVStack` 上是不可靠的：
/// 内容高度是按"已实体化的行 + 其余估算"算的，`scrollTo` 一动，实体化的行换一批、
/// 高度估算又变，落点于是越漂越远。实测这个会话上内容高度在
/// `3155 → 4408 → 3549 → 1272 → 7076` 之间来回跳，偏移最后停在内容之外；
/// 更糟的是视口里那一批行**根本没被实体化**，所以是纯空白。
///
/// 交给系统的底部锚点就没有这个问题：初始位置由系统按锚点定，不依赖任何"估算末尾"。
///
/// 两个角色要分开设（iOS 18 才有 `defaultScrollAnchor(_:for:)`）：
///   · `initialOffset` **永远贴底** —— 修掉上面那个空白；
///   · `sizeChanges` **只在用户没手动接管滚动时开**。不能无条件开：用户往上翻历史
///     时模型还在输出，系统锚点会把正在看历史的用户拽回底部，还会跟"补完历史滚到
///     新内容"那次 `scrollTo` 互相拉扯（实测：正在跑的会话上必现空白）。
///
///     **这个开关不能拿 `isFollowingBottom` 当**：它表示"末尾哨兵此刻在不在视口里"，
///     内容增长/轮次收拢/换一批实体化的行都会让它短暂变 false。用它做判断，
///     初始加载就会被误判成"用户滚走了"、锚点被撤掉，落点停在内容中间（实测）。
///     所以单独用只由真实手势置位的 `userTookOverScroll`。
///
/// iOS 17 拿不到拆开的角色，退回整锚点 —— 仍然是"打开不空白"，代价是上面那条
/// 边界场景退化成"内容增长时可能被拽回底部"。本项目的部署下限是 17.5，
/// 但真机与模拟器都在 26/27，所以实际跑的是拆分版。
private struct BottomScrollAnchor: ViewModifier {
    /// 内容尺寸变化时要不要继续贴底。**只在用户没手动接管滚动时为真**。
    let followsContentChanges: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(followsContentChanges ? .bottom : nil, for: .sizeChanges)
        } else {
            content.defaultScrollAnchor(.bottom)
        }
    }
}
