import DSHKit
import SwiftUI
import TetherKit

/// S6 设置。`NavigationStack` + `Form`，分组按 IOS-DESIGN §4 S6。
struct SettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var showPairing = false
    @State private var renamingHost: TetherHostRecord?

    var body: some View {
        @Bindable var settings = model.settings

        NavigationStack {
            Form {
                hostsSection
                notificationsSection
                appearanceSection
                diagnosticsSection
                aboutSection
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showPairing) { PairingSheet() }
            .alert("重命名主机", isPresented: Binding(
                get: { renamingHost != nil },
                set: { if !$0 { renamingHost = nil } }
            )) {
                RenameHostAlert(host: renamingHost, model: model, onDone: { renamingHost = nil })
                    .onAppear { _ = renamingHost }
            }
        }
    }

    // MARK: 主机

    private var hostsSection: some View {
        Section {
            if model.hosts.isEmpty {
                Text("还没有配对过任何电脑。")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.hosts) { host in
                Button {
                    Task { await model.connect(hostId: host.id, pairingCode: nil) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(host.label).font(.body).foregroundStyle(.primary)
                            Text(host.shortId)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if model.settings.activeHostId == host.id, model.connection.isConnected {
                            StatusBadge("当前", symbol: "checkmark.circle.fill", tone: .success)
                        }
                    }
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button(role: .destructive) {
                        Task { await model.forgetHost(host.id) }
                    } label: {
                        Label("忘记", systemImage: "trash")
                    }
                    Button {
                        renamingHost = host
                    } label: {
                        Label("重命名", systemImage: "pencil")
                    }
                }
            }
            Button {
                showPairing = true
            } label: {
                Label("添加电脑", systemImage: "qrcode")
            }
        } header: {
            Text("主机")
        } footer: {
            if !model.localEndpointId.isEmpty {
                Text("这台手机的设备 ID：\(String(model.localEndpointId.prefix(16)))…\n电脑端按这把公钥授权；删掉它需要重新配对。")
            }
        }
    }

    // MARK: 通知

    private var notificationsSection: some View {
        @Bindable var settings = model.settings

        return Section {
            Toggle(isOn: Binding(
                get: { settings.notifications.approvals },
                set: { newValue in
                    settings.notifications.approvals = newValue
                    requestAuthorizationIfNeeded()
                }
            )) {
                Label("等待审批", systemImage: "exclamationmark.bubble")
            }
            Toggle(isOn: Binding(
                get: { settings.notifications.questions },
                set: { newValue in
                    settings.notifications.questions = newValue
                    requestAuthorizationIfNeeded()
                }
            )) {
                Label("等你回答", systemImage: "questionmark.bubble")
            }
            Toggle(isOn: Binding(
                get: { settings.notifications.completions },
                set: { newValue in
                    settings.notifications.completions = newValue
                    requestAuthorizationIfNeeded()
                }
            )) {
                Label("一轮跑完", systemImage: "checkmark.circle")
            }
        } header: {
            Text("通知")
        } footer: {
            Text("只在打开开关时才向系统申请通知权限。App 退到后台会断开与电脑的连接（iOS 不允许常驻），所以通知是本地提醒，不是实时推送。")
        }
    }

    private func requestAuthorizationIfNeeded() {
        guard model.settings.notifications.anyEnabled else { return }
        Task<Void, Never> { _ = await model.requestNotificationAuthorization() }
    }

    // MARK: 外观

    private var appearanceSection: some View {
        @Bindable var settings = model.settings

        return Section("外观") {
            Picker("主题", selection: $settings.appearance) {
                ForEach(AppearancePreference.allCases) { preference in
                    Label(preference.label, systemImage: preference.symbol).tag(preference)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            Toggle(isOn: $settings.showRawEvents) {
                Label("显示模型可见的原始事件", systemImage: "curlybraces")
            }
        }
    }

    // MARK: 诊断

    private var diagnosticsSection: some View {
        Section("诊断") {
            NavigationLink {
                DiagnosticsView()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("连接与协议")
                        Text(model.connection.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "stethoscope")
                }
            }
        }
    }

    // MARK: 关于

    private var aboutSection: some View {
        Section {
            LabeledContent("版本", value: Bundle.main.shortVersion)
            LabeledContent("协议", value: "DSH 0.2.0-rc.2")
            LabeledContent("传输", value: "iroh 1.1.0 · ALPN dsh-tether/0")

            NavigationLink {
                LicenseView()
            } label: {
                Label("第三方组件与许可", systemImage: "doc.text.magnifyingglass")
            }
            NavigationLink {
                PrivacyView()
            } label: {
                Label("隐私与安全边界", systemImage: "lock.shield")
            }
        } header: {
            Text("关于")
        } footer: {
            Text("DSH Pocket 是独立社区项目，与 DeepSeek 官方无隶属关系。")
        }
    }
}

