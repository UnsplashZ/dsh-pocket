import DSHKit
import PDFKit
import QuickLook
import SwiftUI

/// 一个**工作区文件**的预览。
///
/// 为什么单独抽出来：交付产物卡（时间线里）和「工作区文件」页都要"点开看一眼"，
/// 而这条链路有几个必须做对的地方（都是实测踩出来的）：
///
///   1. **`workspaceFiles/read` 的 `range` 是必填字段**（空对象 `{}` = 整个文件）。
///      省略会被描述符校验拒掉（`missing "range"`），传 `null` 也不行
///      （`field "range" failed boundary validation`）。
///   2. **二进制要走 `readBytes`**，它返回的是 **multipart** 而不是 JSON，
///      而且**不能用 `String` 中转**（图片字节不是合法 UTF-8，一转就毁）。
///   3. 相对路径按**该会话自己的工作区**解析 —— 实测同一个相对路径用不同会话当
///      scope 会落到不同目录（这正是产物卡需要的：产物路径是相对会话工作区写的）。
///   4. **只开一个窗口**。以前这里是"sheet 里再 `.sheet` 推 QuickLook"：
///      先闪一个取回页，紧接着被一个全屏预览盖住 —— 用户原话是"先跳了一个窗口出来，
///      然后又跳了一个正文窗口"。现在取回过程与该格式的渲染器在**同一页**里切换。
///   5. **Markdown 不能交给系统 QuickLook** —— 它不渲染 Markdown，会把
///      `# 标题`、`**粗体**`、`| 表格 |` 原样画出来（用户截图里就是这样）。
///      现在 Markdown 走 App 自己的 `MarkdownBody`，与正文同一套排版。
///
/// 取回策略（对着活宿主逐项实测过，见 `docs/PROTOCOL-NOTES.md`）：
///   · 文本（含 Markdown）先走 `read`（有 `eof`，能如实说"截断了"）；
///   · 但 `read` 的窗口是 **5000 行 / eof:false**，超过就只剩开头 ——
///     而按 `offset` 翻页**拼不回原文**（实测拼出来的字节和磁盘不一致），
///     所以不翻页；文件不大时改用 `readBytes` 整份取回（实测逐字节一致，12 MB 也行）。
@MainActor
@Observable
final class FilePreviewModel {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    /// 取回成功后的内容。每种形态对应一个**同页内**的渲染器。
    enum Content {
        case markdown(String)
        case text(String)
        case image(URL)
        case pdf(URL)
        /// 认不出的二进制，交给系统 QuickLook。
        case systemPreview(URL)
    }

    private(set) var phase: Phase = .idle
    private(set) var content: Content?
    /// 只拿到了开头（宿主的 `read` 是 5000 行窗口，而从 `readBytes` 整份取回也有上限）。
    ///
    /// 放在 model 上而不是塞进 `Content`：截断与"渲染成什么"是两件事，
    /// 而且 Markdown 与纯文本都要如实说明 —— 免得哪一类被静默截断。
    private(set) var isTruncated = false
    /// 文件在电脑上的绝对路径（预览页标题与"复制路径"用）。
    private(set) var absolutePath: String?
    private(set) var byteSize: Int?

    private var task: Task<Void, Never>?

