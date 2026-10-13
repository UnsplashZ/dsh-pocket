import DSHKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// S3 输入区。
///
/// 布局：`.safeAreaInset(edge: .bottom)`；1–6 行自适应；圆角容器 + `.thinMaterial`。
/// 主按钮**同一位置的形态切换**：空闲=发送，运行中=停止（不要并排两个按钮）。
/// 输入区左右两端的圆形按钮。
///
/// **两个都由这一个构造产出**。之前是各写各的：`+` 是 20pt 字形配 44pt 圆底，
/// 发送是 30pt 的 `arrow.up.circle.fill`（符号自带圆）—— 圆的直径和字形占比都不一样，
/// 并排看就是"图标大小不一致"。
struct CircleGlyph: View {
    enum Style {
        /// 次要动作（附件）：浅底 + 次级前景。
        case quiet
        /// 主操作（发送）：实心强调色 + 白字形。
        case prominent
        /// 危险动作（停止）：实心红 + 白字形。
        case destructive
    }

    let systemImage: String
    var style: Style = .quiet

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: Token.Control.glyph, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: Token.Control.diameter, height: Token.Control.diameter)
            .background(Circle().fill(background))
            // 圆是 36pt，但点击区要够 44pt（HIG）。用透明的外框补齐，
            // 而不是把圆本身放大 —— 视觉尺寸和点击尺寸是两件事。
            .frame(width: Token.minimumHitTarget, height: Token.minimumHitTarget)
            .contentShape(Circle())
    }

    private var foreground: Color {
        switch style {
        case .quiet: return Color.secondary
        case .prominent, .destructive: return .white
        }
    }

    private var background: Color {
        switch style {
        case .quiet: return Color(.tertiarySystemFill)
        case .prominent: return .accentColor
        case .destructive: return .red
        }
    }
}

struct Composer: View {
    @Bindable var session: SessionModel

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// 焦点由上层持有 —— 这样"点消息区收键盘"才能从外面关掉它。
    var isFocused: FocusState<Bool>.Binding
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showPermissionPicker = false
    /// 排队面板默认**展开** —— 它出现在屏幕上就说明"有东西在等"，
    /// 这时候收起只会让人多点一下。
    @State private var isQueueExpanded = true
    @State private var isTodoExpanded = false
    @State private var referenceFiles: [FileReferenceCandidate] = []
    @State private var referenceSessions: [SessionReferenceCandidate] = []
    @State private var referenceTask: Task<Void, Never>?
    @State private var showContextBreakdown = false
    @State private var editingQueueItem: QueuedMessage?
    @State private var queueEditText = ""
    @State private var showFileImporter = false
    @State private var sendTrigger = 0
    @State private var stopTrigger = 0

    private var isRunning: Bool { session.isTurnRunning }

