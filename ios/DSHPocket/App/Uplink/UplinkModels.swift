import CryptoKit
import Foundation
import Security
import SwiftUI

/// 多路接入（uplink）的**纯数据层**：配对串、档位、错误。
///
/// 协议真源在 `packages/dsh-plugin-uplink/lib/descriptor.js`（配对串）与
/// `lib/auth.js`（HMAC 换票）。这里只做客户端侧的解析与校验：
/// **任何不合规都返回 nil / 抛可读错误，绝不崩** —— 用户粘贴错东西是常态
/// （电脑端 `decodePairingPayload` 也是这么定的：不抛，只报原因）。
///
/// 这一层刻意不碰网络、不碰 UserDefaults：它要能在单测里被反复构造。

// MARK: - 档位

/// 一个档位 = "这台电脑能从哪个地址到达"。
///
/// 优先级是**产品决策**（电脑端 `config.js` 的 `TIER_PRIORITY` 是同一份决策）：
/// 局域网最快、虚拟组网次之、自建中转再次、iroh 兜底。手机侧不改顺序，
/// 只决定"允许用哪几档"。
public enum UplinkTierKind: String, CaseIterable, Identifiable, Sendable {
    case lan
    case tailscale
    case zerotier
    case frp
    /// iroh 是**兜底路径**，不经过 HTTP 网关 —— 它由 TetherKit 走隧道，
    /// 所以探测时跳过。留在枚举里是因为配对串/清单里会出现这个 kind。
    case iroh

    public var id: String { rawValue }

    /// 数值越小越优先（与电脑端 `priorityOf` 一致）。
    public var priority: Int {
        switch self {
        case .lan: return 10
        case .tailscale: return 20
        case .zerotier: return 30
        case .frp: return 40
        case .iroh: return 50
        }
    }

    /// 真正参与 HTTP 探测的档位。iroh 不在其中（见上）。
    public static let networkKinds: [UplinkTierKind] = [.lan, .tailscale, .zerotier, .frp]

    public var label: LocalizedStringKey {
        switch self {
        case .lan: return "局域网"
        case .tailscale: return "Tailscale"
        case .zerotier: return "ZeroTier"
        case .frp: return "自建中转"
        case .iroh: return "iroh"
        }
    }

    /// 已解析的字符串（理由同 `TransportMode.resolvedLabel`：
    /// `LocalizedStringKey` 不能插进另一个 `LocalizedStringKey`）。
    public var resolvedLabel: String {
        switch self {
        case .lan: return String(localized: "局域网")
        case .tailscale: return String(localized: "Tailscale")
        case .zerotier: return String(localized: "ZeroTier")
        case .frp: return String(localized: "自建中转")
        case .iroh: return String(localized: "iroh")
        }
    }

    public var symbol: String {
        switch self {
        case .lan: return "wifi"
        case .tailscale: return "network"
        case .zerotier: return "circle.grid.cross"
        case .frp: return "server.rack"
        case .iroh: return "point.3.connected.trianglepath.dotted"
        }
    }

    /// 从地址**猜**档位。
    ///
    /// 配对串里只有 `urls: ["http://…"]` 一串地址、没有 kind（见 `descriptor.js`），
    /// 所以手机侧只能按地址段反推。规则故意保守：
    ///
    /// | 地址 | 判成 |
    /// |---|---|
    /// | `127.*` / `localhost` / `10.*` / `172.16-31.*` / `192.168.*` / `169.254.*` / `*.local` | 局域网 |
    /// | `100.64.0.0/10` / `*.ts.net` | Tailscale |
    /// | 其余（公网 IP、公网域名） | 自建中转 |
    ///
    /// **ZeroTier 分不出来**：它常用 10.x / 172.16-31，和家里局域网重叠。
    /// 所以内网段一律先算「局域网」，并在 `UplinkTier.kinds` 里把 ZeroTier
    /// 一起列进去 —— 过滤时"两档里任一开着就用"，两档都关才真的跳过。
    /// 要做到逐档精确，得让电脑端在配对串里带上 kind（协议改动，不在这条线）。
    public static func infer(from url: URL) -> UplinkTierKind {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return .lan }
        if host == "localhost" { return .lan }
        if host.hasSuffix(".local") { return .lan }
        if host.hasSuffix(".ts.net") { return .tailscale }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            // 公网域名（frp 域名之类）
            return .frp
        }
        if octets[0] == 100, (64...127).contains(octets[1]) { return .tailscale }
        if octets[0] == 127 { return .lan }
        if octets[0] == 10 { return .lan }
        if octets[0] == 172, (16...31).contains(octets[1]) { return .lan }
        if octets[0] == 192, octets[1] == 168 { return .lan }
        if octets[0] == 169, octets[1] == 254 { return .lan }
        return .frp
    }
}

