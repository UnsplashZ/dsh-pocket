import DSHKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// S3 输入区。
///
/// 布局：`.safeAreaInset(edge: .bottom)`；1–6 行自适应；圆角容器 + `.thinMaterial`。
/// 主按钮**同一位置的形态切换**：空闲=发送，运行中=停止（不要并排两个按钮）。
struct Composer: View {
    @Bindable var session: SessionModel

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var isFocused: Bool
    @State private var photoSelection: [PhotosPickerItem] = []
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
                    PhotosPicker(
                        selection: $photoSelection,
                        maxSelectionCount: 6,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        Label("照片", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("文件", systemImage: "doc")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.title3)
                        .frame(width: Token.minimumHitTarget, height: Token.minimumHitTarget)
                        .background(Circle().fill(Color(.tertiarySystemFill)))
                }
                .accessibilityLabel(Text("添加附件"))

                TextField("给电脑说点什么…", text: $session.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($isFocused)
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
                    Image(systemName: isRunning ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(isRunning ? Color.red : Color.accentColor)
                        .frame(width: Token.minimumHitTarget, height: Token.minimumHitTarget)
                }
                .disabled(!isRunning && !canSend)
                .accessibilityLabel(Text(isRunning ? "停止" : "发送"))
                .accessibilityHint(Text(isRunning ? "打断正在跑的这一轮" : "把消息发给电脑"))
            }
            .padding(.horizontal, Token.Spacing.gutter)
            .padding(.vertical, Token.Spacing.tight)
        }
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
        .photosPicker(isPresented: .constant(false), selection: $photoSelection)
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