    var body: some View {
        VStack(spacing: 0) {
            if !session.attachments.isEmpty {
                attachmentStrip
            }

            // **电脑在不在干活**：一个脉冲点 + 实时计时器。
            workingIndicator

            // `/` 命令 与 `@` 引用：都做成输入框上方的候选条。
            suggestions

            // 待办在**输入框和排队消息上方**（照桌面端的排布）。
            // 它回答的是"现在进行到哪了"，放在时间线里会被滚走。
            todoPanel

            // 排队消息是**输入框上方一块可展开的记录**，不是摊在时间线末尾。
            // 桌面端就是这样：它属于"我准备发什么"，不属于"已经聊了什么"。
            queuePanel

            // 布局照桌面端：**输入框占整行**，下面一行放工具
            //（附件 / 权限 / 上下文占用 / 发送），再下面一行是会话统计。
            VStack(spacing: Token.Spacing.tight) {
                TextField(placeholder, text: $session.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused(isFocused)
                    .submitLabel(.send)
                    .onSubmit { send() }
                    // 去掉外层卡片之后，输入框要自己有底 —— 否则文字直接贴在 bar 上。
                    .padding(.horizontal, Token.Spacing.compact)
                    .padding(.vertical, Token.Spacing.tight)
                    .background(
                        RoundedRectangle(cornerRadius: Token.Radius.bubble, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )
                    .accessibilityLabel(Text("消息"))

                HStack(spacing: Token.Spacing.tight) {
                    Menu {
                        // `PhotosPicker` **不能放在 `Menu` 里** —— 菜单一关，它自己那层
                        // 呈现就被丢掉了，点了完全没反应（实测）。所以菜单里只置一个标志，
                        // 真正的 picker 用 `.photosPicker(isPresented:)` 挂在外面。
                        Button {
                            showPhotoPicker = true
                        } label: {
                            Label("照片", systemImage: "photo.on.rectangle")
                        }
                        Button {
                            showFileImporter = true
                        } label: {
                            Label("文件", systemImage: "doc")
                        }
                    } label: {
                        CircleGlyph(systemImage: "plus", style: .quiet)
                    }
                    .accessibilityLabel(Text("添加附件"))

                    permissionButton

                    Spacer(minLength: Token.Spacing.hairline)

                    // 跑着的时候**不显示**上下文条：那一行已经有三个动作按钮，
                    // 再塞一根进度条会把权限胶囊和百分比都挤到截断（实测）。
                    // 百分比挪到下面的统计行里，信息不丢。
                    if !isRunning {
                        contextBar
                    }

                    actionButtons
                }
            }
            // **不要卡片底色。** 加了权限/上下文/统计之后，卡片只占中间一块，
            // 四周露出 bar 材质，看起来就是"颜色不连贯"（用户反馈）。
            // 输入区本来就是一条完整的 bar 表面，保持它 ——
            // 输入框自己那层浅底已经够区分了。
            .padding(.horizontal, Token.Spacing.gutter)
            .padding(.vertical, Token.Spacing.tight)

            statsLine
        }
        // 编辑排队消息：用一个带输入框的 alert，不另开一页。
        .alert("编辑排队消息", isPresented: Binding(
            get: { editingQueueItem != nil },
            set: { if !$0 { editingQueueItem = nil } }
        )) {
            TextField("内容", text: $queueEditText, axis: .vertical)
            Button("保存") {
                if let item = editingQueueItem {
                    let text = queueEditText
                    Task { await session.updateQueue(itemId: item.id, action: .edit(text)) }
                }
                editingQueueItem = nil
            }
            Button("取消", role: .cancel) { editingQueueItem = nil }
        }
        .popover(isPresented: $showContextBreakdown) {
            if let breakdown = session.contextBreakdown {
                ContextBreakdownView(breakdown: breakdown, pressure: session.contextPressure)
                    .presentationCompactAdaptation(.popover)
            }
        }
        .popover(isPresented: $showPermissionPicker) {
            // 三个选项 + 一个勾，用不着一整页 sheet。
            PermissionPopover(session: session)
                .presentationCompactAdaptation(.popover)
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $photoSelection,
            maxSelectionCount: 6,
            matching: .images,
            photoLibrary: .shared()
        )
        // 背景要**铺到屏幕底边**（含 home indicator 那一条），否则输入区下面会露出
        // 一条与滚动区不同的底色，看起来像"多出来一条白边"。
        .background {
            Rectangle()
                .fill(.bar)
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: sendTrigger)
        .sensoryFeedback(.impact(weight: .medium), trigger: stopTrigger)
        .onChange(of: session.draft) { _, _ in
            refreshReferences()
        }
        // **有新东西进队列就自动展开** —— 否则用户手动收过一次之后，
        // 后面排队的消息只会悄悄加个数字，很容易漏掉。
        .onChange(of: session.queuedMessages.count) { old, new in
            if new > old { isQueueExpanded = true }
        }
        .onChange(of: photoSelection) { _, items in
            Task { await loadPhotos(items) }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item, .text, .image, .pdf, .sourceCode],
            allowsMultipleSelection: true
        ) { result in
            Task { await loadFiles(result) }
        }
        // 硬件键盘：⌘↩ 发送。
        //
        // 之前这里用的是 `ToolbarItemGroup(placement: .keyboard)`，结果是键盘上方
        // 浮出「附件」「发送」两个大胶囊 —— 而输入区本身就在键盘正上方、
        // 同样的动作已经有一份了，纯属重复；键盘收起时那条 accessory 还会留下
        // 一条白边。改成直接收按键，不再往键盘上挂任何东西。
        .onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            isRunning ? stop() : send()
            return .handled
        }
    }