    /// 只做"取回"，不负责展示 —— 调用方拿 `phase` / `content` 决定怎么显示。
    func load(scopeId: String, path: String, client: DSHClient) {
        task?.cancel()
        phase = .loading
        content = nil
        isTruncated = false
        absolutePath = nil
        byteSize = nil
        task = Task { [weak self] in
            do {
                let stat = try await client.statFile(scopeId: scopeId, path: path)
                // 绝对路径最稳（`stat` 自己解析出来的），拿它去 read / readBytes。
                let resolved = stat.absolutePath ?? path
                let name = (resolved as NSString).lastPathComponent
                let kind = FilePreviewKind.classify(fileName: name)
                let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(name)

                let loaded: Content
                var truncated = false
                switch kind {
                case .markdown, .text:
                    (loaded, truncated) = try await Self.loadTextual(
                        kind: kind, scopeId: scopeId, path: resolved,
                        stat: stat, client: client, scratch: scratch
                    )
                case .image, .pdf, .systemPreview:
                    let bytes = try await client.readFileBytes(scopeId: scopeId, path: resolved)
                    try Self.write(bytes, to: scratch)
                    switch kind {
                    case .image: loaded = .image(scratch)
                    case .pdf: loaded = .pdf(scratch)
                    default: loaded = .systemPreview(scratch)
                    }
                }

                guard let self, !Task.isCancelled else { return }
                self.absolutePath = resolved
                self.byteSize = stat.byteSize ?? Self.size(of: loaded)
                self.isTruncated = truncated
                self.content = loaded
                self.phase = .ready
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.phase = .failed((error as? DSHClientError)?.displayMessage ?? error.localizedDescription)
            }
        }
    }

    func cancel() { task?.cancel(); task = nil }

    // MARK: 文本 / Markdown

    private static func loadTextual(
        kind: FilePreviewKind,
        scopeId: String,
        path: String,
        stat: WorkspaceFileStat,
        client: DSHClient,
        scratch: URL
    ) async throws -> (Content, truncated: Bool) {
        let read = try await client.readFile(scopeId: scopeId, path: path)
        var text = read.text
        var truncated = !read.isEOF

        // `read` 只给 5000 行，超过了就只剩开头。文件不大时改用 `readBytes`
        // 整份取回 —— 实测逐字节一致（`read` 的 offset 翻页则拼不回原文，
        // 所以宁可多下一份字节，也不做会静默丢内容的拼接）。
        if truncated, let total = read.byteSize ?? stat.byteSize, total <= maxWholeTextBytes {
            let bytes = try await client.readFileBytes(scopeId: scopeId, path: path)
            if let whole = String(data: bytes, encoding: .utf8) {
                text = whole
                truncated = false
            } else {
                // 扩展名是文本、内容却不是 UTF-8：交给系统预览，别显示乱码。
                try write(bytes, to: scratch)
                return (.systemPreview(scratch), false)
            }
        }

        // 超过 `readBytes` 的上限时仍然是"只有开头"，这个标志要一路传到界面上
        //（Markdown 与纯文本都一样，不能因为它是 Markdown 就静默截断）。
        switch kind {
        case .markdown: return (.markdown(text), truncated)
        default: return (.text(text), truncated)
        }
    }

    /// 文本整份取回的上限。再大就只显示开头 ——
    /// 手机上一次下载几十 MB 再排版，收益不成比例。
    private static let maxWholeTextBytes = 8 * 1024 * 1024

    private static func size(of content: Content) -> Int? {
        switch content {
        case .markdown(let text), .text(let text): return text.utf8.count
        case .image, .pdf, .systemPreview: return nil
        }
    }

    private static func write(_ data: Data, to url: URL) throws {
        // 临时目录里可能残留同名旧文件（同名的另一份产物），先清掉再写，
        // 否则 QuickLook 会拿缓存里的旧内容。
        try? FileManager.default.removeItem(at: url)
        try data.write(to: url, options: .atomic)
    }
}

/// 全屏预览一个工作区文件。
///
/// 生命周期：出现时取回、消失时取消。取回中显示进度，失败给出**可执行**的原因
/// （文件被删了 / 会话没权限 / 连不上电脑，三种说法不一样）。
///
/// **整页只有一个窗口**：取回、文本/Markdown 渲染、图片、PDF、系统预览
/// 都是这一页里的不同状态，不再叠第二个 sheet（ADR-0028）。
struct FilePreviewScreen: View {
    let scopeId: String
    let path: String
    /// 可选标题（产物卡有 title，比文件名更好认）。
    var title: String?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var preview = FilePreviewModel()

