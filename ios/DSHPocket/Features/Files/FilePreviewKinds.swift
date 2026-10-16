import Foundation

/// 一个工作区文件**该怎么显示**。
///
/// 这个枚举存在的原因是"点开一个文件"以前会弹**两个窗口**：
/// `FilePreviewScreen` 自己是一个 sheet，取回成功后它又用 `.sheet` 推一个
/// 系统 QuickLook —— 于是先看到"正在从电脑取回…"，紧接着一个全屏预览盖上来。
/// 用户对这条链路的原话是"先跳了一个窗口出来，然后又跳了一个正文窗口"。
///
/// 现在改成**一个窗口里直接渲染**：取回过程与该格式的渲染器在同一页里切换，
/// 不再叠第二个 sheet。分类逻辑抽成纯函数放这里，好单测。
///
/// 另一件事：`.md` 以前交给系统 QuickLook，而 QuickLook **不渲染 Markdown**
/// （把 `# 标题`、`**粗体**`、`| 表格 |` 原样画出来）。那正是用户截图里的样子。
/// 所以 Markdown 走 App 自己的 `MarkdownBody`，和其它正文用同一套排版。
enum FilePreviewKind: Equatable {
    /// 纯 Markdown：走 App 自己的渲染器（QuickLook 不认 Markdown）。
    case markdown
    /// 其它文本：等宽排版，保留原文换行。
    case text
    /// 图片：`UIImage` 直接显示，可缩放。
    case image
    /// PDF：`PDFView` 翻页。
    case pdf
    /// 认不出的二进制：仍然交给系统 QuickLook（它至少能给个文件图标的兜底页面）。
    case systemPreview

    /// 按文件名（扩展名）判断该怎么显示。
    ///
    /// 只看名字，不看内容 —— 需要看内容的判断（比如"这个 `.md` 其实是二进制"）
    /// 放到取回之后再做，这里保持纯函数。
    static func classify(fileName: String) -> FilePreviewKind {
        let ext = (fileName as NSString).pathExtension.lowercased()

        // **`pathExtension` 对 dotfile 回空串**（`.gitignore` / `.env` / `.gitattributes`），
        // 所以按扩展名分派的表接不住它们，得单独判。这些按约定都是纯文本。
        if ext.isEmpty, isDotFile(fileName) { return .text }

        switch ext {
        case "md", "markdown", "mdown", "mkd":
            return .markdown
        case "txt", "text", "log", "json", "jsonl", "yml", "yaml", "toml", "csv", "tsv",
             "swift", "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "rb", "go", "rs", "java",
             "kt", "kts", "c", "h", "cc", "cpp", "hpp", "cs", "php", "sh", "bash", "zsh",
             "fish", "sql", "html", "htm", "css", "scss", "less", "xml", "plist", "patch",
             "diff", "ini", "cfg", "conf", "env", "properties", "lock":
            return .text
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif":
            return .image
        case "pdf":
            return .pdf
        default:
            // 无扩展名但按约定就是纯文本（`LICENSE` / `Makefile` / `Dockerfile` …）。
            if ext.isEmpty, looksLikePlainTextName(fileName) { return .text }
            // 其余（含 `svg`）交给系统 QuickLook 兜底：它认得的类型比 `UIImage` 多，
            // 而且画不出来时至少给文件图标 + 大小 + 分享。
            // 实测 `UIImage(contentsOfFile:)` **读不了 SVG**（返回 nil），所以 svg 不走图片分支。
            return .systemPreview
        }
    }

    /// `.gitignore` / `.env` 这类"以点开头、没有扩展名"的文件。
    private static func isDotFile(_ fileName: String) -> Bool {
        let name = (fileName as NSString).lastPathComponent
        // 排除 `.` / `..` 这种路径成分；其余以点开头且只有开头那个点 → dotfile。
        guard name.hasPrefix("."), name.count > 1 else { return false }
        return !name.dropFirst().contains(".")
    }

    /// 无扩展名但按约定就是纯文本的文件名。
    private static func looksLikePlainTextName(_ name: String) -> Bool {
        let known: Set<String> = [
            "license", "licence", "notice", "version", "changelog", "readme", "authors",
            "contributors", "copying", "install", "todo", "codeowners",
            "makefile", "dockerfile", "containerfile", "gemfile", "rakefile", "procfile",
            "brewfile", "justfile", "vagrantfile",
        ]
        return known.contains(name.lowercased())
    }

    /// 这一类是不是"文本"（决定取回时用 `read` 还是 `readBytes`）。
    ///
    /// Markdown 也算文本，但**不能**用宿主那个 5000 行的窗口去读 ——
    /// 超过 5000 行的文档会被截断（见 `FilePreviewModel.load` 的说明）。
    var isTextual: Bool {
        switch self {
        case .markdown, .text: return true
        case .image, .pdf, .systemPreview: return false
        }
    }
}
