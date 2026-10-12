// swift-tools-version:5.9
import PackageDescription

// M0b 互通 spike：证书上是"Swift 客户端能否连上你正在跑的那个 tether sidecar"。
//
// 它故意**同时**依赖两层的真实代码（TetherKit + DSHKit），所以跑通一次等于证明：
//   iroh-ffi(Swift) ↔ 宿主 iroh 1.0.3 → DLP 配对 → 代理流 → 本地 TCP 代理
//   → DSHKit 的 RPC / mux / session/list → 真实数据
// 一整条链路，中途没有任何桩。
let package = Package(
    name: "m0b-interop",
    platforms: [.macOS("14.5")],
    dependencies: [
        .package(path: "../../TetherKit"),
        .package(path: "../../DSHKit"),
    ],
    targets: [
        .executableTarget(
            name: "m0b-interop",
            dependencies: [
                .product(name: "TetherKit", package: "TetherKit"),
                .product(name: "DSHKit", package: "DSHKit"),
            ],
            path: "Sources/m0b-interop"
        ),
    ]
)