    var body: some View {
        NavigationStack {
            Group {
                switch preview.phase {
                case .idle, .loading:
                    VStack(spacing: Token.Spacing.compact) {
                        ProgressView().controlSize(.large)
                        Text("正在从电脑取回…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .failed(let message):
                    ContentUnavailableView {
                        Label("打不开这个文件", systemImage: "doc.badge.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("重试") { load() }
                    }

                case .ready:
                    if let content = preview.content {
                        renderer(for: content)
                    }
                }
            }
            .navigationTitle(title ?? (path as NSString).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let absolutePath = preview.absolutePath {
                        Button {
                            UIPasteboard.general.string = absolutePath
                        } label: {
                            Label("复制路径", systemImage: "doc.on.doc")
                        }
                    }
                }
            }
            .task { load() }
            .onDisappear { preview.cancel() }
        }
    }

    // MARK: 各格式的渲染器（都在这一页里，不开新窗口）

    @ViewBuilder
    private func renderer(for content: FilePreviewModel.Content) -> some View {
        switch content {
        case .markdown(let text):
            ScrollView {
                VStack(alignment: .leading, spacing: Token.Spacing.tight) {
                    // 截断说明对 Markdown 同样要给（大文件只取了开头）。
                    if preview.isTruncated { truncatedNotice }
                    MarkdownBody(text: text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(Token.Spacing.gutter)
            }

        case .text(let text):
            ScrollView {
                VStack(alignment: .leading, spacing: Token.Spacing.tight) {
                    if preview.isTruncated { truncatedNotice }
                    Text(text)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(Token.Spacing.gutter)
            }

        case .image(let url):
            ZoomableImage(url: url)

        case .pdf(let url):
            PDFKitView(url: url)
                .ignoresSafeArea(edges: .bottom)

        case .systemPreview(let url):
            QuickLookPreview(url: url)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    /// 只拿到开头时说清"这里不是全部"，而不是让用户以为文件就这么长。
    private var truncatedNotice: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("文件太大，只显示了开头部分")
                if let size = Format.bytes(preview.byteSize) {
                    Text(size).font(.caption).foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: "scissors")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(Token.Spacing.tight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Token.Radius.chip, style: .continuous)
                .fill(Color(.tertiarySystemFill))
        )
    }

    private func load() {
        preview.load(scopeId: scopeId, path: path, client: model.client)
    }
}

// MARK: - 图片

/// 图片预览：默认缩到屏幕内，支持双指缩放与双击复位 ——
/// 截图/设计稿在手机上放大看细节是常态。
private struct ZoomableImage: View {
    let url: URL

    var body: some View {
        Group {
            if let image = UIImage(contentsOfFile: url.path) {
                // 与聊天附件预览共用同一份实现（UIScrollView 捏合/拖动/双击）。
                //
                // 原来这里是 `ScrollView` + `MagnifyGesture`：手势挂在 ScrollView 上，
                // 会被它自己的滚动手势抢走，真机上**捏合不放大**。
                ZoomableImageView(image: image)
                    .accessibilityLabel(Text("图片预览"))
            } else {
                ContentUnavailableView {
                    Label("这个图片打不开", systemImage: "photo.badge.exclamationmark")
                } description: {
                    Text("文件取回来了，但不是这个 App 认得的图片格式。")
                }
            }
        }
    }
}

// MARK: - PDF

/// PDF 预览。用 PDFKit 而不是 QuickLook ——
/// 内嵌的 `QLPreviewController` 在这里**不显示内容**（只出翻页按钮、正文空白，
/// 它的扩展进程停在 `running-active-NotVisible`），PDFKit 才稳。
private struct PDFKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .systemBackground
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        // 换文件时才重建文档，避免每次 body 求值都重新解析。
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
    }
}

// MARK: - 系统 QuickLook

/// 系统 QuickLook 的 SwiftUI 包装（`QLPreviewController` 没有 SwiftUI 版）。
///
/// 只用于**认不出的二进制**（给个文件图标 + 大小 + 分享的兜底页面）。
/// 文本/Markdown/图片/PDF 都走上面的原生渲染器：
/// QuickLook 不渲染 Markdown，内嵌时 PDF 还会白屏。
struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            url as NSURL
        }
    }
}
