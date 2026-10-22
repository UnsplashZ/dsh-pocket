// swift-tools-version:5.9
import PackageDescription

// uplink-e2e —— 在 Mac 上直接跑一个真的 DLP 客户端，用来验证 iroh 档位端到端。
//
// 为什么值得单独做一个可执行文件：手机侧一时半会儿验不了（没 Wi-Fi / 装不上），
// 而 iroh 这条路只要"客户端 ↔ sidecar"能通就算通。TetherKit 支持 macOS 14.5，
// Iroh.xcframework 也带 macos-arm64 切片，所以同一套客户端代码能在 Mac 上直接跑。
//
// 用法：swift run -c release uplink-e2e '<endpointId>#<code>'
let package = Package(
    name: "uplink-e2e",
    platforms: [.macOS("14.5")],
    dependencies: [
        .package(path: "../../ios/TetherKit"),
    ],
    targets: [
        .executableTarget(
            name: "uplink-e2e",
            dependencies: [.product(name: "TetherKit", package: "TetherKit")]
        ),
    ]
)