/// 一个可探测的地址。
public struct UplinkTier: Sendable, Equatable, Hashable, Identifiable {
    /// 主档位（用于展示、RTT 归类、`HostCoordinator.Mode`）。
    public let kind: UplinkTierKind
    public let url: URL

    public var id: String { "\(kind.rawValue)|\(url.absoluteString)" }

    public init(kind: UplinkTierKind, url: URL) {
        self.kind = kind
        self.url = url
    }

    /// 按地址猜档位并构造。地址不合法时返回 nil。
    public init?(urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // 容忍没写 scheme 的写法（`10.0.0.5:18788`）—— 与网关地址的容错保持一致。
        let normalized = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let url = URL(string: normalized), url.host != nil else { return nil }
        self.init(kind: UplinkTierKind.infer(from: url), url: url)
    }

    /// 这个地址可能属于哪几档（过滤开关时用；见 `UplinkTierKind.infer` 的说明）。
    public var kinds: Set<UplinkTierKind> {
        switch kind {
        case .lan: return [.lan, .zerotier]
        case .tailscale: return [.tailscale]
        case .frp: return [.frp]
        case .zerotier: return [.zerotier]
        case .iroh: return [.iroh]
        }
    }
}

// MARK: - 配对串

/// `dshuplink://` + base64url(JSON)。
///
/// 内容是**一次性**的设备身份（deviceId + secret）加上"此刻算出来的地址清单"。
/// 手机存下 secret，之后所有档位都用它换票；地址过期了也不影响
/// （换网后重新拉清单 / 重新配对）。
public struct UplinkPairing: Sendable, Equatable {
    public static let scheme = "dshuplink://"
    /// 协议版本。电脑端 `DESCRIPTOR_VERSION = 1`。
    public static let version = 1

    public let hostId: String
    public let name: String
    public let port: Int
    public let deviceId: String
    /// 32 字节、64 位十六进制。**只存在两端**（电脑 0600 文件 / 手机 Keychain）。
    public let secret: String
    public let urls: [String]
    /// 电脑端在配对串里带的**档位名**（`tiers: [{kind, url}]`）。
    ///
    /// 有它才能逐档精确：局域网与 ZeroTier 常用同一个私有网段，只靠地址段
    /// 反推永远分不开，"关掉 ZeroTier 但保留局域网"就做不到。
    /// 老版本电脑端不发这个字段，那时退化成按地址猜（见 `tiers`）。
    public let hintedTiers: [UplinkTier]
    /// iroh 兜底档的 endpointId（`iroh: {endpointId, relay}`）。
    ///
    /// 为什么必须有它：降级到 iroh 时如果还用 `settings.activeHostId`
    /// （上一次 tether 配对留下的旧身份），电脑端重装/换机之后那个 id 已经不存在了，
    /// 每一轮都要白等 15 秒超时。配对串里的这个值才是**这台电脑现在**的身份。
    public let irohEndpointId: String?
    public let irohRelay: String?
    /// 配对串里带的**一次性 iroh 配对码**（`iroh.code`）。
    ///
    /// 为什么把码放进配对串：iroh 是"所有网关档都不可达"时的兜底，如果它自己还要
    /// 先有票（票据只能在网关档可达时换到）才能要码，那就是个死锁 ——
    /// 5G + 局域网不可达时永远用不上 iroh。码随串一起下发，配对走 iroh 通道本身，
    /// **不需要任何 HTTP 请求**。
    public let irohCode: String?
    /// 码的过期时间（毫秒时间戳）。过期的码不要拿去试 —— 电脑端会记一次失败。
    public let irohExpiresAt: Int64?
    public let issuedAt: Int64

