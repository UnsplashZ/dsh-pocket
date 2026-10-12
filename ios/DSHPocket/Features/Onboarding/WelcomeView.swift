import DSHKit
import SwiftUI
import TetherKit

/// 首次启动的说明页。
///
/// 按 IOS-DESIGN §9：**如实写清**这个 App 会连接你自己的电脑、凭证与数据都在你自己的机器上，
/// 以及两条已知安全边界。不做营销腔，也不藏边界。
struct WelcomeView: View {
    let onDone: () -> Void

    @Environment(AppModel.self) private var model
    @State private var page = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    page_(.one).tag(0)
                    page_(.two).tag(1)
                    page_(.three).tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))

                VStack(spacing: Token.Spacing.tight) {
                    Button {
                        if page < 2 {
                            withAnimation { page += 1 }
                        } else {
                            model.settings.hasOnboarded = true
                            onDone()
                        }
                    } label: {
                        Text(page < 2 ? "继续" : "开始使用")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    if page < 2 {
                        Button("跳过") {
                            model.settings.hasOnboarded = true
                            onDone()
                        }
                        .font(.footnote)
                    }
                }
                .padding(Token.Spacing.section)
            }
            .navigationTitle("DSH Pocket")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private enum Page { case one, two, three }

    @ViewBuilder
    private func page_(_ which: Page) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Token.Spacing.section) {
                switch which {
                case .one:
                    hero(
                        symbol: "iphone.gen3",
                        title: String(localized: "把电脑上的会话带到手机上"),
                        body: String(localized: "原生 SwiftUI 界面，直接和电脑上的 DSH 说话：看时间线、发消息、批审批、看产物。不经过任何第三方服务器。")
                    )
                    bulletList([
                        ("bubble.left.and.bubble.right", String(localized: "会话时间线，流式追加"), String(localized: "工具调用折叠成一行，点开看参数与输出")),
                        ("checkmark.shield", String(localized: "审批在你的手机上决定"), String(localized: "电脑上有操作要你批准时会推到你面前")),
                        ("folder", String(localized: "浏览工作区文件"), String(localized: "用系统 QuickLook 预览，不下载到别处")),
                    ])

                case .two:
                    hero(
                        symbol: "lock.shield",
                        title: String(localized: "你的数据只在你的设备之间"),
                        body: String(localized: "手机和电脑之间走点对点加密（iroh）。打洞成功时数据不经过任何第三方；回退中转时，中转只能看到密文。")
                    )
                    bulletList([
                        ("hand.raised", String(localized: "不采集分析数据"), String(localized: "没有遥测、没有账号、没有云端")),
                        ("externaldrive", String(localized: "凭证与内容都在你的电脑上"), String(localized: "这个 App 只是一个远程控制端")),
                        ("key", String(localized: "访问权由这台手机的公钥决定"), String(localized: "配对码 6 位、10 分钟、3 次尝试")),
                    ])

                case .three:
                    hero(
                        symbol: "exclamationmark.triangle",
                        title: String(localized: "两条如实告知的边界"),
                        body: String(localized: "安全声明只有在说清边界时才有意义。")
                    )
                    VStack(alignment: .leading, spacing: Token.Spacing.tight) {
                        Text("电脑端")
                            .font(.headline)
                        Text("已经能在你电脑上执行代码的人，可以伪造回环请求、自签配对码，把自己配成一台「手机」。所以不要把本 App 用在你同时跑不可信代码的电脑上。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: Token.Spacing.tight) {
                        Text("手机端")
                            .font(.headline)
                        Text("App 内的本地代理只监听 127.0.0.1，但手机上其它 App 可以连上它，而且端口能由主机 ID 推算出来。一期如实告知，后续会加进程内握手令牌。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(Token.Spacing.section)
        }
    }

    private func hero(symbol: String, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: Token.Spacing.compact) {
            Image(systemName: symbol)
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(title)
                .font(.largeTitle.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            Text(body)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bulletList(_ items: [(String, String, String)]) -> some View {
        VStack(alignment: .leading, spacing: Token.Spacing.compact) {
            ForEach(items, id: \.0) { item in
                HStack(alignment: .top, spacing: Token.Spacing.compact) {
                    Image(systemName: item.0)
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.1).font(.body.weight(.medium))
                        Text(item.2).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
