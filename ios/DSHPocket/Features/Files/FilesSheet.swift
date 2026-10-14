import DSHKit
import QuickLook
import SwiftUI

/// S5 文件浏览。
///
/// 路径语义是这里最容易错的地方（PROTOCOL-NOTES §5.10）：
/// `workspaceFiles/list` 用**工作区相对路径**，`read`/`stat` 用**绝对路径**。
struct FilesSheet: View {
    let scopeId: String

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var path: String = ""
    @State private var entries: [WorkspaceFileEntry] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var previewURL: URL?
    @State private var showPreview = false

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Section {
                        ContentUnavailableView {
                            Label("读不到文件", systemImage: "folder.badge.questionmark")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("重试") { Task { await load() } }
                        }
                    }
                } else if entries.isEmpty, !isLoading {
                    ContentUnavailableView(
                        "这个目录是空的",
                        systemImage: "folder",
                        description: Text(path.isEmpty ? String(localized: "工作区根目录") : path)
                    )
                } else {
                    ForEach(entries) { entry in
                        Button {
                            open(entry)
                        } label: {
                            HStack(spacing: Token.Spacing.tight) {
                                Image(systemName: symbol(for: entry))
                                    .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name).font(.body).lineLimit(1)
                                    if let size = Format.bytes(entry.byteSize) {
                                        Text(size).font(.caption2).foregroundStyle(.tertiary)
                                    }
                                }
                                Spacer()
                                if entry.isDirectory {
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if let entryPath = entry.path {
                                Button {
                                    UIPasteboard.general.string = entryPath
                                } label: {
                                    Label("复制路径", systemImage: "doc.on.doc")
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle(path.isEmpty ? String(localized: "工作区") : (path as NSString).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !path.isEmpty {
                        Button {
                            goUp()
                        } label: {
                            Label("上一层", systemImage: "chevron.up")
                        }
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await load() }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }
            }
            .overlay {
                if isLoading {
                    ZStack {
                        Color(.systemBackground).opacity(0.5)
                        ProgressView().controlSize(.large)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .sheet(isPresented: $showPreview) {
                if let previewURL {
                    QuickLookPreview(url: previewURL)
                }
            }
        }
    }

    private func symbol(for entry: WorkspaceFileEntry) -> String {
        if entry.isDirectory { return "folder" }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift", "ts", "js", "py", "rs", "go", "java", "kt", "c", "cpp", "h": return "chevron.left.forwardslash.chevron.right"
        case "md", "txt", "log", "json", "yml", "yaml", "toml": return "doc.text"
        case "png", "jpg", "jpeg", "gif", "webp", "heic": return "photo"
        case "pdf": return "doc.richtext"
        case "zip", "tar", "gz": return "archivebox"
        default: return "doc"
        }
    }

    private func open(_ entry: WorkspaceFileEntry) {
        guard let entryPath = entry.path else { return }
        if entry.isDirectory {
            path = entryPath
            Task { await load() }
            return
        }
        Task { await preview(entryPath) }
    }

    private func goUp() {
        let parent = (path as NSString).deletingLastPathComponent
        path = parent == "/" ? "" : parent
        Task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            // **根目录要传 `.`，不能省略 `path`** —— 服务端把 `path` 当必填，
            // 省略会被拒：`missing "path"`（实测，工作区文件点开就是这样读不着东西）。
            entries = try await model.client.listFiles(scopeId: scopeId, path: path.isEmpty ? "." : path)
                .sorted { lhs, rhs in
                    if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            error = nil
        } catch {
            self.error = (error as? DSHClientError)?.displayMessage ?? error.localizedDescription
            entries = []
        }
    }

    /// 预览：把文件内容落到临时目录再交给系统 QuickLook（QuickLook 只认本地 URL）。
    private func preview(_ absolutePath: String) async {
        do {
            let text = try await model.client.readFile(scopeId: scopeId, path: absolutePath)
            let name = (absolutePath as NSString).lastPathComponent
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            previewURL = url
            showPreview = true
        } catch {
            self.error = (error as? DSHClientError)?.displayMessage ?? error.localizedDescription
        }
    }
}

/// 系统 QuickLook 的 SwiftUI 包装（`QLPreviewController` 没有 SwiftUI 版）。
struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        controller.reloadData()
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            url as NSURL
        }
    }
}
