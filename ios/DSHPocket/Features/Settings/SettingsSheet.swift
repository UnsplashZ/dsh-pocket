import DSHKit
import SwiftUI
import TetherKit

/// S6 设置。`NavigationStack` + `Form`，分组按 IOS-DESIGN §4 S6。
struct SettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var showPairing = false
    @State private var renamingHost: TetherHostRecord?

    // 这三个是**功能**状态，不是调试状态，所以必须在 DEBUG 之外：
    // 缓存页会读 `cacheStats`，电脑设置那个 sheet 会绑另外两个。
    // （它们曾经被一起放进下面的 `#if DEBUG` 里 —— Debug 编得过、Release 编不过，
    //  而本仓库对外发的未签名 IPA 正是 Release 构建。）
    @State private var showHostSettings = false
    @State private var showHostSettingsFromDebug = false
    @State private var cacheStats: (sessions: Int, bytes: Int) = (0, 0)

    #if DEBUG
    /// 调试用：`defaults write cc.unsplashz.dshpocket DSHShowArchived -bool YES` 直接打开归档页。
    @State private var showArchived = false
    #endif

    var body: some View {
        @Bindable var settings = model.settings

        NavigationStack {
            Form {
                #if DEBUG
                developerModeSection
                #endif
                hostsSection
                hostSettingsSection
                cacheSection
                archivedSection
                notificationsSection
                appearanceSection
                remindersSection
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
            // **必须挂在最外层**，不能挂在 `Section` 上。
            // 挂在 section 上时，`connection` 一变（重连）整个 Form 重建、
            // section 的身份跟着变，已经呈现的 sheet 会被拆掉 ——
            // 表现就是"点一次菜单自己缩回去，得再点一次"（实测）。
            .sheet(isPresented: $showHostSettings) { HostSettingsView() }
            .sheet(isPresented: $showHostSettingsFromDebug) { HostSettingsView() }
            #if DEBUG
            .sheet(isPresented: $showArchived) {
                NavigationStack { ArchivedSessionsView() }
            }
            .task {
                if UserDefaults.standard.bool(forKey: "DSHShowArchived") { showArchived = true }
                if UserDefaults.standard.bool(forKey: "DSHShowHostSettings") { showHostSettingsFromDebug = true }
            }
            #endif
            .alert("重命名主机", isPresented: Binding(
                get: { renamingHost != nil },
                set: { if !$0 { renamingHost = nil } }
            )) {
                RenameHostAlert(host: renamingHost, model: model, onDone: { renamingHost = nil })
                    .onAppear { _ = renamingHost }
            }
        }
    }

    #if DEBUG
    // MARK: 开发者模式提示

    /// 连接方式已经不在设置页里暴露（产品上默认且只用 iroh）。
    /// 但开发者仍可用 defaults 打开另两种模式 —— 没有这块的话，
    /// 改完 defaults 之后界面上没有任何地方能看出来，也没法改回去。
    @ViewBuilder
    private var developerModeSection: some View {
        if model.settings.transportMode != .remote {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "开发者模式：") + model.settings.transportMode.resolvedLabel)
                        Text("正常使用请改回「远端连接（iroh）」")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "hammer")
                }
                Button("改回 iroh") {
                    model.settings.transportMode = .remote
                    Task { await model.activateConfiguredTransport() }
                }
            } header: {
                Text("调试")
            }
        }
    }
    #endif

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
                            StatusBadge(String(localized: "当前"), symbol: "checkmark.circle.fill", tone: .success)
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

    // MARK: 已归档

    private var archivedSection: some View {
        Section {
            NavigationLink {
                ArchivedSessionsView()
            } label: {
                Label {
                    HStack {
                        Text("已归档的会话")
                        Spacer()
                        if !model.archivedSessions.isEmpty {
                            // 纯数字：用 String 而不是插值字面量，
                            // 否则它会变成一条没有意义的本地化 key（"%lld"）。
                            Text(String(model.archivedSessions.count))
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "archivebox")
                }
            }
        } footer: {
            Text("归档过的会话不会出现在对话列表里，在这里可以恢复或重新打开。")
        }
    }

    // MARK: 电脑设置

    @ViewBuilder
    private var hostSettingsSection: some View {
        Section {
            Button {
                showHostSettings = true
            } label: {
                LabeledContent {
                    Text(model.connection.isConnected ? "" : String(localized: "未连接"))
                        .foregroundStyle(.secondary)
                } label: {
                    Label("电脑设置", systemImage: "desktopcomputer")
                }
            }
            .disabled(!model.connection.isConnected)
        } footer: {
            Text("在手机上改**电脑上**的配置：插件开关、新会话的默认模型与思考等级。其余设置在电脑上改更合适。")
        }
    }

    // MARK: 缓存

    @ViewBuilder
    private var cacheSection: some View {
        Section {
            LabeledContent("已缓存会话", value: "\(cacheStats.sessions)")
            LabeledContent("占用空间", value: ByteCountFormatter.string(fromByteCount: Int64(cacheStats.bytes), countStyle: .file))
            Button("清空缓存", role: .destructive) {
                Task {
                    await model.clearSessionCache()
                    cacheStats = await model.cacheStatistics()
                }
            }
        } header: {
            Text("缓存")
        } footer: {
            Text("会话内容会缓存在本机，切回之前的会话时不用再等一次远程加载。缓存放在系统可回收的位置，随时可以清空 —— 清空只影响速度，不会丢任何东西。")
        }
        .task {
            cacheStats = await model.cacheStatistics()
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

            Toggle(isOn: $settings.expandReasoningByDefault) {
                Label("默认展开思考过程", systemImage: "brain")
            }

            // 字号**只影响会话内容** —— 跟桌面端一致。
            // 全局放大会把设置页和导航栏一起撑开，反而更难用。
            Picker(selection: $settings.fontScale) {
                ForEach(FontScale.allCases, id: \.self) { scale in
                    Text(scale.label).tag(scale)
                }
            } label: {
                Label("会话字号", systemImage: "textformat.size")
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: 定时提醒

    private var remindersSection: some View {
        Section {
            NavigationLink {
                RemindersView()
            } label: {
                Label("定时提醒", systemImage: "bell.badge")
            }
        } footer: {
            Text("让电脑到点自己干件事。新建要在会话里发 `/schedule`。")
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
        (String(localized: "DSH_Mobile 协议文档"), "jayantTang", "MIT"),
        ("DeepSeek Harness", "deepseek-ai", String(localized: "上游协议，不改源码")),
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
                bullet(String(localized: "不采集任何分析数据，不联网发送遥测。"), symbol: "hand.raised")
                bullet(String(localized: "所有流量都发往你自己已配对的电脑。"), symbol: "arrow.left.arrow.right")
                bullet(String(localized: "凭证与数据都在你自己的机器上。"), symbol: "externaldrive")
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
                bullet(String(localized: "打洞成功时数据不经过任何第三方。"), symbol: "point.3.connected.trianglepath.dotted")
                bullet(String(localized: "回退中转时，中转只能看到密文。"), symbol: "lock.fill")
                bullet(String(localized: "配对码 6 位、10 分钟、3 次尝试；配对后访问权由这台手机的公钥决定。"), symbol: "key")
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
