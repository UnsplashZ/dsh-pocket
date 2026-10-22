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
        /// 电脑端给的档位名（`tiers: [{kind, url}]`）。**必须持久化**：
        /// 不存的话重启之后只剩 `urls`，ZeroTier 会被重新推断成局域网，
        /// "关掉 ZeroTier 保留局域网"就失效了。
        static let tiers = "uplink.tiers"
        /// iroh 兜底档的 endpointId / relay。同样必须持久化 ——
        /// 它决定"降级到 iroh 时连谁"，丢了就只能退回那个已经失效的旧身份。
        static let irohEndpointId = "uplink.irohEndpointId"
        static let irohRelay = "uplink.irohRelay"
        /// 配对串里带的一次性码 + 过期时间。**必须持久化**：用户粘完配对串
        /// 未必当场就能把 iroh 配上（比如那次 App 被杀了），重启后码还在就能补上。
        static let irohCode = "uplink.irohCode"
        static let irohExpiresAt = "uplink.irohExpiresAt"
        /// Bonjour 发现到的地址（带时间戳）。**不进 Keychain**：地址不是秘密，
        /// 而且它变化频繁，Keychain 那种"一次写入长期不动"的用法并不合适。
        static let discovered = "uplink.discovered"
        static let discoveredAt = "uplink.discoveredAt"
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
        let hintedTiers = Self.tiers(from: defaults.array(forKey: Key.tiers))
        return UplinkPairing(
            hostId: hostId,
            name: defaults.string(forKey: Key.hostName) ?? "",
            port: defaults.integer(forKey: Key.port),
            deviceId: deviceId,
            secret: secret,
            urls: defaults.stringArray(forKey: Key.urls) ?? [],
            hintedTiers: hintedTiers,
            irohEndpointId: defaults.string(forKey: Key.irohEndpointId),
            irohRelay: defaults.string(forKey: Key.irohRelay),
            irohCode: defaults.string(forKey: Key.irohCode),
            irohExpiresAt: (defaults.object(forKey: Key.irohExpiresAt) as? Double).map { Int64($0) },
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
        defaults.set(pairing.hintedTiers.map { ["kind": $0.kind.rawValue, "url": $0.url.absoluteString] },
                     forKey: Key.tiers)
        if let endpoint = pairing.irohEndpointId {
            defaults.set(endpoint, forKey: Key.irohEndpointId)
        } else {
            defaults.removeObject(forKey: Key.irohEndpointId)
        }
        if let relay = pairing.irohRelay {
            defaults.set(relay, forKey: Key.irohRelay)
        } else {
            defaults.removeObject(forKey: Key.irohRelay)
        }
        if let code = pairing.irohCode {
            defaults.set(code, forKey: Key.irohCode)
        } else {
            defaults.removeObject(forKey: Key.irohCode)
        }
        if let expiresAt = pairing.irohExpiresAt {
            defaults.set(Double(expiresAt), forKey: Key.irohExpiresAt)
        } else {
            defaults.removeObject(forKey: Key.irohExpiresAt)
        }
        try? secrets.write(Key.deviceId, Data(pairing.deviceId.utf8))
        try? secrets.write(Key.secret, Data(pairing.secret.utf8))
    }

    /// 记下这次 Bonjour 发现的地址。带时间戳是为了让调用方判断"还新不新" ——
    /// DHCP 续租、换 SSID 之后旧地址会静默失效，太老的缓存不该再当候选。
    public func saveDiscovered(_ tiers: [UplinkTier], at date: Date) {
        guard !tiers.isEmpty else { return }
        defaults.set(tiers.map { ["kind": $0.kind.rawValue, "url": $0.url.absoluteString] },
                     forKey: Key.discovered)
        defaults.set(date.timeIntervalSince1970, forKey: Key.discoveredAt)
    }

    public func loadDiscovered() -> (tiers: [UplinkTier], at: Date)? {
        guard let stamp = defaults.object(forKey: Key.discoveredAt) as? Double, stamp > 0 else {
            return nil
        }
        let tiers = Self.tiers(from: defaults.array(forKey: Key.discovered))
        guard !tiers.isEmpty else { return nil }
        return (tiers, Date(timeIntervalSince1970: stamp))
    }

    public func clearDiscovered() {
        defaults.removeObject(forKey: Key.discovered)
        defaults.removeObject(forKey: Key.discoveredAt)
    }

    public func clear() {
        for key in [Key.hostId, Key.hostName, Key.port, Key.urls, Key.issuedAt,
                    Key.tiers, Key.irohEndpointId, Key.irohRelay, Key.irohCode, Key.irohExpiresAt,
                    Key.discovered, Key.discoveredAt] {
            defaults.removeObject(forKey: key)
        }
        try? secrets.delete(Key.deviceId)
        try? secrets.delete(Key.secret)
    }

    /// `[[kind, url]]` → 档位。
    ///
    /// 先转成 `[[String: Any]]` 再逐字段取：直接 `as? [[String: String]]` 在
    /// UserDefaults 返回 NSDictionary 时**可能静默失败**（返回 nil，于是"配对还在、
    /// 地址却全没了"），这种坑不值得省两行。
    private static func tiers(from raw: [Any]?) -> [UplinkTier] {
        (raw ?? []).compactMap { item -> UplinkTier? in
            guard let dict = item as? [String: Any],
                  let kindRaw = dict["kind"] as? String,
                  let kind = UplinkTierKind(rawValue: kindRaw),
                  let urlText = dict["url"] as? String,
                  let url = URL(string: urlText) else { return nil }
            return UplinkTier(kind: kind, url: url)
        }
    }

    private func secretString(_ key: String) -> String? {
        guard let data = try? secrets.read(key), let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text.isEmpty ? nil : text
    }
}