    /// 发送区右侧的按钮。
    ///
    /// 抽出来是为了**压住类型检查的复杂度** —— 这些按钮加上权限胶囊、
    /// 上下文条全塞在一个 `HStack` 里时，编译器会直接放弃
    /// （`unable to type-check this expression in reasonable time`）。
    @ViewBuilder
    private var actionButtons: some View {
        // **一个主按钮**，按状态变：
        //   闲置 + 没文本 → 灰色发送（点不动）
        //   闲置 + 有文本 → 实色发送
        //   跑着 + 没文本 → **红色停止**
        //   跑着 + 有文本 → 实色发送（实际是排队）
        // 插队单独一个小按钮，只在真能插的时候出现。
        if isRunning, !canSend {
            stopButton
        } else {
            sendButton
        }
        if isRunning, canSend || !session.queuedMessages.isEmpty {
            steerButton
        }
    }

    /// 主按钮：跑着且没文本时是停止，其余是发送。
    private var isStopMode: Bool { isRunning && !canSend }

    /// 插队：有草稿就插草稿，没草稿就插**队列里的第一条**。
    ///
    /// 用户："排队的会话，通过一个简单的交互按钮可以插话发送"。
    private var steerButton: some View {
        Button {
            Task {
                if canSend {
                    await session.send(mode: .steer)
                } else if let first = session.queuedMessages.first {
                    await session.updateQueue(itemId: first.id, action: .steer)
                }
            }
        } label: {
            CircleGlyph(systemImage: "bolt.fill", style: .quiet)
        }
        .accessibilityLabel(Text("立刻插队"))
        .accessibilityHint(Text(canSend ? "把输入框里的内容插进正在跑的这一轮" : "把排队里的第一条插进正在跑的这一轮"))
    }

    private var stopButton: some View {
        Button(action: stop) {
            CircleGlyph(systemImage: "stop.fill", style: .destructive)
        }
        .accessibilityLabel(Text("停止"))
        .accessibilityHint(Text("打断正在跑的这一轮"))
    }

    private var sendButton: some View {
        Button { Task { await session.send(mode: .queue) } } label: {
            CircleGlyph(systemImage: "arrow.up", style: .prominent)
        }
        .disabled(!canSend)
        .opacity(canSend ? 1 : 0.4)
        .accessibilityLabel(Text(isRunning ? "排队发送" : "发送"))
        .accessibilityHint(Text(isRunning ? "等这一轮跑完再发出去" : "把消息发给电脑"))
    }

    /// 输入框的占位文案 —— **照 desktop 的说法**。
    ///
    /// desktop 的 `placeholder.default` 是「发消息或创建任务」，
    /// 计划模式是「描述你的任务以生成计划」。之前我们自己编的
    /// 「给电脑说点什么…」跟桌面端对不上（用户："有点奇怪"）。
    private var placeholder: LocalizedStringKey {
        // 计划模式下 desktop 会换成另一句（`placeholder.plan`）。
        // 这里先只做默认那句 —— 计划模式的开关状态还没接进来。
        "发消息或创建任务"
    }

    // MARK: 工作状态