    /// 校验构造。任何一项不合规都返回 nil。
    public init?(
        hostId: String,
        name: String,
        port: Int,
        deviceId: String,
        secret: String,
        urls: [String],
        hintedTiers: [UplinkTier] = [],
        irohEndpointId: String? = nil,
        irohRelay: String? = nil,
        irohCode: String? = nil,
        irohExpiresAt: Int64? = nil,
        issuedAt: Int64
    ) {
        let host = hostId.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = secret.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty, !device.isEmpty else { return nil }
        // 与电脑端 decodePairingPayload 的 /^[0-9a-f]{64}$/i 对齐
        guard key.count == 64, key.allSatisfy({ $0.isHexDigit }) else { return nil }
        self.hostId = host
        self.name = name
        self.port = port
        self.deviceId = device
        self.secret = key
        self.urls = urls.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        self.hintedTiers = hintedTiers
        let endpoint = irohEndpointId?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.irohEndpointId = (endpoint?.isEmpty == false) ? endpoint : nil
        let relay = irohRelay?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.irohRelay = (relay?.isEmpty == false) ? relay : nil
        let code = irohCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.irohCode = (code?.isEmpty == false) ? code : nil
        self.irohExpiresAt = irohExpiresAt
        self.issuedAt = issuedAt
    }

    /// 配对码是否已经过期。没有 `expiresAt` 时**按未过期处理**（老配对串没这个字段，
    /// 拿它去试一次才知道行不行 —— 总比直接拒绝强）。
    public func irohCodeExpired(now: Date) -> Bool {
        guard let irohExpiresAt, irohExpiresAt > 0 else { return false }
        return Double(irohExpiresAt) / 1000 <= now.timeIntervalSince1970
    }

    /// 能不能"就地"配 iroh（不需要任何 HTTP）：有 endpointId 和码，且码没过期。
    public func canPairIroh(now: Date) -> Bool {
        irohEndpointId != nil && irohCode != nil && !irohCodeExpired(now: now)
    }

    /// 把"新发现到的地址"并进配对材料（回写用）。
    ///
    /// 老配对串没有 `tiers`（只有 `urls`）时**继续只写 `urls`** —— 那台电脑端
    /// 不认识带 kind 的清单，硬塞进去反而会让它下次解析出不一致的东西。
    public func merging(tiers extra: [UplinkTier]) -> UplinkPairing {
        guard !extra.isEmpty else { return self }
        let known = Set((hintedTiers.isEmpty ? urls : hintedTiers.map { $0.url.absoluteString })
            .map { Self.normalized($0) })
        let fresh = extra.filter { !known.contains(Self.normalized($0.url.absoluteString)) }
        guard !fresh.isEmpty else { return self }
        return UplinkPairing(
            hostId: hostId,
            name: name,
            port: port,
            deviceId: deviceId,
            secret: secret,
            urls: urls + fresh.map { $0.url.absoluteString },
            hintedTiers: hintedTiers.isEmpty ? [] : hintedTiers + fresh,
            irohEndpointId: irohEndpointId,
            irohRelay: irohRelay,
            irohCode: irohCode,
            irohExpiresAt: irohExpiresAt,
            issuedAt: issuedAt
        ) ?? self
    }

    /// 地址比较用的规范化形式：去掉结尾的 `/`、统一小写。
    /// `http://10.0.0.5:18788` 与 `http://10.0.0.5:18788/` 是同一个地址。
    static func normalized(_ url: String) -> String {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    /// 可探测的档位。
    ///
    /// 优先用电脑端给的 `tiers`（带 kind，逐档精确）；没有时才按地址段猜 ——
    /// 那种情况下 ZeroTier 会被算成局域网，由 `UplinkTier.kinds` 兜住
    /// （两档任一开着就用）。
    public var tiers: [UplinkTier] {
        let resolved = hintedTiers.isEmpty
            ? urls.compactMap { UplinkTier(urlString: $0) }
            : hintedTiers.filter { $0.kind != .iroh }
        return resolved.sorted { $0.kind.priority < $1.kind.priority }
    }

    /// 给人看的电脑名。空名字退回 hostId 前 8 位（比"未命名"有用）。
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(hostId.prefix(8)) : trimmed
    }

