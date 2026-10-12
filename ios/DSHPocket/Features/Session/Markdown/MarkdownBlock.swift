import Foundation

/// Markdown 的**块级**结构。
///
/// 为什么自己写而不是引第三方库（记在 [DECISIONS.md](../../../../docs/DECISIONS.md) ADR-0013）：
/// 试过 MarkdownUI —— 它能解析、也能在 SwiftPM 里编译，但只要把包引用写进
/// `project.yml`，**Xcode 27 加载工程时就直接挂死**（`xcodebuild -list` 60 秒不返回，
/// 包解析永远不会完成）。那套 vendored 方案要连 `swift-cmark`（C 库）一起搬，
/// 加起来 5 MB 源码，对一个"把表格画对"的需求不成比例。
///
/// 所以这里做一个**只覆盖实际会遇到的块**的小渲染器：标题、段落、代码块、
/// 表格、列表、引用、分隔线。内联（粗体/斜体/行内代码/链接）交给
/// `AttributedString(markdown:)`，那是系统自带的，不用自己写。
///
/// 解析是纯函数，因此可单测 —— 之前表格原样显示成 `| 方向 | 能做什么 |` 就是
/// 因为压根没有块级解析。
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String?, text: String)
    case table(Table)
    case listItem(marker: String, text: String, depth: Int)
    case quote(String)
    case rule
    /// 单独成段的图片。**不从网上加载** —— 见 `MarkdownBody` 的说明。
    case image(alt: String, url: String)

    struct Table: Equatable {
        var headers: [String]
        var rows: [[String]]
        /// 每列是否右对齐（`:---:` / `---:`）。
        var alignments: [Alignment]

        enum Alignment: Equatable { case leading, center, trailing }
    }
}

