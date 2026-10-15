import DSHKit
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
///   3. QuickLook **只认本地 URL**，所以取回来的字节要先落到临时目录。
///   4. 相对路径按**该会话自己的工作区**解析 —— 实测同一个相对路径用不同会话当
///      scope 会落到不同目录（这正是产物卡需要的：产物路径是相对会话工作区写的）。
///
/// 取回策略：先 `stat` 拿大小，再决定走文本还是二进制 —— 文本走 `read`（能按行截断、
/// 拿得到 `eof`），其余（图片/PDF/未知扩展名）走 `readBytes` 交给系统预览。
@MainActor
@Observable
final class FilePreviewModel {
    enum Phase: Equatable {
        case idle
        case loading
        case ready(URL)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// 文件在电脑上的绝对路径（预览页标题与"复制路径"用）。
    private(set) var absolutePath: String?
    private(set) var byteSize: Int?

    private var task: Task<Void, Never>?

    /// 只做"取回并落盘"，不负责展示 —— 调用方拿 `phase` 决定怎么显示。
    func load(scopeId: String, path: String, client: DSHClient) {
        task?.cancel()
        phase = .loading
        absolutePath = nil
        byteSize = nil
        task = Task { [weak self] in
            do {
                let stat = try await client.statFile(scopeId: scopeId, path: path)
                let resolved = stat.absolutePath ?? path
                let name = (resolved as NSString).lastPathComponent
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)

                if Self.isTextual(name), let bytes = stat.byteSize, bytes <= Self.maxInlineTextBytes {
                    let text = try await client.readFileText(scopeId: scopeId, path: resolved)
                    try Self.write(Data(text.utf8), to: url)
                } else {
                    let bytes = try await client.readFileBytes(scopeId: scopeId, path: resolved)
                    try Self.write(bytes, to: url)
                }
                guard let self, !Task.isCancelled else { return }
                self.absolutePath = resolved
                self.byteSize = stat.byteSize
                self.phase = .ready(url)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.phase = .failed((error as? DSHClientError)?.displayMessage ?? error.localizedDescription)
            }
        }
    }

    func cancel() { task?.cancel(); task = nil }

    /// 文本类文件走 `read` 的上限。再大就交给 `readBytes` + QuickLook ——
    /// 把几十 MB 的文本读进内存再转 `String` 没有意义。
    private static let maxInlineTextBytes = 2 * 1024 * 1024

    static func isTextual(_ name: String) -> Bool {
        switch (name as NSString).pathExtension.lowercased() {
        case "md", "markdown", "txt", "log", "json", "yml", "yaml", "toml", "csv", "tsv",
             "swift", "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "rb", "go", "rs", "java",
             "kt", "c", "h", "cpp", "hpp", "cs", "php", "sh", "bash", "zsh", "sql", "html",
             "css", "scss", "xml", "plist", "patch", "diff", "ini", "cfg", "conf", "env":
            return true
        default:
            return false
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
struct FilePreviewScreen: View {
    let scopeId: String
    let path: String
    /// 可选标题（产物卡有 title，比文件名更好认）。
    var title: String?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var preview = FilePreviewModel()
    @State private var showQuickLook = false

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
                    // 取回成功后**立刻**推 QuickLook；它自己是全屏的，
                    // 用户关掉就回到这里（这里只作为"关掉之后"的落地页）。
                    VStack(spacing: Token.Spacing.compact) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("已取回")
                            .font(.headline)
                        if let size = preview.byteSize, let text = Format.bytes(size) {
                            Text(text).font(.caption).foregroundStyle(.tertiary)
                        }
                        Button("再打开一次") { showQuickLook = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .onChange(of: preview.phase) { _, new in
                if case .ready = new { showQuickLook = true }
            }
            .sheet(isPresented: $showQuickLook) {
                if case .ready(let url) = preview.phase {
                    QuickLookPreview(url: url)
                }
            }
        }
    }

    private func load() {
        preview.load(scopeId: scopeId, path: path, client: model.client)
    }
}
