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
    /// 这一轮里"哪一条"该显示操作行（传 `turn.headline?.id`）。
    /// `nil` = 都不显示（还在跑的轮次）。
    var actionsFor: String? = nil

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
                session: session,
                time: item.time,
                seq: item.seq,
                showsActions: actionsFor == item.id,
                isTurnComplete: item.turn.map { session.completedTurns.contains($0) } ?? false
            )

        case .toolCall(let call):
            // 子代理调用单独一张卡：它的价值在于"能点进去看它干了什么"，
            // 而不是像 bash 那样展开一段 JSON。
            if call.name == "subagent" {
                SubagentCard(call: call, session: session)
            } else {
                ToolRow(call: call)
            }

        case .todo:
            // 待办**不在时间线里**了 —— 挪到输入框上方那块常驻面板
            // （见 Composer.todoPanel）。放在这里会被滚走，
            // 而它恰恰是"现在进行到哪了"的答案。
            EmptyView()

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

/// 一次子代理调用。
///
/// 桌面上子代理也是一张独立的卡（不是普通工具行）—— 它是一次**委派**，
/// 用户需要知道：派给了谁、在干什么、干完没有、以及**能点进去看**。
struct SubagentCard: View {
    let call: TimelineItem.ToolCall
    let session: SessionModel

    @Environment(AppModel.self) private var model