enum MarkdownParser {
    /// 把一段 Markdown 切成块。
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var inCode = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }

        let lines = text.components(separatedBy: .newlines)
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // ── 代码围栏 ──────────────────────────────────────────────
            if trimmed.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(language: codeLanguage, text: codeLines.joined(separator: "\n")))
                    codeLines = []
                    codeLanguage = nil
                    inCode = false
                } else {
                    flushParagraph()
                    let tag = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    codeLanguage = tag.isEmpty ? nil : tag
                    inCode = true
                }
                index += 1
                continue
            }
            if inCode {
                codeLines.append(line)
                index += 1
                continue
            }

            // ── 空行：段落边界 ────────────────────────────────────────
            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            // ── 水平分隔线（必须在列表之前判，否则 `---` 会被当成列表标记）──
            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }

            // ── 表格：本行有 `|`，下一行是分隔行 ──────────────────────
            if trimmed.contains("|"),
               index + 1 < lines.count,
               isTableSeparator(lines[index + 1].trimmingCharacters(in: .whitespaces)) {
                flushParagraph()
                let headers = splitRow(trimmed)
                let alignments = alignmentsOf(lines[index + 1].trimmingCharacters(in: .whitespaces), count: headers.count)
                var rows: [[String]] = []
                var cursor = index + 2
                while cursor < lines.count {
                    let candidate = lines[cursor].trimmingCharacters(in: .whitespaces)
                    guard candidate.contains("|"), !candidate.isEmpty else { break }
                    rows.append(pad(splitRow(candidate), to: headers.count))
                    cursor += 1
                }
                blocks.append(.table(.init(headers: headers, rows: rows, alignments: alignments)))
                index = cursor
                continue
            }

            // ── 标题 ──────────────────────────────────────────────────
            if let heading = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                index += 1
                continue
            }

            // ── 引用 ──────────────────────────────────────────────────
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                var cursor = index
                while cursor < lines.count {
                    let candidate = lines[cursor].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    quoted.append(String(candidate.dropFirst()).trimmingCharacters(in: .whitespaces))
                    cursor += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                index = cursor
                continue
            }

            // ── 列表 ──────────────────────────────────────────────────
            if let item = parseListItem(line) {
                flushParagraph()
                blocks.append(item)
                index += 1
                continue
            }

            // ── 单独成段的图片 ────────────────────────────────────────
            if let image = parseImage(trimmed), paragraph.isEmpty {
                flushParagraph()
                blocks.append(image)
                index += 1
                continue
            }

            // ── 普通段落 ──────────────────────────────────────────────
            paragraph.append(line)
            index += 1
        }

        if inCode, !codeLines.isEmpty {
            blocks.append(.code(language: codeLanguage, text: codeLines.joined(separator: "\n")))
        }
        flushParagraph()
        return blocks
    }

    // MARK: 逐行识别

    private static func isRule(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        let stripped = trimmed.replacingOccurrences(of: " ", with: "")
        guard let first = stripped.first, "-*_".contains(first) else { return false }
        return stripped.allSatisfy { $0 == first }
    }

    private static func parseHeading(_ trimmed: String) -> MarkdownBlock? {
        let hashes = trimmed.prefix { $0 == "#" }
        guard !hashes.isEmpty, hashes.count <= 6, trimmed.dropFirst(hashes.count).hasPrefix(" ") else { return nil }
        let title = trimmed.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        return .heading(level: hashes.count, text: title)
    }

    /// 整行就是一个 `![alt](url)` 时识别为图片块。
    private static func parseImage(_ trimmed: String) -> MarkdownBlock? {
        guard trimmed.hasPrefix("!["), trimmed.hasSuffix(")") else { return nil }
        guard let split = trimmed.range(of: "](") else { return nil }
        let alt = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<split.lowerBound])
        let url = String(trimmed[split.upperBound...].dropLast())
        guard !url.isEmpty else { return nil }
        return .image(alt: alt, url: url)
    }

    private static func parseListItem(_ line: String) -> MarkdownBlock? {
        // 缩进深度：每两个空格算一层
        let leadingSpaces = line.prefix { $0 == " " || $0 == "\t" }.count
        let depth = leadingSpaces / 2
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            let text = String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            return .listItem(marker: "•", text: text, depth: depth)
        }

        // 有序列表：`12. ` 这类
        let digits = trimmed.prefix { $0.isNumber }
        if !digits.isEmpty, trimmed.dropFirst(digits.count).hasPrefix(". ") {
            let text = String(trimmed.dropFirst(digits.count + 2)).trimmingCharacters(in: .whitespaces)
            return .listItem(marker: "\(digits).", text: text, depth: depth)
        }
        return nil
    }

    // MARK: 表格工具

    private static func isTableSeparator(_ line: String) -> Bool {
        guard line.contains("-") else { return false }
        let cells = splitRow(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let stripped = cell.replacingOccurrences(of: " ", with: "")
            guard stripped.hasPrefix("-") || stripped.hasPrefix(":") else { return false }
            return stripped.allSatisfy { $0 == "-" || $0 == ":" } && stripped.contains("-")
        }
    }

    /// 拆一行表格：去掉首尾的 `|`，按 `|` 切，并 trim。
    static func splitRow(_ line: String) -> [String] {
        var body = line.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        return body
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func alignmentsOf(_ separator: String, count: Int) -> [MarkdownBlock.Table.Alignment] {
        let cells = splitRow(separator)
        return (0..<count).map { index in
            guard index < cells.count else { return .leading }
            let cell = cells[index].replacingOccurrences(of: " ", with: "")
            let leading = cell.hasPrefix(":")
            let trailing = cell.hasSuffix(":")
            switch (leading, trailing) {
            case (true, true): return .center
            case (false, true): return .trailing
            default: return .leading
            }
        }
    }

    private static func pad(_ row: [String], to count: Int) -> [String] {
        if row.count >= count { return Array(row.prefix(count)) }
        return row + Array(repeating: "", count: count - row.count)
    }
}
