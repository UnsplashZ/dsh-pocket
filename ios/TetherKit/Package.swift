// swift-tools-version:5.9
import PackageDescription

// TetherKit —— iroh 官方 Swift 绑定（IrohLib）+ DLP 线协议 + 本地 TCP 代理。
//
// 设计约束（见 docs/TRANSPORT.md）：
//   · 只暴露"给一个 DSHEndpoint 拿一个可用的本地 http 基址"这一件事；
//   · 计算机（Mac）侧用的 dsh-plugin-tether 一行不改；
//   · 平台要求 17.5 / 14.5 来自 IrohLib 自身（其 Package.swift 声明 .iOS("17.5")）。
let package = Package(
    name: "TetherKit",
    platforms: [
        .iOS("17.5"),
        .macOS("14.5"),
    ],
    products: [
        .library(name: "TetherKit", targets: ["TetherKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/n0-computer/iroh-ffi.git", exact: "1.1.0"),
    ],
    targets: [
        .target(
            name: "TetherKit",
            dependencies: [
                .product(name: "IrohLib", package: "iroh-ffi"),
            ],
            path: "Sources/TetherKit"
        ),
        .testTarget(
            name: "TetherKitTests",
            dependencies: ["TetherKit"],
            path: "Tests/TetherKitTests"
        ),
    ]
)
