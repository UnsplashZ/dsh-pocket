import DSHKit
import SwiftUI

/// 诊断页：**"任何'宿主升级后 App 崩了'的问题，第一步都是跑探针，而不是看 App"**
/// （docs/DESIGN.md §7.3）。这一页就是把那一步做进 App 里。
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model

    @State private var logEntries: [DSHLogEntry] = []
    @State private var isRunningSelfCheck = false
    @State private var selfCheck: [CheckResult] = []
    @State private var showsRawLog = false
    /// 传输层此刻的**事实**。和 `model.connection`（界面状态）分开存：
    /// 两者脱节正是已知 bug 的形状（"明明已经连接上了，界面还在连接中"）。
    @State private var transportHealthy: Bool?
    @State private var isRunningIrohFallback = false
    /// 「强制用 iroh 兜底」的结果（`nil` = 还没跑过）。
    @State private var irohFallbackResult: String?

    struct CheckResult: Identifiable {
        let id = UUID()
        var title: String
        var detail: String
        var tone: StatusTone
        var symbol: String
    }

    var body: some View {
        List {
            connectionSection
            legacySection
            uplinkSection
            transportSection
            selfCheckSection
            logSection
        }
        .navigationTitle("诊断")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.refreshDiagnostics()
            logEntries = await model.logs.snapshot()
            transportHealthy = await model.transportSnapshot().healthy
        }
        .refreshable {
            await model.refreshDiagnostics()
            await model.refreshSessions()
            logEntries = await model.logs.snapshot()
            transportHealthy = await model.transportSnapshot().healthy
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: exportText) {
                    Label("导出日志", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    // MARK: 连接

    private var connectionSection: some View {
        Section("连接") {
            LabeledContent("状态") {
                HStack(spacing: Token.Spacing.hairline) {
                    StatusDot(tone: tone, label: model.connection.label)
                    Text(model.connection.label)
                }
            }
            if case .failed(let message) = model.connection {
                Text(message).font(Token.Typography.note).foregroundStyle(.red)
            }
            LabeledContent("会话流（mux）", value: muxLabel)
            LabeledContent("本地代理", value: model.diagnostics?.proxyURL ?? String(localized: "未启动"))
            LabeledContent("加密路径", value: pathLabel)
            if let rtt = model.diagnostics?.rttMilliseconds {
                LabeledContent("RTT", value: "\(rtt) ms")
            }
            if let address = model.diagnostics?.remoteAddress {
                LabeledContent("远端", value: address)
            }
            LabeledContent("本机端点 ID") {
                Text(model.localEndpointId.isEmpty ? "—" : String(model.localEndpointId.prefix(16)) + "…")
                    .font(Token.Typography.identifier)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 老用户提示

    /// 还在用旧 iroh 配对的老用户：**不给旧 UI，只在这里提示一句**。
    ///
    /// 为什么不自动迁过去：迁移需要 uplink 配对材料，而那要用户去电脑上生成一次。
    /// 自动迁移等于"升级后连不上"，所以这里只建议、不强制。
    @ViewBuilder
    private var legacySection: some View {
        if model.settings.transportMode != .uplink {
            Section {
                Text("这台手机还在用旧的 iroh 配对。建议到「设置 → 多路接入」里重新粘贴一次配对串：之后局域网 / 虚拟组网会更快，iroh 仍然作为兜底。")
                    .font(Token.Typography.note)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("建议重新配对")
            }
        }
    }

    // MARK: 多路接入

    /// 只在"多路接入"模式下显示。
    ///
    /// 三件事必须看得见，否则用户报"卡住"时无从判断：
    ///   1. **当前用哪一档**（局域网 / Tailscale / …）与它的地址；
    ///   2. **每一档各多快**（最近一次探测的 RTT）—— "局域网 4ms、Tailscale 90ms"
    ///      直接说明了为什么选中这一档；
    ///   3. **最近一次为什么换档**（上一档没通？被关掉了？）。
    @ViewBuilder
    private var uplinkSection: some View {
        if model.settings.transportMode == .uplink {
            Section {
                LabeledContent("当前档位", value: currentTierLabel)
                LabeledContent("当前网络", value: model.uplink.networkKind.resolvedLabel)
                LabeledContent("网关地址") {
                    Text(model.uplink.currentTier?.url.absoluteString ?? String(localized: "未选档"))
                        .font(Token.Typography.identifier)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                // 协议层实际打的是这个回环地址：ATS 只放行本地地址，
                // tailnet / 公网 IP 的明文 http 会被 -1022 拒掉（见 UplinkLocalProxy）。
                LabeledContent("本地代理") {
                    Text(model.uplink.baseURL?.absoluteString ?? "—")
                        .font(Token.Typography.identifier)
                        .foregroundStyle(.secondary)
                }
                if let remaining = model.uplink.ticketRemainingSeconds {
                    LabeledContent("票据", value: String(localized: "还剩 \(String(remaining)) 秒"))
                }
                // iroh 与"网关档"是**两条独立的路**，绝不能合成一个"已连接"：
                // 用户要知道"现在走的是局域网"、"iroh 已经配好了但没在用"。
                if let endpoint = model.uplinkPairing?.irohEndpointId {
                    // 三种状态 + 来源，别混成一个"已连接"：
                    //   已配对（电脑端确认）/ 已配对（本地记录）/ 未配对 + 灰字原因。
                    LabeledContent("iroh 兜底") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(irohStatusLabel)
                                .foregroundStyle(model.irohStatus.isPaired ? .green : .secondary)
                            Text(String(endpoint.prefix(12)) + "…")
                                .font(Token.Typography.identifier)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if case .unpaired(let reason) = model.irohStatus {
                        Text(reason.advice)
                            .font(Token.Typography.secondary)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                ForEach(model.uplink.tierStatuses) { status in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Token.Spacing.tight) {
                            Label(status.tier.kind.label, systemImage: status.tier.kind.symbol)
                            Spacer()
                            if !status.enabled {
                                Text("已关闭")
                                    .font(Token.Typography.secondary)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(status.rttMilliseconds.map { "\($0) ms" } ?? "—")
                                .font(Token.Typography.identifier)
                                .foregroundStyle(status.isCurrent ? .primary : .secondary)
                        }
                        Text(status.tier.url.absoluteString)
                            .font(Token.Typography.identifier)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        // **为什么不通**比"通不通"更有用：超时 / 被拒 / 认错电脑
                        // 的修法完全不同，只写一句"探测失败"等于什么都没说。
                        if let reason = status.skipReason {
                            Text(reason)
                                .font(Token.Typography.secondary)
                                .foregroundStyle(.tertiary)
                        } else if let failure = status.failure {
                            Text(failure.advice)
                                .font(Token.Typography.secondary)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }

                if let reason = model.uplink.lastSwitchReason {
                    Text(reason)
                        .font(Token.Typography.note)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = model.uplink.lastError {
                    Text(error)
                        .font(Token.Typography.note)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    Task { await model.activateConfiguredTransport() }
                } label: {
                    Label("重新探测", systemImage: "arrow.clockwise")
                }

                // 专门测 iroh 兜底用：跳过档位探测，直接走 iroh。
                // 不然要测它就得先去关手机的 VPN / sing-box 让网关档"恰好"失败。
                Button {
                    Task { await runIrohFallbackProbe() }
                } label: {
                    HStack {
                        Label("强制用 iroh 兜底试一次", systemImage: "bolt.horizontal.circle")
                        Spacer()
                        if isRunningIrohFallback { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(isRunningIrohFallback)

                if let irohFallbackResult {
                    Text(irohFallbackResult)
                        .font(Token.Typography.secondary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("多路接入")
            } footer: {
                Text("地址清单来自电脑端的配对串，探测全不通时还会用 Bonjour 找一次电脑现在的地址。RTT 是最近一次探测的结果，「—」表示这次没测到（另一档先通了，或当前网络下不可达）。")
            }
        }
    }

    /// 多路接入模式下"当前用哪一档"。
    ///
    /// 网关档全不可达时会落到 iroh —— 那时 `currentTier` 是 nil，但**连接是好的**。
    /// 直接显示"未选档"会让人以为没连上，所以这里要如实说是 iroh 兜底。
    /// 手动触发一次 iroh 兜底，并把结果落到界面上。
    private func runIrohFallbackProbe() async {
        isRunningIrohFallback = true
        irohFallbackResult = nil
        defer { isRunningIrohFallback = false }
        let failure = await model.forceIrohFallback()
        irohFallbackResult = failure.map { String(localized: "没连上：\($0)") }
            ?? String(localized: "iroh 兜底已连上")
    }

    /// 「iroh 兜底」那一行的主文案。
    private var irohStatusLabel: String {
        switch model.irohStatus {
        case .pairedByComputer: return String(localized: "已配对（电脑端确认）")
        case .pairedLocally: return String(localized: "已配对（本地记录）")
        case .unpaired: return String(localized: "未配对")
        }
    }

    private var currentTierLabel: String {
        if let kind = model.uplink.currentTier?.kind { return kind.resolvedLabel }
        if model.connection.isConnected { return String(localized: "iroh 兜底") }
        return String(localized: "未选档")
    }

    private var transportSection: some View {
        Section {
            Button {
                Task { await model.refreshSessions() }
            } label: {
                Label("重新拉会话列表", systemImage: "arrow.clockwise")
            }
            if let hostId = model.settings.activeHostId, !hostId.isEmpty {
                Button {
                    Task { await model.connect(hostId: hostId, pairingCode: nil) }
                } label: {
                    Label("重连电脑", systemImage: "bolt.horizontal")
                }
            }
        } header: {
            Text("动作")
        } footer: {
            Text("连不上时先看电脑端：sidecar 进程在不在、DSH 是否还在 127.0.0.1:19387、系统「本地网络」权限是否放行。")
        }
    }

    // MARK: 自检

    private var selfCheckSection: some View {
        Section {
            Button {
                Task { await runSelfCheck() }
            } label: {
                HStack {
                    Label("跑一次协议自检", systemImage: "checklist")
                    Spacer()
                    if isRunningSelfCheck { ProgressView().controlSize(.small) }
                }
            }
            .disabled(isRunningSelfCheck || !model.connection.isConnected)

            ForEach(selfCheck) { result in
                HStack(alignment: .top, spacing: Token.Spacing.tight) {
                    Image(systemName: result.symbol)
                        .foregroundStyle(result.tone.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.title).font(Token.Typography.sectionTitle)
                        Text(result.detail)
                            .font(Token.Typography.secondary)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("协议自检")
        } footer: {
            Text("自检直接打 DSH 的客户端协议（unary + 流），不经过界面。宿主升级后出问题，先看这里。")
        }
    }

    // MARK: 日志

    private var logSection: some View {
        Section {
            Toggle("显示全部日志", isOn: $showsRawLog)
            let visible = showsRawLog ? logEntries : Array(logEntries.suffix(12))
            if visible.isEmpty {
                Text("还没有日志。").foregroundStyle(.secondary)
            }
            ForEach(visible) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Token.Spacing.hairline) {
                        Text(entry.level.label)
                            .font(Token.Typography.identifier)
                            .foregroundStyle(color(for: entry.level))
                        Text(Format.time(entry.time))
                            .font(Token.Typography.identifier)
                            .foregroundStyle(.tertiary)
                    }
                    Text(entry.message)
                        .font(Token.Typography.identifier)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("最近日志")
        } footer: {
            Text("日志只留在本机内存里，不会外发；要给别人看就手动导出。")
        }
    }

    // MARK: 自检实现

    private func runSelfCheck() async {
        isRunningSelfCheck = true
        selfCheck = []
        defer { isRunningSelfCheck = false }

        // 1) unary
        do {
            let sessions = try await model.client.listSessions()
            selfCheck.append(.init(
                title: String(localized: "unary · session/list"),
                detail: String(localized: "拿到 \(sessions.count) 个会话"),
                tone: .success,
                symbol: "checkmark.circle.fill"
            ))

            // 2) 流 · $events
            if let target = sessions.first(where: { !$0.sessionId.hasPrefix("im:") }) {
                var sawSnapshot = false
                var count = 0
                do {
                    for try await frame in model.client.follow(sessionId: target.sessionId, assistantStream: false) {
                        if case .snapshot(let snapshot) = frame {
                            sawSnapshot = true
                            count = snapshot.events.count
                        }
                        if sawSnapshot { break }
                    }
                    selfCheck.append(.init(
                        title: String(localized: "流 · session/follow"),
                        detail: sawSnapshot
                            ? String(localized: "快照 \(count) 条事件")
                            : String(localized: "没有收到快照"),
                        tone: sawSnapshot ? .success : .failure,
                        symbol: sawSnapshot ? "checkmark.circle.fill" : "xmark.octagon.fill"
                    ))
                } catch {
                    selfCheck.append(.init(
                        title: String(localized: "流 · session/follow"),
                        detail: (error as? DSHClientError)?.displayMessage ?? error.localizedDescription,
                        tone: .failure,
                        symbol: "xmark.octagon.fill"
                    ))
                }
            }
        } catch {
            selfCheck.append(.init(
                title: String(localized: "unary · session/list"),
                detail: (error as? DSHClientError)?.displayMessage ?? error.localizedDescription,
                tone: .failure,
                symbol: "xmark.octagon.fill"
            ))
        }

        logEntries = await model.logs.snapshot()
    }

    // MARK: 辅助

    private var tone: StatusTone {
        switch model.connection {
        case .connected: return model.muxState.isHealthy ? .success : .warning
        case .connecting: return .info
        case .failed: return .failure
        case .idle: return .neutral
        }
    }

    private var muxLabel: String {
        switch model.muxState {
        case .idle: return String(localized: "未开始")
        case .connecting: return String(localized: "连接中")
        case .connected: return String(localized: "已连接")
        case .disconnected(let reason): return String(localized: "已断开：\(reason)")
        }
    }

    private var pathLabel: String {
        guard let diagnostics = model.diagnostics else { return String(localized: "未连接") }
        return diagnostics.isDirect
            ? String(localized: "直连（打洞成功）")
            : String(localized: "中转（仅密文）")
    }

    private var exportText: String {
        var lines: [String] = [String(localized: "# DSH Pocket 诊断"), ""]
        lines.append(String(localized: "状态：\(model.connection.label)"))
        if let transportHealthy {
            lines.append(String(localized: "传输层：\(transportHealthy ? "健康" : "未连接")"))
        }
        lines.append(String(localized: "mux：\(muxLabel)"))
        if model.settings.transportMode == .uplink {
            lines.append(String(localized: "档位：\(currentTierLabel)"))
            lines.append(String(localized: "网络：\(model.uplink.networkKind.resolvedLabel)"))
            lines.append(String(localized: "网关：\(model.uplink.currentTier?.url.absoluteString ?? "—")"))
            lines.append(String(localized: "本地代理：\(model.uplink.baseURL?.absoluteString ?? "—")"))
            for status in model.uplink.tierStatuses {
                let state = status.rttMilliseconds.map { "\($0)ms" }
                    ?? status.skipReason
                    ?? status.failure?.logLabel
                    ?? "—"
                lines.append("\(status.tier.kind.rawValue) \(status.tier.url.absoluteString) \(state)")
            }
        }
        if let diagnostics = model.diagnostics {
            lines.append(String(localized: "路径：\(pathLabel)"))
            lines.append(String(localized: "代理：\(diagnostics.proxyURL ?? "—")"))
            lines.append(String(localized: "RTT：\(diagnostics.rttMilliseconds.map { "\($0)ms" } ?? "—")"))
            lines.append(String(localized: "绑定套接字：\(diagnostics.boundSockets.joined(separator: ", "))"))
        }
        lines.append(String(localized: "设备 ID：\(model.localEndpointId)"))
        lines.append("")
        lines.append(String(localized: "## 日志"))
        lines.append(contentsOf: logEntries.map { "[\($0.level.label)] \($0.message)" })
        return lines.joined(separator: "\n")
    }

    private func color(for level: DSHLogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .accentColor
        case .warning: return .orange
        case .error: return .red
        }
    }
}
