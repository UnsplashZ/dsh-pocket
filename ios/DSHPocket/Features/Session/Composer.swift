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
    @State private var showFileImporter = false
    @State private var sendTrigger = 0
    @State private var stopTrigger = 0

    private var isRunning: Bool { session.isTurnRunning }

    var body: some View {
        VStack(spacing: 0) {
            if !session.attachments.isEmpty {
                attachmentStrip
            }

            HStack(alignment: .bottom, spacing: Token.Spacing.tight) {
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

                TextField("给电脑说点什么…", text: $session.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused(isFocused)
                    .submitLabel(.send)
                    .onSubmit { send() }
                    .padding(.horizontal, Token.Spacing.compact)
                    .padding(.vertical, Token.Spacing.tight)
                    .background(
                        RoundedRectangle(cornerRadius: Token.Radius.bubble, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )
                    .accessibilityLabel(Text("消息"))

                // 同一位置：空闲=发送，运行中=停止
                Button(action: isRunning ? stop : send) {
                    CircleGlyph(
                        systemImage: isRunning ? "stop.fill" : "arrow.up",
                        style: isRunning ? .destructive : .prominent
                    )
                }
                .disabled(!isRunning && !canSend)
                .accessibilityLabel(Text(isRunning ? "停止" : "发送"))
                .accessibilityHint(Text(isRunning ? "打断正在跑的这一轮" : "把消息发给电脑"))
            }
            .padding(.horizontal, Token.Spacing.gutter)
            .padding(.vertical, Token.Spacing.tight)
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
