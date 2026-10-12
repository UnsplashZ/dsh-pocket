import Foundation
import IrohLib

/// 设备身份：一把持久的 iroh `SecretKey`。
///
/// 首次启动生成并存入 `TetherSecretStore`，之后复用。**不要**把它当"会话令牌"看 ——
/// 它就是设备的公钥身份，配对白名单认的是它，丢了就得重新配对。
public struct TetherIdentity: Sendable {
    public static let storageKey = "iroh-identity-key"

    public let secretKey: SecretKey
    public let endpointId: String

    public init(secretKey: SecretKey) {
        self.secretKey = secretKey
        self.endpointId = secretKey.public().description
    }

    /// 读已有身份，没有就生成一把并写回。
    public static func loadOrCreate(store: any TetherSecretStore) throws -> TetherIdentity {
        if let data = try store.read(storageKey), data.count == 32,
           let key = try? SecretKey.fromBytes(bytes: data) {
            return TetherIdentity(secretKey: key)
        }
        let key = SecretKey.generate()
        try store.write(storageKey, key.toBytes())
        return TetherIdentity(secretKey: key)
    }

    /// 换一把新身份（"重置设备身份"用；换完必须重新配对）。
    public static func reset(store: any TetherSecretStore) throws -> TetherIdentity {
        try? store.delete(storageKey)
        return try loadOrCreate(store: store)
    }
}

/// TetherKit 的错误。每一条都要能变成给用户看的一句话（见 docs/TRANSPORT.md §7）。
public enum TetherError: Error, Sendable {
    /// 还没配对。
    case notPaired
    /// 配对窗口没开 / 过期 / 错太多次 / 码不对。
    case pairingFailed(TetherPairFailure)
    /// 端点 ID 不是合法的 64 位十六进制。
    case invalidEndpointId(String)
    /// iroh 层失败（绑定、连接、流）。
    case transport(String)
    /// 本地代理端口起不来。
    case proxyUnavailable(String)
    /// 电脑端拒绝了代理流（多半是 sidecar 没配 `--proxy-target`）。
    case proxyRefused
    /// 控制流断了。
    case controlClosed(String)
}

extension TetherError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notPaired:
            return String(localized: "还没有和这台电脑配对")
        case .pairingFailed(let failure):
            return failure.localizedDescription
        case .invalidEndpointId(let value):
            return "端点 ID 不合法（应为 64 位十六进制）：\(value.prefix(16))"
        case .transport(let detail):
            return "连接失败：\(detail)"
        case .proxyUnavailable(let detail):
            return "本地代理启动失败：\(detail)"
        case .proxyRefused:
            return "电脑端拒绝了代理流（插件可能没在正常状态）"
        case .controlClosed(let detail):
            return "与电脑的连接已断开：\(detail)"
        }
    }
}

extension TetherPairFailure {
    /// 原因码 → 本地化文案。**永远不要把码本身显示给用户**。
    public var localizedDescription: String {
        switch self {
        case .noWindow:
            return String(localized: "电脑上没有开着的配对窗口。请在电脑上打开「连接手机」再试。")
        case .expired:
            return String(localized: "配对窗口已过期。请在电脑上重新打开「连接手机」。")
        case .tooManyAttempts:
            return String(localized: "配对码试错次数超限，窗口已关。请在电脑上重新打开「连接手机」。")
        case .badCode:
            return String(localized: "配对码不正确。")
        case .other(let raw):
            // 认不出的码原样显示，总好过吞掉。
            return raw
        }
    }
}
