import DSHKit
import SwiftUI

/// 时间线上的一条。
///
/// 渲染规则（docs/IOS-DESIGN.md §4 S2）：
///   · 用户消息 → 右侧气泡；助手消息 → 左侧正文卡片；
///   · 工具调用 → **默认折叠一行**（符号 + 名字 + 状态 + 耗时），点开看参数/结果；
///   · 助手气泡里**不画** tool-call 块（工具走单独一行，见 `renderableBlocks`）；
///   · 未知事件不丢，折叠成一条可展开的"未知事件"。
struct TimelineRow: View {
    let item: TimelineItem
    let session: SessionModel

    /// 找到这条审批对应工具调用的参数。
    ///
    /// 审批请求本身只带工具名与理由（`ApprovalRequestEvent`），**不带参数** ——
    /// 参数在时间线的那条 `tool/call` 上，按 `callId` 关联。
    /// 不把它拿出来，用户就是在"不知道要执行什么"的情况下点批准。
    private func pendingArguments(for approval: TimelineItem.Approval) -> String? {
        // 用审批挂着的**工具调用 id** 去关联，不是审批自己的 id。
        guard let callId = approval.callId ?? (approval.approvalId.isEmpty ? nil : approval.approvalId) else {
            return nil
        }
        for candidate in session.items.reversed() {
            if case .toolCall(let call) = candidate.kind, call.callId == callId {
                let trimmed = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        }
        return nil
    }

    var body: some View {
        switch item.kind {
        case .turnStart(let turn):
            turnDivider(turn: turn, isStart: true)

        case .turnEnd(let turn, let reason):
            turnEndDivider(turn: turn, reason: reason)

        case .userMessage(let message):
            UserBubble(message: message, session: session, time: item.time)

        case .assistantMessage(let message):
            // 轮次结束之后思考过程要收起来（除非用户手动展开）。
            AssistantCard(
                message: message,
                time: item.time,
                isTurnComplete: item.turn.map { session.completedTurns.contains($0) } ?? false
            )

        case .toolCall(let call):
            ToolRow(call: call)

        case .todo(let list):
            TodoCard(list: list)

        case .approval(let approval):
            ApprovalCard(approval: approval, item: item, pendingArguments: pendingArguments(for: approval))

        case .compaction(let compaction):
            compactionRow(compaction)

        case .goal(let goal):
            noteRow(
                text: goal.objective ?? String(localized: "目标已更新"),
                symbol: "target",
                tone: .info
            )

        case .planMode(let plan):
            noteRow(
                text: plan.isActive ? String(localized: "已进入计划模式") : String(localized: "已退出计划模式"),
                symbol: "list.bullet.rectangle",
                tone: .neutral
            )

        case .deliverables(let list):
            DeliverablesCard(items: list)

        case .note(let note):
            noteRow(text: note.text, symbol: note.symbolName, tone: note.tone.statusTone)

        case .raw(let type, let data):
            RawEventRow(type: type, data: data)

        case .unknown(let type, let data):
            RawEventRow(type: type, data: data, isUnknown: true)
        }
    }

    // MARK: 分隔

    private func turnDivider(turn: Int, isStart: Bool) -> some View {
        HStack(spacing: Token.Spacing.tight) {
            Rectangle().fill(Color(.separator)).frame(height: 1)
            Text(String(localized: "第 \(turn) 轮"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
            Text(Format.time(item.time))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize()
            Rectangle().fill(Color(.separator)).frame(height: 1)
        }
        .padding(.vertical, Token.Spacing.tight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("第 \(turn) 轮，\(Format.time(item.time)) 开始"))
    }

    private func turnEndDivider(turn: Int, reason: TimelineItem.TurnEndReason) -> some View {
        HStack {
            Spacer()
            Label(reasonLabel(reason), systemImage: reason.isFailure ? "exclamationmark.triangle" : "checkmark")
                .font(.caption2)
                .foregroundStyle(reason.isFailure ? Color.red : Color.secondary)
            Spacer()
        }
        .padding(.vertical, Token.Spacing.hairline)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(String(localized: "第 \(turn) 轮：\(reasonLabel(reason))")))
    }

    private func reasonLabel(_ reason: TimelineItem.TurnEndReason) -> String {
        switch reason {
        case .completed: return String(localized: "这一轮结束")
        case .interrupted: return String(localized: "已中断")
        case .failed(let message): return message.isEmpty ? String(localized: "出错结束") : message
        case .other(let kind): return kind
        }
    }

    private func compactionRow(_ compaction: TimelineItem.Compaction) -> some View {
        HStack {
            Spacer()
            VStack(spacing: Token.Spacing.hairline) {
                Label(compactionLabel(compaction.phase), systemImage: "arrow.triangle.merge")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !compaction.summary.isEmpty {
                    Text(compaction.summary)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(3)
                }
            }
            Spacer()
        }
        .padding(.vertical, Token.Spacing.tight)
        .accessibilityElement(children: .combine)
    }

    private func compactionLabel(_ phase: TimelineItem.Compaction.Phase) -> String {
        switch phase {
        case .start: return String(localized: "开始压缩上下文")
        case .summary: return String(localized: "上下文已压缩")
        case .end: return String(localized: "压缩完成")
        case .prune: return String(localized: "已裁剪旧工具结果")
        }
    }

    private func noteRow(text: String, symbol: String, tone: StatusTone) -> some View {
        HStack(spacing: Token.Spacing.tight) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(tone.color)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Token.Spacing.hairline)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 用户气泡

struct UserBubble: View {
    let message: TimelineItem.UserMessage
    let session: SessionModel
    let time: Date

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack {
            Spacer(minLength: Token.Spacing.section * 2)

            VStack(alignment: .trailing, spacing: Token.Spacing.tight) {
                if !message.images.isEmpty {
                    HStack(spacing: Token.Spacing.hairline) {
                        ForEach(message.images) { image in
                            AttachmentThumbnail(reference: image, session: session)
                        }
                    }
                }

                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.body)
                        .foregroundStyle(.white)
                        .padding(.horizontal, Token.Spacing.compact)
                        .padding(.vertical, Token.Spacing.tight)
                        .background(
                            RoundedRectangle(cornerRadius: Token.Radius.bubble, style: .continuous)
                                .fill(Color.accentColor)
                        )
                }

                if !message.files.isEmpty {
                    ForEach(message.files) { file in
                        Label(file.name ?? String(localized: "附件"), systemImage: "doc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: Token.Spacing.hairline) {
                    if message.isPending {
                        ProgressView().controlSize(.mini)
                        Text("发送中…").font(.caption2).foregroundStyle(.tertiary)
                    } else {
                        Text(Format.time(time)).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(String(localized: "你说：\(message.text)")))
    }
}

/// 排队中的消息。
///
/// 刻意**画得跟已发送的不一样**：更淡、带「排队中」标签、并且说明它在等什么。
/// 之前队列完全不显示，用户会以为那条消息已经发出去了。
struct QueuedMessagesRow: View {
    let messages: [QueuedMessage]

    var body: some View {
        VStack(alignment: .leading, spacing: Token.Spacing.tight) {
            HStack(spacing: Token.Spacing.hairline) {
                Image(systemName: "clock.badge")
                    .font(.caption)
                Text(messages.count == 1
                     ? String(localized: "1 条排队中")
                     : String(format: String(localized: "%lld 条排队中"), messages.count))
                    .font(.caption.weight(.medium))
                Spacer()
            }
            .foregroundStyle(.secondary)

            ForEach(messages) { message in
                VStack(alignment: .leading, spacing: Token.Spacing.hairline) {
                    if !message.text.isEmpty {
                        Text(message.text)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if message.imageCount > 0 || message.fileCount > 0 {
                        Text(attachmentLabel(message))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Token.Spacing.compact)
                .background(
                    RoundedRectangle(cornerRadius: Token.Radius.bubble, style: .continuous)
                        .fill(Color.accentColor.opacity(0.10))
                )
                // 虚线边框：一眼能看出"还没真正发出去"。
                .overlay(
                    RoundedRectangle(cornerRadius: Token.Radius.bubble, style: .continuous)
                        .strokeBorder(
                            Color.accentColor.opacity(0.35),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                        )
                )
            }

            Text("电脑跑完这一轮就会发出去。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(String(format: String(localized: "%lld 条消息排队中"), messages.count)))
    }

    private func attachmentLabel(_ message: QueuedMessage) -> String {
        var parts: [String] = []
        if message.imageCount > 0 { parts.append(String(format: String(localized: "%lld 张图片"), message.imageCount)) }
        if message.fileCount > 0 { parts.append(String(format: String(localized: "%lld 个文件"), message.fileCount)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 助手卡片

struct AssistantCard: View {
    let message: TimelineItem.AssistantMessage
    let time: Date
    /// 这一轮跑完了没有。决定了思考过程是"边跑边看"还是"收起来"。
    var isTurnComplete: Bool = false

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // 跑着的时候：折叠面板，默认收起（长推理会把对话挤下去），设置里可以改成默认展开。
    @State private var reasoningExpanded = false
    /// 轮次结束**之后**用户有没有手动把思考过程翻出来。
    ///
    /// 与上面那个分开：用户要的是"输出最终结果时全部隐藏，除非手动展开"。
    /// 跑的时候该看就看，跑完就该消失 —— 两种状态不能共用一个开关。
    @State private var reasoningRevealedAfterCompletion = false
    @State private var hasAppliedDefault = false

    private var hasReasoning: Bool {
        message.blocks.contains { if case .reasoning(let text) = $0 {
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }; return false }
    }

    var body: some View {
        HStack {
            Card {
                VStack(alignment: .leading, spacing: Token.Spacing.tight) {
                    ForEach(Array(message.renderableBlocks.enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .text(let text):
                            MarkdownBody(text: text)

                        case .reasoning(let text):
                            // 轮次结束 + 用户没手动展开 → **整块不渲染**。
                            // 这就是"输出最终结果时把思考过程全藏起来"。
                            if !isTurnComplete {
                                reasoningBlock(text)
                            } else if reasoningRevealedAfterCompletion {
                                revealedReasoningBlock(text)
                            }

                        case .image(let reference):
                            Label(reference.name ?? String(localized: "图片"), systemImage: "photo")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                        case .toolCall:
                            EmptyView()   // 工具走单独的 ToolRow
                        }
                    }

                    HStack(spacing: Token.Spacing.hairline) {
                        if message.isStreaming {
                            Text("▌")
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .symbolEffect(.pulse, options: reduceMotion ? .nonRepeating : .repeating)
                                .accessibilityLabel(Text("正在生成"))
                        }
                        if message.interrupted {
                            StatusBadge("已中断", symbol: "stop.circle", tone: .warning)
                        }
                        // 轮次结束后思考过程整块藏起来了，入口留在这里。
                        // 做得**刻意低干扰**：一行小字，跟时间并排，不抢正文。
                        if isTurnComplete, hasReasoning, !reasoningRevealedAfterCompletion {
                            Button {
                                withAnimation(reduceMotion ? nil : .snappy) {
                                    reasoningRevealedAfterCompletion = true
                                }
                            } label: {
                                Label("思考过程", systemImage: "brain")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(Text("展开这一轮模型的推理过程"))
                        }
                        Spacer(minLength: 0)
                        Text(Format.time(time))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: Token.Spacing.section * 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(String(localized: "助手回复")))
    }

    /// 轮次结束、用户手动翻出来之后的推理内容。
    ///
    /// 与跑着时的折叠面板不同：这里**给一个明确的收起按钮** ——
    /// 用户是主动翻出来的，得能主动放回去。
    private func revealedReasoningBlock(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: Token.Spacing.hairline) {
            HStack {
                Label("思考过程", systemImage: "brain")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("收起") {
                    withAnimation(reduceMotion ? nil : .snappy) {
                        reasoningRevealedAfterCompletion = false
                    }
                }
                .font(.caption2)
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(Token.Spacing.tight)
        .background(
            RoundedRectangle(cornerRadius: Token.Radius.chip, style: .continuous)
                .fill(Color(.tertiarySystemFill))
        )
        .accessibilityElement(children: .contain)
    }

    private func reasoningBlock(_ text: String) -> some View {
        DisclosureGroup(isExpanded: $reasoningExpanded) {
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Token.Spacing.hairline)
        } label: {
            Label("思考过程", systemImage: "brain")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityHint(Text("展开查看模型的推理过程"))
        .onAppear {
            // 只在第一次出现时套用设置，之后尊重用户手动展开/收起。
            guard !hasAppliedDefault else { return }
            hasAppliedDefault = true
            reasoningExpanded = model.settings.expandReasoningByDefault
            // 设置里打开"默认展开"时，轮次结束之后也一并翻出来。
            reasoningRevealedAfterCompletion = model.settings.expandReasoningByDefault
        }
    }
}

/// 代码块：等宽 + 横向滚动 + 复制按钮 + 分享。
struct CodeBlock: View {
    let code: String
    let language: String?

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? String(localized: "代码"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.4))
                        copied = false
                    }
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(copied ? "已复制代码" : "复制代码"))
            }
            .padding(.horizontal, Token.Spacing.tight)
            .padding(.vertical, Token.Spacing.hairline)

            MonoBlock(code)
        }
        .background(
            RoundedRectangle(cornerRadius: Token.Radius.chip, style: .continuous)
                .fill(Color(.tertiarySystemFill))
        )
    }
}

// MARK: - 工具调用

/// 工具调用：**默认折叠成一行**（符号 + 名字 + 状态 + 耗时）。
struct ToolRow: View {
    let call: TimelineItem.ToolCall

    @State private var expanded = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isLongOutput: Bool { call.output.count > 1_200 }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: Token.Spacing.tight) {
                if !call.arguments.isEmpty {
                    Text("参数")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    MonoBlock(prettyPrinted(call.arguments), lineLimit: expanded ? nil : 6)
                }
                if !call.output.isEmpty {
                    HStack {
                        Text(call.isError ? "错误输出" : "输出")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(call.isError ? Color.red : Color.secondary)
                        Spacer()
                        if isLongOutput {
                            Text(Format.bytes(call.output.count) ?? "")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    MonoBlock(call.output, lineLimit: expanded ? nil : 12)
                    if isLongOutput {
                        ShareLink(item: call.output) {
                            Label("查看全部 / 分享", systemImage: "square.and.arrow.up")
                                .font(.caption)
                        }
                    }
                }
            }
            .padding(.top, Token.Spacing.hairline)
        } label: {
            HStack(spacing: Token.Spacing.tight) {
                Image(systemName: symbol)
                    .font(.footnote)
                    .foregroundStyle(call.status == .failed ? Color.red : Color.secondary)
                    .frame(width: 18)

                Text(call.name)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)

                StatusBadge(call.status.localizedLabel, symbol: call.status.symbolName, tone: tone)

                Spacer(minLength: Token.Spacing.hairline)

                // AX3 以上把耗时挪到第二行，避免挤压工具名
                if let duration = Format.duration(call.duration) {
                    Text(duration)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .layoutPriority(dynamicTypeSize.isAccessibilitySize ? -1 : 1)
                }
            }
        }
        .padding(Token.Spacing.tight)
        .background(
            RoundedRectangle(cornerRadius: Token.Radius.card, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Token.Radius.card, style: .continuous)
                .strokeBorder(Color(.separator), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    private var accessibilityLabel: String {
        var parts = [String(localized: "工具 \(call.name)"), call.status.localizedLabel]
        if let duration = Format.duration(call.duration) { parts.append(duration) }
        return parts.joined(separator: "，")
    }

    private var tone: StatusTone {
        switch call.status {
        case .running: return .info
        case .success: return .success
        case .failed: return .failure
        case .cancelled: return .neutral
        }
    }

    /// 工具类别的符号。认不出的工具一律 `wrench.and.screwdriver`。
    private var symbol: String {
        let name = call.name.lowercased()
        if name.contains("bash") || name.contains("shell") || name.contains("pwsh") { return "terminal" }
        if name.contains("read") || name.contains("fs") || name.contains("file") { return "doc.text" }
        if name.contains("write") || name.contains("edit") { return "square.and.pencil" }
        if name.contains("search") || name.contains("grep") || name.contains("glob") { return "magnifyingglass" }
        if name.contains("web") || name.contains("fetch") { return "globe" }
        if name.contains("todo") { return "checklist" }
        if name.contains("subagent") || name.contains("agent") { return "person.2" }
        if name.contains("present") { return "sparkles" }
        return "wrench.and.screwdriver"
    }

    private func prettyPrinted(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8)
        else { return raw }
        return text
    }
}

// MARK: - 待办

struct TodoCard: View {
    let list: TimelineItem.TodoList

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Token.Spacing.hairline) {
                Label("待办", systemImage: "checklist")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(list.items) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: Token.Spacing.tight) {
                        Image(systemName: symbol(entry.status))
                            .font(.footnote)
                            .foregroundStyle(tone(entry.status).color)
                            .frame(width: 16)
                        Text(entry.text)
                            .font(.subheadline)
                            .strikethrough(entry.status == .completed, color: .secondary)
                            .foregroundStyle(entry.status == .completed ? Color.secondary : Color.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text("\(entry.text)，\(statusLabel(entry.status))"))
                }
            }
        }
    }

    private func symbol(_ status: TimelineItem.TodoEntry.Status) -> String {
        switch status {
        case .pending: return "circle"
        case .inProgress: return "circle.dotted"
        case .completed: return "checkmark.circle.fill"
        }
    }

    private func tone(_ status: TimelineItem.TodoEntry.Status) -> StatusTone {
        switch status {
        case .pending: return .neutral
        case .inProgress: return .info
        case .completed: return .success
        }
    }

    private func statusLabel(_ status: TimelineItem.TodoEntry.Status) -> String {
        switch status {
        case .pending: return String(localized: "待办")
        case .inProgress: return String(localized: "进行中")
        case .completed: return String(localized: "已完成")
        }
    }
}

// MARK: - 产物

struct DeliverablesCard: View {
    let items: [TimelineItem.Deliverable]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Token.Spacing.tight) {
                Label("产物", systemImage: "shippingbox")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.subheadline.weight(.medium))
                        if let description = item.description {
                            Text(description).font(.caption).foregroundStyle(.secondary)
                        }
                        if let path = item.path {
                            Text(path)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contextMenu {
                        if let path = item.path {
                            Button {
                                UIPasteboard.general.string = path
                            } label: {
                                Label("复制路径", systemImage: "doc.on.doc")
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 原始 / 未知事件

struct RawEventRow: View {
    let type: String
    let data: JSONValue
    var isUnknown = false

    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            MonoBlock(data.displayText(limit: 6_000), lineLimit: expanded ? nil : 10)
                .padding(.top, Token.Spacing.hairline)
        } label: {
            HStack(spacing: Token.Spacing.tight) {
                Image(systemName: isUnknown ? "questionmark.diamond" : "curlybraces")
                    .font(.caption)
                    .foregroundStyle(isUnknown ? Color.orange : Color.secondary)
                Text(type)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if isUnknown {
                    StatusBadge("认不出", symbol: "questionmark", tone: .warning)
                }
            }
        }
        .padding(Token.Spacing.tight)
        .background(
            RoundedRectangle(cornerRadius: Token.Radius.chip, style: .continuous)
                .fill(Color(.quaternarySystemFill))
        )
        .accessibilityLabel(Text(isUnknown ? String(localized: "认不出的事件 \(type)") : type))
    }
}

// MARK: - 附件缩略图

struct AttachmentThumbnail: View {
    let reference: TimelineItem.ImageRef
    let session: SessionModel

    @State private var data: Data?
    @State private var showPreview = false

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color(.tertiarySystemFill)
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 140, height: 140)
        .clipShape(RoundedRectangle(cornerRadius: Token.Radius.chip, style: .continuous))
        .onTapGesture { showPreview = true }
        .task {
            if data == nil { data = await session.image(for: reference) }
        }
        .accessibilityLabel(Text(reference.name ?? String(localized: "图片附件")))
        .accessibilityAddTraits(.isImage)
        .accessibilityHint(Text("点按全屏查看"))
        .fullScreenCover(isPresented: $showPreview) {
            if let data, let image = UIImage(data: data) {
                ImagePreview(image: image, onClose: { showPreview = false })
            }
        }
    }
}

struct ImagePreview: View {
    let image: UIImage
    let onClose: () -> Void

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    MagnificationGesture()
                        .onChanged { scale = max(1, $0) }
                        .onEnded { _ in if scale <= 1 { offset = .zero } }
                )
                .gesture(
                    DragGesture()
                        .onChanged { offset = $0.translation }
                        .onEnded { _ in if scale <= 1 { offset = .zero } }
                )
            VStack {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.4))
                    }
                    .minimumHitTarget()
                    .accessibilityLabel(Text("关闭"))
                }
                Spacer()
            }
            .padding(Token.Spacing.gutter)
        }
    }
}