/// 主机重命名的输入框（单独一个视图，避免在 alert 里做绑定地狱）。
private struct RenameHostAlert: View {
    let host: TetherHostRecord?
    let model: AppModel
    let onDone: () -> Void

    @State private var text = ""

    @ViewBuilder
    var body: some View {
        TextField("名称", text: $text)
        Button("取消", role: .cancel) { onDone() }
        Button("保存") {
            if let host {
                Task { await model.renameHost(host.id, label: text) }
            }
            onDone()
        }
    }
}

// MARK: - 许可

struct LicenseView: View {
    private let components: [(String, String, String)] = [
        ("iroh / iroh-ffi", "n0-computer", "MIT / Apache-2.0"),
        ("dsh-plugin-tether", "zexadev", "MIT"),
        ("DSH_Mobile 协议文档", "jayantTang", "MIT"),
        ("DeepSeek Harness", "deepseek-ai", "上游协议，不改源码"),
    ]

    var body: some View {
        List {
            Section {
                ForEach(components, id: \.0) { component in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(component.0).font(.body.weight(.medium))
                        Text(component.1).font(.caption).foregroundStyle(.secondary)
                        Text(component.2).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    }
                }
            } footer: {
                Text("本项目以 MIT 许可发布。以上组件各自保留原许可与版权声明。")
            }
        }
        .navigationTitle("第三方组件")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 隐私

struct PrivacyView: View {
    var body: some View {
        List {
            Section("我们做什么") {
                bullet("不采集任何分析数据，不联网发送遥测。", symbol: "hand.raised")
                bullet("所有流量都发往你自己已配对的电脑。", symbol: "arrow.left.arrow.right")
                bullet("凭证与数据都在你自己的机器上。", symbol: "externaldrive")
            }

            Section {
                Text("电脑端的已知边界")
                    .font(.headline)
                Text("已经能在你电脑上执行代码的人，可以伪造回环 Host 通过栅栏、自签配对码，把自己配成一台「手机」。")
            } footer: {
                Text("所以：**不要把本 App 用在你同时跑不可信代码的电脑上。**")
            }

            Section {
                Text("手机端的已知边界")
                    .font(.headline)
                Text("App 内的本地代理只监听 127.0.0.1，但手机上其它 App 可以连上它，而且端口可以由主机 ID 推算出来。")
            } footer: {
                Text("一期如实告知；后续可加一个进程内的随机握手令牌（需要电脑端配合）。")
            }

            Section("端到端加密") {
                bullet("打洞成功时数据不经过任何第三方。", symbol: "point.3.connected.trianglepath.dotted")
                bullet("回退中转时，中转只能看到密文。", symbol: "lock.fill")
                bullet("配对码 6 位、10 分钟、3 次尝试；配对后访问权由这台手机的公钥决定。", symbol: "key")
            }
        }
        .navigationTitle("隐私与安全边界")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func bullet(_ text: String, symbol: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
    }
}

extension Bundle {
    var shortVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
