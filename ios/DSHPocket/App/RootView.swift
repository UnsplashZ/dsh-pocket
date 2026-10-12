import DSHKit
import SwiftUI

/// 导航架构（docs/IOS-DESIGN.md §3）：
///
/// ```
/// RootView
///  ├─ iPhone  NavigationStack(path:)
///  │     ├─ SessionListView        大标题；按工作区分组
///  │     └─ SessionView            时间线 + 底部输入区
///  ├─ iPad    NavigationSplitView
///  │     ├─ sidebar: SessionListView
///  │     └─ detail:  SessionView 或 ContentUnavailableView("选择一个会话")
///  └─ 模态（全部用系统 sheet）
///        PairingSheet / SettingsSheet / FilesSheet / 首次启动说明页
/// ```
///
/// 规则：**不自绘导航栏、不做抽屉/汉堡菜单、不抢系统手势**。返回手势与转场一律系统默认。
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var path: [SessionSummary] = []
    @State private var showPairing = false
    @State private var showSettings = false
    @State private var showWelcome = false

    var body: some View {
        @Bindable var model = model

        Group {
            if horizontalSizeClass == .regular {
                splitLayout
            } else {
                stackLayout
            }
        }
        .sheet(isPresented: $showPairing) {
            PairingSheet()
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
        }
        .sheet(isPresented: $showWelcome) {
            WelcomeView { showWelcome = false }
                .interactiveDismissDisabled()
        }
        .task {
            if !model.settings.hasOnboarded { showWelcome = true }
            await openDebugSessionIfRequested()
        }
    }

    // MARK: iPhone

    private var stackLayout: some View {
        NavigationStack(path: $path) {
            SessionListView(
                onSelect: { path.append($0) },
                onPair: { showPairing = true },
                onSettings: { showSettings = true }
            )
            .navigationDestination(for: SessionSummary.self) { summary in
                SessionView(summary: summary)
            }
        }
    }

    // MARK: iPad

    private var splitLayout: some View {
        NavigationSplitView {
            SessionListView(
                onSelect: { selection = $0 },
                onPair: { showPairing = true },
                onSettings: { showSettings = true }
            )
            .navigationTitle("会话")
        } detail: {
            if let selection {
                SessionView(summary: selection)
            } else {
                ContentUnavailableView(
                    "选择一个会话",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("在左侧选一个会话开始；也可以下拉刷新列表。")
                )
            }
        }
    }

    @State private var selection: SessionSummary?

    #if DEBUG
    /// 调试用深链：`-DSHOpenSessionId <id>` 直接打开某个会话。
    /// 让"截一张时间线的图"这种验证不必依赖 UI 自动化点按。
    private func openDebugSessionIfRequested() async {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "DSHShowSettings") { showSettings = true }
        if defaults.bool(forKey: "DSHShowWelcome") { showWelcome = true }
        guard let sessionId = defaults.string(forKey: "DSHOpenSessionId"), !sessionId.isEmpty else { return }
        // 列表可能还没拉回来，等一拍
        for _ in 0..<20 {
            if let summary = model.sessions.first(where: { $0.sessionId == sessionId }) {
                path = [summary]
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
            await model.refreshSessions()
        }
    }
    #else
    private func openDebugSessionIfRequested() async {}
    #endif
}