    /// 解析配对串。**容忍前后空白**（用户从聊天窗口复制常带换行），
    /// scheme 大小写不敏感；其余任何不合规返回 nil。
    public static func parse(_ text: String) -> UplinkPairing? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.lowercased().hasPrefix(scheme) else { return nil }
        let payload = String(trimmed.dropFirst(scheme.count))
        guard let data = UplinkBase64.decode(payload) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let v = json["v"] as? Int, v == version else { return nil }
        guard let hostId = json["hostId"] as? String else { return nil }
        guard let deviceId = json["deviceId"] as? String else { return nil }
        guard let secret = json["secret"] as? String else { return nil }
        let urls = (json["urls"] as? [Any])?.compactMap { $0 as? String } ?? []
        // 认不出的 kind 直接丢：宁可少一档，也别把一个不知道优先级的地址塞进探测列表。
        let hintedTiers = (json["tiers"] as? [Any] ?? []).compactMap { item -> UplinkTier? in
            guard let dict = item as? [String: Any],
                  let kindRaw = dict["kind"] as? String,
                  let kind = UplinkTierKind(rawValue: kindRaw),
                  let url = dict["url"] as? String,
                  let tier = UplinkTier(urlString: url)
            else { return nil }
            return UplinkTier(kind: kind, url: tier.url)
        }
        let iroh = json["iroh"] as? [String: Any]
        return UplinkPairing(
            hostId: hostId,
            name: json["name"] as? String ?? "",
            port: json["port"] as? Int ?? 0,
            deviceId: deviceId,
            secret: secret,
            urls: urls,
            hintedTiers: hintedTiers,
            // endpointId 缺失就当没有 —— 别猜、也别用 relay 顶替。
            irohEndpointId: iroh?["endpointId"] as? String,
            irohRelay: iroh?["relay"] as? String,
            irohCode: iroh?["code"] as? String,
            // JSONSerialization 会把整数给成 Int（64 位上够装毫秒时间戳），
            // 但服务端如果用浮点写（`1792670400000.0`）就会是 Double —— 两种都收。
            irohExpiresAt: (iroh?["expiresAt"] as? Int).map(Int64.init)
                ?? (iroh?["expiresAt"] as? Double).map { Int64($0) },
            issuedAt: Int64(json["issuedAt"] as? Int ?? 0)
        )
    }

    /// 反解出来的配对串。**测试与调试用**：真实配对串由电脑端生成，
    /// 手机侧永远不会自己签发。
    public func encodedString() -> String {
        var payload: [String: Any] = [
            "v": Self.version,
            "hostId": hostId,
            "name": name,
            "port": port,
            "deviceId": deviceId,
            "secret": secret,
            "urls": urls,
            "issuedAt": issuedAt,
        ]
        if !hintedTiers.isEmpty {
            payload["tiers"] = hintedTiers.map { ["kind": $0.kind.rawValue, "url": $0.url.absoluteString] }
        }
        if let irohEndpointId {
            var iroh: [String: Any] = ["endpointId": irohEndpointId]
            if let irohRelay { iroh["relay"] = irohRelay }
            if let irohCode { iroh["code"] = irohCode }
            if let irohExpiresAt { iroh["expiresAt"] = irohExpiresAt }
            payload["iroh"] = iroh
        }
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        return Self.scheme + UplinkBase64.encode(data)
    }
}

// MARK: - 换票

