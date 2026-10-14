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
            transportSection
            selfCheckSection
            logSection
        }
        .navigationTitle("诊断")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.refreshDiagnostics()
            logEntries = await model.logs.snapshot()
        }
        .refreshable {
            await model.refreshDiagnostics()
            await model.refreshSessions()
            logEntries = await model.logs.snapshot()
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
                Text(message).font(.footnote).foregroundStyle(.red)
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
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
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
                        Text(result.title).font(.subheadline)
                        Text(result.detail)
                            .font(.caption)
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
                            .font(.caption2.monospaced())
                            .foregroundStyle(color(for: entry.level))
                        Text(Format.time(entry.time))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    Text(entry.message)
                        .font(.caption.monospaced())
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
        lines.append(String(localized: "mux：\(muxLabel)"))
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