    /// 工具调用的参数里就有人类可读的那句描述。
    private var label: String {
        guard let data = call.arguments.data(using: .utf8),
              let object = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return String(localized: "子代理") }
        return object.string("description") ?? object.string("prompt").map { String($0.prefix(40)) } ?? String(localized: "子代理")
    }

    private var isBackground: Bool {
        guard let data = call.arguments.data(using: .utf8),
              let object = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return false }
        return object.bool("run_in_background") ?? false
    }

    private var subagentId: String? {
        session.subagentSessionId(label: label, at: call.startedAt)
    }

    private var summary: DSHKit.SessionSummary? {
        guard let subagentId else { return nil }
        return model.sessions.first { $0.sessionId == subagentId }
    }

    private var isRunning: Bool { summary?.isRunning ?? (call.status == .running) }

    var body: some View {
        Button {
            guard let subagentId else { return }
            model.pendingOpenSessionId = subagentId
        } label: {
            Card {
                VStack(alignment: .leading, spacing: Token.Spacing.tight) {
                    HStack(spacing: Token.Spacing.tight) {
                        Image(systemName: "person.2.wave.2")
                            .foregroundStyle(.tint)
                        Text(label)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: Token.Spacing.tight)
                        if subagentId != nil {
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    HStack(spacing: Token.Spacing.tight) {
                        if isRunning {
                            StatusBadge("运行中", symbol: "circle.dotted", tone: .info)
                        } else if call.status == .success {
                            StatusBadge("已完成", symbol: "checkmark.circle.fill", tone: .success)
                        } else if call.status == .failed {
                            StatusBadge("失败", symbol: "xmark.circle.fill", tone: .failure)
                        }
                        if isBackground {
                            Text("后台")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let ended = call.endedAt {
                            Text(Format.duration(ended.timeIntervalSince(call.startedAt)) ?? "")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                    }

                    // 子代理的输出就是它的结论 —— 折叠着给一眼，点进去看全过程。
                    if !call.output.isEmpty {
                        Text(call.output)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if subagentId == nil {
                        Text("找不到对应的子代理会话（可能已经不在列表里了）")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(subagentId == nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(String(localized: "子代理：") + label))
        .accessibilityHint(Text(subagentId == nil ? "" : "打开这个子代理的会话"))
    }
}

// MARK: - 轮次分组

/// 一个轮次。
///
/// 跑完了就**收拢**：明面上只留一行「已完成，用时 X」+ 最终结论，
/// 中间的思考、命令、过场说明全部折叠进去（点摘要行展开）。
/// 这跟桌面端一致 —— 一个跑了半小时的轮次能刷出几十屏，
/// 真正要回看的往往只有最后那段话。
///
/// 还在跑的轮次**照常全展开**：正在发生的事没有收拢的道理。
struct TurnGroupView: View {
    let turn: TimelineTurn
    let session: SessionModel

    @State private var isExpanded = false
    @State private var hasAppliedDefault = false

    /// 轮内除摘要两端之外的条目。
    ///
    /// 在 `init` 里算一次 —— 它每个 body 求值都要扫一遍 `turn.items`，
    /// 而滚动期间 body 的求值次数远多于数据更新次数。
    private let startItem: TimelineItem?
    private let bodyItems: [TimelineItem]

    init(turn: TimelineTurn, session: SessionModel) {
        self.turn = turn
        self.session = session
        self.startItem = turn.items.first { if case .turnStart = $0.kind { return true }; return false }
        self.bodyItems = turn.items.filter { item in
            switch item.kind {
            case .turnStart, .turnEnd: return false
            default: return true
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Token.Spacing.tight) {
            if let startItem {
                TimelineRow(item: startItem, session: session)
                    .padding(.horizontal, Token.Spacing.gutter)
            }

            if turn.isComplete {
                // 用户自己说的话永远在最上面，不参与折叠。
                ForEach(turn.pinned) { item in
                    TimelineRow(item: item, session: session)
                        .padding(.horizontal, Token.Spacing.gutter)
                        .id(item.id)
                }

                summaryRow
                    .padding(.horizontal, Token.Spacing.gutter)

                // 收起 = 用户消息 + 结论；展开 = 全过程，**都按时间顺序**。
                ForEach(isExpanded ? turn.expandedItems : turn.collapsedItems) { item in
                    TimelineRow(item: item, session: session, actionsFor: turn.headline?.id)
                        .padding(.horizontal, Token.Spacing.gutter)
                        .id(item.id)
                }
            } else {
                // 跑着：全展开，实时看得到。**不给操作行** ——
                // 还没出最终结果，复制/点赞都没有对象。
                ForEach(bodyItems) { item in
                    TimelineRow(item: item, session: session, actionsFor: nil)
                        .padding(.horizontal, Token.Spacing.gutter)
                        .id(item.id)
                }
            }
        }
        // **轮次跑完时"过程消息收起来"要有动画。**
        // 不加的话是一次瞬间跳变：几十条过程消息凭空消失、内容骤减，
        // 滚动位置一下子落到内容之外 —— 屏幕上就是一片空白
        //（用户："因为任务完成，折叠过程消息导致的内容空白"）。
        .animation(.snappy(duration: 0.42), value: turn.isComplete)
        .onAppear {
            #if DEBUG
            // 调试用：`defaults write cc.unsplashz.dshpocket DSHExpandTurns -bool YES`
            // 让所有轮次默认展开，便于核对展开后的时序。
            guard !hasAppliedDefault else { return }
            hasAppliedDefault = true
            if UserDefaults.standard.bool(forKey: "DSHExpandTurns") { isExpanded = true }
            #endif
        }
    }

    private var summaryRow: some View {
        Button {
            withAnimation(.snappy) { isExpanded.toggle() }
        } label: {
            HStack(spacing: Token.Spacing.tight) {
                Image(systemName: turn.isComplete ? "checkmark.circle" : "circle.dotted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(summaryLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if !turn.collapsible.isEmpty {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(minHeight: Token.minimumHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(turn.collapsible.isEmpty)
        .accessibilityLabel(Text(summaryLabel))
        .accessibilityHint(Text(isExpanded ? "收起这一轮的过程" : "展开这一轮的过程"))
    }

    private var summaryLabel: String {
        var parts: [String] = [String(localized: "已完成")]
        if let duration = turn.duration, let formatted = Format.duration(duration) {
            parts.append(String(format: String(localized: "用时 %@"), formatted))
        }
        if turn.collapsedCount > 0 {
            parts.append(String(format: String(localized: "%lld 步"), turn.collapsedCount))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 助手卡片

struct AssistantCard: View {
    let message: TimelineItem.AssistantMessage
    /// 复制/点赞/分支都要它。
    let session: SessionModel
    let time: Date
    /// 这条消息在日志里的 seq —— 分支要按它切。
    var seq: Double = 0
    /// 要不要显示操作行（复制/点赞/分支/用量）。
    ///
    /// **只有"轮次结束时的最终那条"才显示**：中间那些过场消息上也挂一排按钮
    /// 会把正文淹掉，而且它们本来就会随轮次一起收起来。
    var showsActions: Bool = false
    /// 这一轮跑完了没有。决定了思考过程是"边跑边看"还是"收起来"。
    var isTurnComplete: Bool = false

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 用户有没有把思考过程翻出来。
    ///
    /// **默认永远是关的**（跑着的时候也是）—— 长轮次里每一步都冒一张卡片太吵，
    /// 而推理内容一次点击就能看到。设置里的"默认展开"可以把它变成常开。
    @State private var reasoningRevealed = false
    @State private var hasAppliedDefault = false
    @State private var copyFeedback = 0

    private var hasReasoning: Bool {
        message.blocks.contains { if case .reasoning(let text) = $0 {
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }; return false }
    }

    var body: some View {
        // 卡片 + **卡片下方的操作行**。操作行放在卡片里看起来像正文的一部分
        // （用户："放在会话卡片里怪怪的"）。
        VStack(alignment: .leading, spacing: Token.Spacing.hairline) {
            HStack {
                Card {
                    VStack(alignment: .leading, spacing: Token.Spacing.tight) {
                        ForEach(Array(message.renderableBlocks.enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .text(let text):
                            MarkdownBody(text: text)

                        case .reasoning(let text):
                            // **一律默认不渲染**，只留页脚那个入口。
                            //
                            // 之前分两种状态（跑着看、跑完收起），但用户要的是
                            // "不默认显示" —— 而且一个长轮次里每一步都冒一张
                            // "思考过程"卡片，跟工具行交错在一起非常吵。
                            if reasoningRevealed {
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
                        // 思考过程的入口就留在这里。
                        // 做得**刻意低干扰**：一行小字，跟时间并排，不抢正文。
                        if hasReasoning, !reasoningRevealed {
                            Button {
                                withAnimation(reduceMotion ? nil : .snappy) { reasoningRevealed = true }
                            } label: {
                                Label(
                                    // 跑着的时候说"思考中"，让人知道它正在推理；
                                    // 跑完了就说"思考过程"，暗示这里存着内容。
                                    message.isStreaming || !isTurnComplete ? "思考中…" : "思考过程",
                                    systemImage: "brain"
                                )
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(Text("展开模型的推理过程"))
                        }
                        Spacer(minLength: 0)
                    }
                }
                }
            }

            // 操作行在**卡片下方、卡片外面** —— 放在卡片里看起来像正文的一部分
            // （用户："放在会话卡片里怪怪的"）。
            if showsActions {
                actionRowOutsideCard
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(String(localized: "助手回复")))
    }

    /// 卡片**下方**那一行：操作按钮 + 用量 + 时间，整行左对齐。
    private var actionRowOutsideCard: some View {
        HStack(spacing: Token.Spacing.tight) {
            actionRow
            if let usage = message.usage, usage.totalTokens > 0 {
                Text(String(format: String(localized: "用量 %@"), Format.tokens(usage.totalTokens) ?? ""))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Text(Format.time(time))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        // 跟卡片左边对齐：卡片自己有内边距，这里补上同样的量。
        .padding(.leading, Token.Spacing.compact)
    }

    /// 一条消息能做的事：复制、点赞点踩、从这里分支。
    ///
    /// 跟用量、时间**挤在同一行**，整行左对齐 —— 桌面上也是这么摆的：
    /// 这些是回看时才需要的动作，不该占据正文的注意力，也不该在中间空出一大片。
    @ViewBuilder
    private var actionRow: some View {
        if message.hasRenderableContent {
            HStack(spacing: 2) {
                actionIcon("doc.on.doc", label: "复制") {
                    UIPasteboard.general.string = message.plainText
                    copyFeedback += 1
                }
                if !messageId.isEmpty {
                    actionIcon(
                    feedback == .positive ? "hand.thumbsup.fill" : "hand.thumbsup",
                    label: String(localized: "赞"),
                    tint: feedback == .positive ? .accentColor : nil
                    ) {
                        Task { await session.toggleFeedback(messageId: messageId, rating: .positive) }
                    }
                    actionIcon(
                    feedback == .negative ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                    label: String(localized: "踩"),
                    tint: feedback == .negative ? .orange : nil
                    ) {
                        Task { await session.toggleFeedback(messageId: messageId, rating: .negative) }
                    }
                }
                actionIcon("arrow.triangle.branch", label: String(localized: "从这里分支")) {
                    Task {
                        guard let id = await session.fork(atSeq: Int(seq)) else { return }
                        await model.refreshSessions()
                        model.pendingOpenSessionId = id
                    }
                }
            }
            .sensoryFeedback(.success, trigger: copyFeedback)
        }
    }

    private func actionIcon(
        _ symbol: String,
        label: String,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(tint ?? Color.secondary)
                // 图标小，但点击区不能小 —— 用透明外框补齐 44pt。
                .frame(width: Token.minimumHitTarget, height: Token.minimumHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    /// 这条消息在日志里的 id —— 评价按它索引。
    /// 拿不到就没有评价入口（宁可不给，也不要给一个点了报错的按钮）。
    private var messageId: String { message.messageId ?? "" }

    private var feedback: MessageFeedbackRating? {
        guard !messageId.isEmpty else { return nil }
        return session.feedbacks[messageId]?.rating
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
                    withAnimation(reduceMotion ? nil : .snappy) { reasoningRevealed = false }
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
                    StatusBadge(String(localized: "认不出"), symbol: "questionmark", tone: .warning)
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