/// 挑战-应答里的 HMAC。
///
/// 协议（`auth.js` 的 `proofFor`）：
/// `proof = hex(HMAC-SHA256(key = hex(secret), "auth|deviceId|ts|nonce"))`
///
/// 为什么用 CryptoKit 而不是自己拼 CommonCrypto：系统自带、没有第三方依赖，
/// 且 `SymmetricKey` 会尽量不把密钥落到堆上。
public enum UplinkCrypto {
    /// 计算应答。secret 不是 64 位十六进制时返回 nil（不该发生，但别崩）。
    public static func proof(secret: String, deviceId: String, ts: Int64, nonce: String) -> String? {
        guard let key = hexData(secret) else { return nil }
        let message = Data("auth|\(deviceId)|\(ts)|\(nonce)".utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key))
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// 十六进制字符串 → 字节。长度为奇数或含非十六进制字符时返回 nil。
    public static func hexData(_ hex: String) -> Data? {
        let scalars = Array(hex.lowercased().utf8)
        guard scalars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(scalars.count / 2)
        var index = 0
        while index < scalars.count {
            guard let high = nibble(scalars[index]), let low = nibble(scalars[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        return Data(bytes)
    }

    private static func nibble(_ scalar: UInt8) -> UInt8? {
        switch scalar {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return scalar - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return scalar - UInt8(ascii: "a") + 10
        default: return nil
        }
    }

    /// 随机 nonce（32 位十六进制）。电脑端要求 8~128 个字符、且同窗口内不重复。
    public static func makeNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // 拿不到安全随机数时退回 UUID —— 退化的熵仍远好于"固定 nonce"（那会立刻被重放拒绝）
            return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - base64url

/// base64url（RFC 4648 §5）：`-` `_`，无填充。配对串与票据都用它。
enum UplinkBase64 {
    static func decode(_ string: String) -> Data? {
        var text = string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // 电脑端生成的是**无填充**形式；Foundation 要求长度是 4 的倍数。
        while text.count % 4 != 0 { text += "=" }
        return Data(base64Encoded: text)
    }

    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - iroh 配对窗口

/// 一次 iroh 配对窗口（`POST /uplink/iroh-pairing` 的返回）。
///
/// 电脑端回的是 `<endpointId>#<6 位码>`。**码只有几分钟有效期**，所以它不能存 ——
/// 用掉就该扔（`TetherSession` 配对成功后会把这台电脑记进主机簿，下次直接 hello）。
public struct UplinkIrohPairing: Sendable, Equatable {
    public let endpointId: String
    public let code: String
    /// 窗口还剩多少秒（电脑端给的，600 是默认值）。
    public let expiresInSec: Int

    /// 解析电脑端给的 `pairingString`。
    ///
    /// 以 `pairingString` 为准、`endpointId` 字段只作交叉校验：真正能连的是
    /// "码 + 这个 endpoint"这一对，两者对不上时宁可不信（返回 nil 让上层报错），
    /// 也不要拿一个连不上的组合去白试 20 秒。
    public init?(pairingString: String, endpointId: String?, expiresInSec: Int) {
        let trimmed = pairingString.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let endpoint = String(parts[0]).trimmingCharacters(in: .whitespaces)
        let code = String(parts[1]).trimmingCharacters(in: .whitespaces)
        guard !endpoint.isEmpty, !code.isEmpty else { return nil }
        if let declared = endpointId?.trimmingCharacters(in: .whitespaces), !declared.isEmpty,
           declared != endpoint {
            return nil
        }
        self.endpointId = endpoint
        self.code = code
        self.expiresInSec = expiresInSec
    }
}

/// 换 iroh 配对窗口时的失败。
public enum UplinkIrohPairingError: Error, Equatable, Sendable {
    /// 电脑端没跑 iroh 档（`503 iroh-unavailable`）。
    /// **这一档就是不可用** —— 别重试，重试只会打出一串 503。
    case unavailable
    /// 手上没有可用票据（当前一个地址都不通，或还没换过票）。
    /// 如实报错：没有票就换不到配对码，假装在重试没有意义。
    case noTicket
    /// 状态码意外 / 响应看不懂。
    case failed(String)
}

extension UplinkIrohPairingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return String(localized: "电脑端没有启用 iroh 兜底档。")
        case .noTicket:
            return String(localized: "现在一个地址都不通，换不到 iroh 配对码。请先回到能连上这台电脑的网络。")
        case .failed(let reason):
            return String(localized: "换 iroh 配对码失败：\(reason)")
        }
    }
}

// MARK: - 探测结果

/// 一次探测的结果。
///
/// 为什么不是 `Int?`：`nil` 把"超时""被拒""根本没网""对面是别的电脑"全糊成一种，
/// 而它们的修法完全不同（换网络 / 起网关 / 开权限 / 重新配对）。
/// 真机排障时只有一句"所有档位都探测失败"，等于什么都没说。
public enum UplinkProbeResult: Sendable, Equatable {
    case reachable(rttMilliseconds: Int)
    case unreachable(UplinkProbeFailure)

    public var rtt: Int? {
        if case .reachable(let rtt) = self { return rtt }
        return nil
    }

    public var failure: UplinkProbeFailure? {
        if case .unreachable(let failure) = self { return failure }
        return nil
    }
}

/// 探测失败的原因。分类是**主要目的**，文案只是它的投影。
public enum UplinkProbeFailure: Sendable, Equatable {
    /// 超时：多半不在同一网络、iOS「本地网络」权限没开，或者 VPN 把包吞了。
    case timedOut(milliseconds: Int)
    /// 地址可达但连接被拒：端口没在监听（网关没起），或者被防火墙挡了。
    case refused(milliseconds: Int)
    /// 手机自己就没网（飞行模式、蜂窝关了、Wi-Fi 没连上）。
    case offline(milliseconds: Int)
    /// 名字解析不到（DNS / mDNS）。
    case unknownHost(milliseconds: Int)
    /// 地址通了，但对面是**另一台**电脑（`hostId` 对不上）。
    case hostMismatch(milliseconds: Int)
    /// 其余：TLS 失败、5xx、响应不是 JSON……
    case other(milliseconds: Int, reason: String)

    /// 粗分类。`summary(for:)` 与诊断页都按它分支。
    public enum Category: String, Sendable, Equatable {
        case timeout, refused, offline, dns, mismatch, other
    }

    public var category: Category {
        switch self {
        case .timedOut: return .timeout
        case .refused: return .refused
        case .offline: return .offline
        case .unknownHost: return .dns
        case .hostMismatch: return .mismatch
        case .other: return .other
        }
    }

    public var milliseconds: Int {
        switch self {
        case .timedOut(let ms), .refused(let ms), .offline(let ms),
             .unknownHost(let ms), .hostMismatch(let ms), .other(let ms, _):
            return ms
        }
    }

    /// 日志里的形状：`timedOut(832ms)`。**不本地化** —— 排障时要能直接 grep
    /// URLError 的语义，翻成中文反而对不上系统日志。
    public var logLabel: String {
        switch self {
        case .timedOut(let ms): return "timedOut(\(ms)ms)"
        case .refused(let ms): return "refused(\(ms)ms)"
        case .offline(let ms): return "offline(\(ms)ms)"
        case .unknownHost(let ms): return "unknownHost(\(ms)ms)"
        case .hostMismatch(let ms): return "hostMismatch(\(ms)ms)"
        case .other(let ms, let reason): return "error(\(reason))(\(ms)ms)"
        }
    }

    /// 给用户的一句话（含"下一步该做什么"）。诊断页逐档显示。
    public var advice: String {
        switch self {
        case .timedOut:
            return String(localized: "超时：可能不在同一网络、iOS「本地网络」权限没开，或者 VPN 拦了请求。")
        case .refused:
            return String(localized: "连接被拒：地址是通的，但那个端口上没有服务（电脑端网关没起，或被防火墙挡了）。")
        case .offline:
            return String(localized: "手机当前没有网络连接。")
        case .unknownHost:
            return String(localized: "解析不到这个地址（DNS / mDNS 没回应）。")
        case .hostMismatch:
            return String(localized: "这个地址上是另一台电脑，不是已配对的那台。")
        case .other(_, let reason):
            return String(localized: "探测失败：\(reason)")
        }
    }

    /// 把 `URLError` 归到上面几类。
    ///
    /// 映射表是按 iOS 实测的错误码写的：`URLSession` 在"同网段但端口没开"时给
    /// `.cannotConnectToHost`（不是 `.timedOut`），在"本地网络权限没给"时给
    /// `.timedOut`（iOS 静默丢包），两者必须分开，否则用户会照着错的建议去改。
    public init(urlError: URLError, milliseconds: Int) {
        switch urlError.code {
        case .timedOut:
            self = .timedOut(milliseconds: milliseconds)
        case .cannotConnectToHost:
            self = .refused(milliseconds: milliseconds)
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
             .internationalRoamingOff, .callIsActive:
            self = .offline(milliseconds: milliseconds)
        case .cannotFindHost, .dnsLookupFailed:
            self = .unknownHost(milliseconds: milliseconds)
        default:
            self = .other(milliseconds: milliseconds, reason: "\(urlError.code.rawValue)")
        }
    }

    /// 整体失败时的一句话：**按最可执行的那一类给建议**。
    ///
    /// 优先级是 offline → timeout → refused → dns：
    /// "手机没网"能解释其余一切，先说它才不会被后面那些噪音带偏。
    public static func summary(for failures: [UplinkProbeFailure]) -> String {
        guard !failures.isEmpty else {
            return String(localized: "没有可探测的地址。")
        }
        let count = String(failures.count)
        let categories = Set(failures.map(\.category))
        if categories.contains(.offline) {
            return String(localized: "\(count) 个地址都没试通：手机现在没有网络。先确认 Wi-Fi 或蜂窝数据是开的。")
        }
        if categories.contains(.timeout) {
            return String(localized: "\(count) 个地址都超时了：可能不在同一网络、iOS「本地网络」权限没开，或者 VPN 把请求劫持了。")
        }
        if categories.contains(.refused) {
            return String(localized: "\(count) 个地址都拒绝连接：电脑上的网关可能没在跑，或者被防火墙挡了。")
        }
        if categories.contains(.dns) {
            return String(localized: "\(count) 个地址都解析不到：多半是 DNS 或 VPN 的问题。")
        }
        if categories.contains(.mismatch) {
            return String(localized: "\(count) 个地址上都不是已配对的那台电脑，请重新配对。")
        }
        return String(localized: "\(count) 个地址都不通，原因见下方每一档的说明。")
    }
}

// MARK: - 错误

/// 多路接入的错误。**每一种都给一句可执行的话** —— 这一层离用户最近。
public enum UplinkError: Error, Equatable, Sendable {
    /// 还没配对（没有配对串）。
    case notPaired
    /// 配对串解析失败。
    case badPairing
    /// 没有可用档位（全被关掉、或全部探测失败）。
    case noTierAvailable
    /// 探测通了，但对面不是配对串里那台电脑。
    case hostMismatch(expected: String, got: String)
    /// 换票被拒（`401`：密钥被撤销、时钟偏差过大、nonce 重放、限流）。
    case unauthorized(String)
    /// 票据用不了（重换一次之后仍然 401）。
    case ticketRejected(String)
    /// 非 200 的响应。
    case http(status: Int)
    /// 网络层失败。
    case transport(String)
    /// 响应不是预期的 JSON。
    case badResponse(String)
}

extension UplinkError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notPaired:
            return String(localized: "还没有配对这台电脑。请让电脑端显示配对串，然后粘贴到这里。")
        case .badPairing:
            return String(localized: "配对串认不出来。它应该以 dshuplink:// 开头，后面是一整段字符 —— 别只复制半截。")
        case .noTierAvailable:
            return String(localized: "所有档位都连不上。检查手机和电脑是否在同一网络，或者换一个档位再试。")
        case .hostMismatch(let expected, let got):
            return String(localized: "这个地址上是另一台电脑（期望 \(expected.prefix(8))…，实际 \(got.prefix(8))…），已跳过。")
        case .unauthorized(let reason):
            return String(localized: "电脑拒绝了这台手机（\(reason)）。多半是电脑端重装过插件或清过配对数据，重新配一次就好。")
        case .ticketRejected(let reason):
            return String(localized: "票据被拒（\(reason)）。请在电脑端确认这台设备还在授权列表里。")
        case .http(let status):
            return String(localized: "电脑回了一个意外的状态码 \(String(status))。")
        case .transport(let message):
            return String(localized: "连不上：\(message)")
        case .badResponse(let message):
            return String(localized: "电脑回的响应看不懂：\(message)")
        }
    }
}
