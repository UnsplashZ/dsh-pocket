// swift-tools-version:5.9
import PackageDescription

// DSHKit —— DSH 客户端协议层。
//
// 设计约束（见 docs/DESIGN.md §4）：
//   · 不知道 iroh、不知道 SwiftUI、不 import UIKit/AppKit；
//   · 只依赖 Foundation + URLSession，因此可以在 macOS 上直接 `swift test`；
//   · 所有"宿主可能扩展"的负载用 JSONValue 承载，解码器只对**信封**严格。
let package = Package(
    name: "DSHKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "DSHKit", targets: ["DSHKit"]),
    ],
    targets: [
        .target(
            name: "DSHKit",
            path: "Sources/DSHKit",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "DSHKitTests",
            dependencies: ["DSHKit"],
            path: "Tests/DSHKitTests"
        ),
    ]
)