    /// **电脑到底在不在干活。**
    ///
    /// 用户："工作中状态缺少提示，除了右下角终止按钮，别的地方看不出来
    /// 是在工作还是停止了。最好像 desktop 一样有一个实时的计时器。"
    ///
    /// 用 `TimelineView` 每秒重绘**这一行** —— 不引入 model 层的 ticker，
    /// 也就不会每秒把整棵时间线刷一遍。
    @ViewBuilder
    private var workingIndicator: some View {
        if session.isTurnRunning, let startedAt = session.turnStartedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = max(0, context.date.timeIntervalSince(startedAt))
                HStack(spacing: Token.Spacing.tight) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                        .opacity(0.35 + 0.65 * abs(sin(elapsed * .pi / 1.6)))
                    Text(session.isStreaming ? "正在生成" : "工作中")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(Self.elapsedText(elapsed))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Token.Spacing.gutter)
                .padding(.top, Token.Spacing.tight)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(String(
                    format: String(localized: "工作中，已用时 %@"),
                    Self.elapsedText(elapsed)
                )))
            }
        }
    }

    /// `1 分 23 秒` / `12 秒` —— 跟 desktop 的说法一致。
    static func elapsedText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        if total < 60 { return String(format: String(localized: "%lld 秒"), total) }
        let minutes = total / 60
        let rest = total % 60
        return String(format: String(localized: "%lld 分 %lld 秒"), minutes, rest)
    }

    // MARK: `/` 命令 与 `@` 引用

    /// 输入框里正在打的 `/命令` 或 `@引用`。
    ///
    /// 只在**最后一个词**上触发：`/` 必须出现在开头（`@` 可以出现在任何位置，
    /// 因为引用常常夹在句子里）。
    private var trigger: (kind: TriggerKind, query: String)? {
        let text = session.draft
        if text.hasPrefix("/"), !text.contains(" ") {
            return (.command, String(text.dropFirst()))
        }
        guard let at = text.lastIndex(of: "@") else { return nil }
        let tail = text[text.index(after: at)...]
        guard !tail.contains(" "), !tail.contains("\n") else { return nil }
        return (.reference, String(tail))
    }

    private enum TriggerKind { case command, reference }

    @ViewBuilder
    private var suggestions: some View {
        if let trigger {
            let commands = trigger.kind == .command
                ? session.commands.filter {
                    trigger.query.isEmpty
                        || $0.name.localizedCaseInsensitiveContains(trigger.query)
                        || $0.summary.localizedCaseInsensitiveContains(trigger.query)
                }
                : []
            let files = trigger.kind == .reference ? referenceFiles : []
            let sessions = trigger.kind == .reference ? referenceSessions : []

            if !commands.isEmpty || !files.isEmpty || !sessions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Token.Spacing.tight) {
                        ForEach(commands) { command in
                            suggestionChip(
                                title: "/" + command.name,
                                subtitle: command.summary,
                                symbol: "command"
                            ) {
                                // 不带参数的命令**直接跑**，带参数的填进输入框。
                                if command.takesInput {
                                    session.draft = "/" + command.name + " "
                                } else {
                                    Task { await session.runCommand(command) }
                                }
                            }
                        }
                        ForEach(files.prefix(12)) { file in
                            suggestionChip(
                                title: file.path,
                                subtitle: file.isDirectory ? String(localized: "目录") : nil,
                                symbol: file.isDirectory ? "folder" : "doc"
                            ) {
                                insertReference(file.path)
                            }
                        }
                        ForEach(sessions.prefix(6)) { candidate in
                            suggestionChip(
                                title: candidate.display,
                                subtitle: candidate.sameWorkspace ? String(localized: "同一工作区") : nil,
                                symbol: "bubble.left.and.text.bubble.right"
                            ) {
                                insertReference(candidate.sessionId)
                            }
                        }
                    }
                    .padding(.horizontal, Token.Spacing.gutter)
                    .padding(.vertical, Token.Spacing.tight)
                }
                .background(.bar)
                .overlay(alignment: .top) { Rectangle().fill(Color(.separator)).frame(height: 0.5) }
            }
        }
    }

    private func suggestionChip(
        title: String,
        subtitle: String?,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Token.Spacing.hairline) {
                Image(systemName: symbol).font(.caption2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, Token.Spacing.tight)
            .padding(.vertical, Token.Spacing.hairline)
            .background(Color(.tertiarySystemFill), in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }

    /// 把 `@` 换成引用。
    private func insertReference(_ value: String) {
        var text = session.draft
        if let at = text.lastIndex(of: "@") {
            text = String(text[..<at])
        }
        session.draft = text + "@" + value + " "
        referenceFiles = []
        referenceSessions = []
    }

    // MARK: 待办

    /// 当前待办。
    ///
    /// 用户："任务待办应该参考 desktop，在对话框和排队消息上方展示。"
    /// 放在时间线里会被滚走 —— 而它恰恰是"现在进行到哪了"的答案。
    @ViewBuilder
    private var todoPanel: some View {
        let entries = session.todos
        if !entries.isEmpty {
            let done = entries.filter { $0.status == .completed }.count
            VStack(spacing: 0) {
                Button {
                    withAnimation(.snappy) { isTodoExpanded.toggle() }
                } label: {
                    HStack(spacing: Token.Spacing.tight) {
                        Image(systemName: "checklist")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(String(format: String(localized: "待办 %lld/%lld"), done, entries.count))
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        // 进行中的那条**收起时也要看得见** —— 那是最该知道的一条。
                        if let active = entries.first(where: { $0.status == .inProgress }) {
                            Text(active.text)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        Image(systemName: isTodoExpanded ? "chevron.down" : "chevron.up")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, Token.Spacing.gutter)
                    .frame(height: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(String(format: String(localized: "待办 %lld/%lld"), done, entries.count)))

                if isTodoExpanded {
                    Divider().padding(.leading, Token.Spacing.gutter)
                    ForEach(entries) { entry in
                        HStack(alignment: .top, spacing: Token.Spacing.tight) {
                            Image(systemName: symbol(for: entry.status))
                                .font(.caption2)
                                .foregroundStyle(tint(for: entry.status))
                                .frame(width: 16)
                            Text(entry.text)
                                .font(.footnote)
                                .foregroundStyle(entry.status == .completed ? .secondary : .primary)
                                .strikethrough(entry.status == .completed)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Token.Spacing.gutter)
                        .padding(.vertical, 3)
                    }
                }
            }
            .background(.bar)
            .overlay(alignment: .top) { Rectangle().fill(Color(.separator)).frame(height: 0.5) }
            .overlay(alignment: .bottom) { Rectangle().fill(Color(.separator)).frame(height: 0.5) }
        }
    }

    private func symbol(for status: TimelineItem.TodoEntry.Status) -> String {
        switch status {
        case .completed: return "checkmark.circle.fill"
        case .inProgress: return "circle.dotted"
        case .pending: return "circle"
        }
    }

    private func tint(for status: TimelineItem.TodoEntry.Status) -> Color {
        switch status {
        case .completed: return .secondary
        case .inProgress: return .accentColor
        // `Color.tertiary` 不是 `Color`（它是 `some ShapeStyle`），用具体的灰。
        case .pending: return Color(.tertiaryLabel)
        }
    }

    // MARK: 排队消息

    @ViewBuilder
    private var queuePanel: some View {
        if !session.queuedMessages.isEmpty {
            VStack(spacing: 0) {
                Button {
                    withAnimation(.snappy) { isQueueExpanded.toggle() }
                } label: {
                    HStack(spacing: Token.Spacing.tight) {
                        Image(systemName: "text.badge.minus")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(String(format: String(localized: "%lld 条排队消息"), session.queuedMessages.count))
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        // **收起时也要看得见内容。**
                        // 用户："好像是因为我在手机上点了排队的收起按钮" ——
                        // 收起来只剩一行计数，很容易以为队列没了。
                        // 所以收起时把**第一条**的文字带出来（跟待办面板一个做法）。
                        if !isQueueExpanded, let first = session.queuedMessages.first {
                            Text(first.text)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        Image(systemName: isQueueExpanded ? "chevron.down" : "chevron.up")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, Token.Spacing.gutter)
                    .frame(height: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(String(format: String(localized: "%lld 条排队消息"), session.queuedMessages.count)))
                .accessibilityHint(Text(isQueueExpanded ? "收起排队消息" : "展开排队消息"))

                if isQueueExpanded {
                    Divider().padding(.leading, Token.Spacing.gutter)
                    ForEach(session.queuedMessages) { item in
                        queueRow(item)
                        if item.id != session.queuedMessages.last?.id {
                            Divider().padding(.leading, Token.Spacing.gutter)
                        }
                    }
                }
            }
            .background(.bar)
            .overlay(alignment: .top) { Rectangle().fill(Color(.separator)).frame(height: 0.5) }
            .overlay(alignment: .bottom) { Rectangle().fill(Color(.separator)).frame(height: 0.5) }
        }
    }

    private func queueRow(_ item: QueuedMessage) -> some View {
        HStack(spacing: Token.Spacing.tight) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text)
                    .font(.footnote)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                if item.imageCount > 0 || item.fileCount > 0 {
                    Text(queueAttachmentLabel(item))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: Token.Spacing.hairline)

            queueAction("pencil", label: "编辑") {
                editingQueueItem = item
                queueEditText = item.text
            }
            queueAction("trash", label: "删除", tint: .red) {
                Task { await session.updateQueue(itemId: item.id, action: .remove) }
            }
            queueAction("arrow.up", label: "插进这一轮") {
                Task { await session.updateQueue(itemId: item.id, action: .steer) }
            }
        }
        .padding(.horizontal, Token.Spacing.gutter)
        .padding(.vertical, Token.Spacing.hairline)
        .frame(minHeight: 40)
        .accessibilityElement(children: .contain)
    }

    private func queueAction(_ symbol: String, label: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(tint ?? Color.secondary)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    private func queueAttachmentLabel(_ item: QueuedMessage) -> String {
        var parts: [String] = []
        if item.imageCount > 0 { parts.append(String(format: String(localized: "%lld 张图片"), item.imageCount)) }
        if item.fileCount > 0 { parts.append(String(format: String(localized: "%lld 个文件"), item.fileCount)) }
        return parts.joined(separator: " · ")
    }

    // MARK: 权限档位

    /// 直接在输入框里改权限。
    ///
    /// 权限是"这次任务怎么跑"的一部分，跟打字在同一个动作里 —— 桌面端也放在这儿。
    /// 之前它藏在右上角 `⋯` 菜单里，每次都要点两层。
    private var permissionButton: some View {
        Button {
            showPermissionPicker = true
        } label: {
            HStack(spacing: Token.Spacing.hairline) {
                Image(systemName: PermissionLabel.symbol(session.currentPermission))
                    .font(.caption)
                    .foregroundStyle(PermissionLabel.isRisky(session.currentPermission) ? Color.orange : Color.secondary)
                Text(PermissionLabel.text(session.currentPermission))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Token.Spacing.tight)
            .frame(height: Token.Control.diameter)
            .background(Color(.tertiarySystemFill), in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(localized: "权限：") + PermissionLabel.text(session.currentPermission)))
        .accessibilityHint(Text("改这个会话的文件读写与审批档位"))
    }

    // MARK: 上下文占用

    /// 上下文占用的进度条。
    ///
    /// 这个数字是"还能聊多久"的唯一线索 —— 快满的时候模型会开始压缩历史，
    /// 用户得能提前看到。桌面端把它放在输入框右边。
    @ViewBuilder
    private var contextBar: some View {
        if let pressure = session.contextPressure, pressure.contextWindow > 0 {
            let ratio = min(1, Double(pressure.pressureTokens) / Double(pressure.contextWindow))
            HStack(spacing: Token.Spacing.hairline) {
                Capsule(style: .continuous)
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 44, height: 5)
                    .overlay(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(ratio > 0.85 ? Color.orange : Color.accentColor)
                            .frame(width: max(3, 44 * ratio))
                    }
                // `verbatim`：这就是个百分数，不该进本地化目录
                // （写成 `Text("\(…)")` 会生成一条 key 为 `%lld%` 的条目）。
                Text(verbatim: "\(Int(ratio * 100))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(ratio > 0.85 ? Color.orange : Color.secondary)
            }
            .frame(height: Token.Control.diameter)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(String(format: String(localized: "上下文占用 %lld%%"), Int(ratio * 100))))
            .accessibilityValue(Text(Format.contextPressure(pressure) ?? ""))
        }
    }

    // MARK: 会话统计

    /// 输入框下面那行：轮数 / 步数 / 首字延迟 / 解码速度 / 缓存命中。
    ///
    /// 空会话不显示 —— 一排 0 只会占地方。
    @ViewBuilder
    private var statsLine: some View {
        let stats = session.sessionStats
        if !stats.isEmpty {
            // 居中：靠 `frame(maxWidth: .infinity)` + 居中，而不是靠左再加 Spacer。
            // 整行可点 —— 点开是上下文明细（官方 `contextBreakdown` 那三个数）。
            Button {
                guard session.contextBreakdown != nil else { return }
                showContextBreakdown = true
            } label: {
                HStack(spacing: Token.Spacing.hairline) {
                    Text(statTexts(stats).joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(session.contextBreakdown == nil)
            .padding(.horizontal, Token.Spacing.gutter)
            .padding(.top, Token.Spacing.hairline)
            .padding(.bottom, Token.Spacing.tight)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(statTexts(stats).joined(separator: "，")))
        }
    }

    private func statTexts(_ stats: SessionStats) -> [String] {
        var parts: [String] = []
        parts.append(String(format: String(localized: "%lld 轮"), stats.turns))
        parts.append(String(format: String(localized: "%lld 步"), stats.steps))
        if let ttft = stats.averageTimeToFirstToken {
            parts.append(String(format: String(localized: "首字 %@"), String(format: "%.1fs", ttft)))
        }
        if let speed = stats.tokensPerSecond {
            parts.append(String(format: String(localized: "%.0f tok/s"), speed))
        }
        if let cache = session.tokenUsage.cacheHitRate {
            parts.append(String(format: String(localized: "缓存 %.0f%%"), cache * 100))
        }
        // 上下文占用挪到这里 —— 跑着的时候上面那行没地方放它。
        if let pressure = session.contextPressure, pressure.contextWindow > 0 {
            let ratio = min(1, Double(pressure.pressureTokens) / Double(pressure.contextWindow))
            parts.append(String(format: String(localized: "上下文 %.0f%%"), ratio * 100))
        }
        return parts
    }

    /// `@` 候选按输入防抖拉一次。
    ///
    /// 每敲一个字符就发一次 RPC 太浪费 —— 250ms 内的连续输入只发最后一次。
    private func refreshReferences() {
        guard let trigger, trigger.kind == .reference else {
            referenceFiles = []
            referenceSessions = []
            return
        }
        let query = trigger.query
        referenceTask?.cancel()
        referenceTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let result = await session.referenceCandidates(query: query)
            guard !Task.isCancelled else { return }
            referenceFiles = result.files
            referenceSessions = result.sessions
        }
    }

    private var canSend: Bool {
        !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !session.attachments.isEmpty
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Token.Spacing.tight) {
                ForEach(session.attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let data = attachment.thumbnail, let image = UIImage(data: data) {
                                Image(uiImage: image).resizable().scaledToFill()
                            } else {
                                ZStack {
                                    Color(.tertiarySystemFill)
                                    VStack(spacing: 2) {
                                        Image(systemName: "doc").font(.title3)
                                        Text(attachment.name)
                                            .font(.caption2)
                                            .lineLimit(1)
                                            .padding(.horizontal, 4)
                                    }
                                }
                            }
                        }
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: Token.Radius.chip, style: .continuous))

                        Button {
                            session.removeAttachment(id: attachment.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.55))
                        }
                        .offset(x: 6, y: -6)
                        .accessibilityLabel(Text("移除附件 \(attachment.name)"))
                    }
                    .frame(width: 70, height: 70)
                }
            }
            .padding(.horizontal, Token.Spacing.gutter)
            .padding(.top, Token.Spacing.tight)
        }
    }

    // MARK: 动作

    private func send() {
        guard canSend else { return }
        sendTrigger += 1
        Task { await session.send() }
    }

    private func stop() {
        stopTrigger += 1
        Task { await session.cancel() }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let type = item.supportedContentTypes.first
            let mediaType = type?.preferredMIMEType ?? "image/jpeg"
            let ext = type?.preferredFilenameExtension ?? "jpg"
            session.addAttachment(name: "照片.\(ext)", mediaType: mediaType, data: data)
        }
        photoSelection = []
    }

    private func loadFiles(_ result: Result<[URL], any Error>) async {
        guard case .success(let urls) = result else { return }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let type = UTType(filenameExtension: url.pathExtension)
            let mediaType = type?.preferredMIMEType ?? "application/octet-stream"
            session.addAttachment(name: url.lastPathComponent, mediaType: mediaType, data: data)
        }
    }
}
