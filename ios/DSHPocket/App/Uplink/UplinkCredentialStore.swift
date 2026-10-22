import Foundation
import TetherKit

/// 配对材料的存放处。
///
/// 分两半，理由和 `TetherSecretStore` 的注释一样：
///   · **deviceId + secret 进 Keychain** —— 它是长期凭证，嗅到一次就是永久授权
///     （局域网是明文的，见 `auth.js` 开头的说明）。Keychain 用
///     `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`：解锁后可用、不随 iCloud 同步；
///   · 其余（hostId / 名字 / 地址清单 / 端口）进 `UserDefaults` —— 它们不是秘密，
///     清单本来就可以走明文（Bonjour 引导、二维码）。
///
/// 为什么密钥是**两条独立记录**而不是一个 JSON blob：Keychain 的读写粒度就是
/// "一条一个 item"，混在一起要么全进 Keychain（超小容量、频繁整块读写），
/// 要么全进 UserDefaults（密钥明文落盘）。分开最省事。
///
/// 注：`lastGood` 与粘滞窗口**不在这里** —— 它们由 `AppSettings` 持有
/// （它已经是 `UserDefaults` 的唯一写入口），这里不重复存一份，免得两处打架。
@MainActor
public final class UplinkCredentialStore {
    private enum Key {
        static let deviceId = "uplink.deviceId"
        static let secret = "uplink.secret"
        static let hostId = "uplink.hostId"
        static let hostName = "uplink.hostName"
        static let port = "uplink.port"
        static let urls = "uplink.urls"
        static let issuedAt = "uplink.issuedAt"
    }

    private let secrets: any TetherSecretStore
    private let defaults: UserDefaults

    public init(secrets: any TetherSecretStore, defaults: UserDefaults = .standard) {
        self.secrets = secrets
        self.defaults = defaults
    }

    /// 读回已配对的电脑。**任何一项缺失都当作"没配对"** —— 半个配对串比没有更危险
    /// （会用错误的 deviceId 去换票，然后被电脑端限流）。
    public func loadPairing() -> UplinkPairing? {
        guard let hostId = defaults.string(forKey: Key.hostId), !hostId.isEmpty else { return nil }
        guard let deviceId = secretString(Key.deviceId), let secret = secretString(Key.secret) else {
            return nil
        }
        return UplinkPairing(
            hostId: hostId,
            name: defaults.string(forKey: Key.hostName) ?? "",
            port: defaults.integer(forKey: Key.port),
            deviceId: deviceId,
            secret: secret,
            urls: defaults.stringArray(forKey: Key.urls) ?? [],
            issuedAt: Int64(defaults.double(forKey: Key.issuedAt))
        )
    }

    /// 落盘。写失败**不抛**：最坏情况是下次启动要重新粘贴一次配对串，
    /// 比在配对流程里弹一个用户看不懂的 Keychain 错误好。
    public func save(_ pairing: UplinkPairing) {
        defaults.set(pairing.hostId, forKey: Key.hostId)
        defaults.set(pairing.name, forKey: Key.hostName)
        defaults.set(pairing.port, forKey: Key.port)
        defaults.set(pairing.urls, forKey: Key.urls)
        defaults.set(Double(pairing.issuedAt), forKey: Key.issuedAt)
        try? secrets.write(Key.deviceId, Data(pairing.deviceId.utf8))
        try? secrets.write(Key.secret, Data(pairing.secret.utf8))
    }

    public func clear() {
        for key in [Key.hostId, Key.hostName, Key.port, Key.urls, Key.issuedAt] {
            defaults.removeObject(forKey: key)
        }
        try? secrets.delete(Key.deviceId)
        try? secrets.delete(Key.secret)
    }

    private func secretString(_ key: String) -> String? {
        guard let data = try? secrets.read(key), let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text.isEmpty ? nil : text
    }
}
