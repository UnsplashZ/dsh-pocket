import SwiftUI

/// 助手正文的 Markdown 渲染。
///
/// 块级结构由 `MarkdownParser` 解析（可单测），这里只负责排版。
/// 内联（粗体/斜体/行内代码/链接）走系统的 `AttributedString(markdown:)` —— 不用自己写。
///
/// 两条排版约定：
///   · **遥测诚信**：正文里的图片**不从网上加载**。这个 App 的承诺是"所有流量都只去你自己的电脑"，
///     如果 Markdown 里一个 `![](http://…)` 就去拉外网，那条承诺就破了。远程图片渲染成一行占位。
///   · 表格横向可滚 —— 手机上把宽表格压缩换行比让它滚起来难读得多。
struct MarkdownBody: View {
    let text: String

    /// **解析一次，存下来。**
    ///
    /// 原来是 `private var blocks: [MarkdownBlock] { MarkdownParser.parse(text) }` ——
    /// 每次 body 求值都重新解析一遍。滚动期间 body 的求值次数远多于数据更新次数，
    /// 一条带表格的长回复（表格要拆行、算对齐、补列）反复解析是实打实的卡顿来源。
    private let blocks: [MarkdownBlock]

    init(text: String) {
        self.text = text
        self.blocks = MarkdownParser.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Token.Spacing.tight) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            InlineMarkdown(text)
                .font(headingFont(level))
                .padding(.top, Token.Spacing.hairline)

        case .paragraph(let text):
            InlineMarkdown(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

        case .code(let language, let text):
            CodeBlock(code: text, language: language)

        case .rule:
            Divider().padding(.vertical, Token.Spacing.hairline)

        case .listItem(let marker, let text, let depth):
            HStack(alignment: .firstTextBaseline, spacing: Token.Spacing.tight) {
                Text(marker)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 18, alignment: .trailing)
                InlineMarkdown(text)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * Token.Spacing.section)
            .accessibilityElement(children: .combine)

        case .quote(let text):
            HStack(alignment: .top, spacing: Token.Spacing.tight) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Color(.tertiaryLabel))
                    .frame(width: 3)
                InlineMarkdown(text)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, Token.Spacing.hairline)
            .accessibilityElement(children: .combine)

        case .image(let alt, let url):
            // **刻意不加载**。这个 App 的承诺是"所有流量都只去你自己的电脑"；
            // 正文里一个外网图片地址就去拉图，那条承诺就破了。
            HStack(spacing: Token.Spacing.tight) {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(alt.isEmpty ? String(localized: "图片") : alt)
                        .font(.subheadline)
                    Text(url)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Token.Spacing.tight)
            .background(
                RoundedRectangle(cornerRadius: Token.Radius.chip, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(String(localized: "图片 \(alt)，未加载：只从你的电脑取数据")))

        case .table(let table):
            MarkdownTable(table: table)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title3.weight(.bold)
        case 2: return .headline
        default: return .subheadline.weight(.semibold)
        }
    }
}

/// 内联 Markdown（粗体、斜体、行内代码、链接）。
///
/// 解析失败就退回纯文本 —— 一条渲染不了的富文本不该让整条消息消失。
struct InlineMarkdown: View {
    let text: String

    /// `AttributedString(markdown:)` 也不便宜。这里**必须走缓存**：
    ///
    /// 跟块级解析同一个坑 —— 父视图每次 body 求值都会重建这个 struct，
    /// init 里的解析于是每帧重跑。实测静置状态下每 2 秒 222 次，
    /// 一次求值里每个段落/列表项/表格单元格各一次，是掉帧的大头。
    private let attributed: AttributedString?

    /// 缓存。`AttributedString` 是值类型，塞进引用盒子里给 `NSCache`。
    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 2_000
        return cache
    }()

    private final class Box: NSObject {
        /// `nil` = 这段文本解析不了（要退回纯文本）。**这个也要缓存** ——
        /// 否则一段解析不了的文本每帧都会重试一遍解析。
        let value: AttributedString?
        init(_ value: AttributedString?) { self.value = value }
    }

    init(_ text: String) {
        self.text = text
        let key = text as NSString
        if let hit = Self.cache.object(forKey: key) {
            self.attributed = hit.value
        } else {
            let parsed = try? AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
            Self.cache.setObject(Box(parsed), forKey: key)
            self.attributed = parsed
        }
    }

    var body: some View {
        if let attributed {
            Text(attributed)
        } else {
            Text(text)
        }
    }
}

/// 表格。
///
/// 手机上宽表格只有两种做法：压缩换行（列内容被压得没法读）或横向滚动。
/// 这里选后者，并把**表头固定在横向滚动区里一起滚**（SwiftUI 的 Grid 不会固定表头，
/// 但把表头与数据放在同一个 ScrollView 里至少不会错位）。
private struct MarkdownTable: View {
    let table: MarkdownBlock.Table

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: Token.Spacing.compact, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(table.headers.enumerated()), id: \.offset) { index, header in
                        cellText(header, column: index, isHeader: true)
                    }
                }
                Divider().gridCellColumns(max(table.headers.count, 1))

                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { index, value in
                            cellText(value, column: index, isHeader: false)
                        }
                    }
                    if row != table.rows.last {
                        Divider().gridCellColumns(max(table.headers.count, 1))
                    }
                }
            }
            .padding(Token.Spacing.tight)
        }
        .background(
            RoundedRectangle(cornerRadius: Token.Radius.chip, style: .continuous)
                .fill(Color(.tertiarySystemFill))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(String(localized: "表格，\(table.headers.count) 列 \(table.rows.count) 行")))
    }

    private func cellText(_ value: String, column: Int, isHeader: Bool) -> some View {
        InlineMarkdown(value)
            .font(isHeader ? .subheadline.weight(.semibold) : .subheadline)
            .multilineTextAlignment(textAlignment(column))
            .frame(minWidth: 60, alignment: frameAlignment(column))
            .padding(.vertical, Token.Spacing.hairline)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func alignment(_ column: Int) -> MarkdownBlock.Table.Alignment {
        column < table.alignments.count ? table.alignments[column] : .leading
    }

    private func textAlignment(_ column: Int) -> TextAlignment {
        switch alignment(column) {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func frameAlignment(_ column: Int) -> Alignment {
        switch alignment(column) {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}
