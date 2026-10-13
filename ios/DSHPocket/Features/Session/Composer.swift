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

            // 排队消息是**输入框上方一块可展开的记录**，不是摊在时间线末尾。
            // 桌面端就是这样：它属于"我准备发什么"，不属于"已经聊了什么"。
            queuePanel

            // 布局照桌面端：**输入框占整行**，下面一行放工具
            //（附件 / 权限 / 上下文占用 / 发送），再下面一行是会话统计。
            VStack(spacing: Token.Spacing.tight) {
                TextField("给电脑说点什么…", text: $session.draft, axis: .vertical)
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
        if isRunning {
            queueButton
            steerButton
            stopButton
        } else {
            sendButton
        }
    }

    private var queueButton: some View {
        Button { Task { await session.send(mode: .queue) } } label: {
            HStack(spacing: Token.Spacing.hairline) {
                Image(systemName: "arrow.up")
                    .font(.system(size: Token.Control.glyph - 3, weight: .semibold))
                Text("排队").font(.caption.weight(.semibold))
            }
            .foregroundStyle(canSend ? Color.white : Color.secondary)
            .padding(.horizontal, Token.Spacing.tight)
            .frame(height: Token.Control.diameter)
            .background(
                canSend ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.tertiarySystemFill)),
                in: Capsule(style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .accessibilityLabel(Text("追加排队"))
        .accessibilityHint(Text("等这一轮跑完再发出去"))
    }

    private var steerButton: some View {
        Button { Task { await session.send(mode: .steer) } } label: {
            CircleGlyph(systemImage: "bolt.fill", style: .quiet)
        }
        .disabled(!canSend)
        .opacity(canSend ? 1 : 0.5)
        .accessibilityLabel(Text("立刻插队"))
        .accessibilityHint(Text("插进正在跑的这一轮，不再等它跑完"))
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
        .accessibilityLabel(Text("发送"))
        .accessibilityHint(Text("把消息发给电脑"))
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
            HStack(spacing: Token.Spacing.hairline) {
                Text(statTexts(stats).joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
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
