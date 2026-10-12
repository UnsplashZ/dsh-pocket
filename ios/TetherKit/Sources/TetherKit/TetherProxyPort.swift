import Foundation

/// 派生本地代理端口。**必须与电脑端公式一致**：
///
/// ```rust
/// fn proxy_port_for(peer: &EndpointId) -> u16 {
///     let b = peer.as_bytes();
///     20000 + u16::from_be_bytes([b[0], b[1]]) % 12000      // 20000..31999
/// }
/// ```
///
/// 为什么按主机派生而不是随机取：同一台主机的代理 origin 稳定，
/// URLSession 的连接复用与凭据上下文才一致，调试也可复现。
/// 范围 20000–31999 避开了 iOS 临时端口区（49152 起）。
public enum TetherProxyPort {
    public static let minimum: UInt16 = 20_000
    public static let span: UInt16 = 12_000

    /// 从 64 位十六进制的端点 ID 派生端口。解析失败时退回 `minimum`（仍可用，只是不保证稳定）。
    public static func port(for endpointId: String) -> UInt16 {
        guard let bytes = bytes(fromHex: endpointId), bytes.count >= 2 else {
            return minimum
        }
        let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        return minimum + raw % span
    }

    /// 十六进制字符串 → 字节。非法字符返回 nil（不做"尽力而为"的解析，否则端口会静默漂移）。
    public static func bytes(fromHex hex: String) -> [UInt8]? {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard cleaned.count % 2 == 0, !cleaned.isEmpty else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}

/// 配对串：`<endpointId>#<6 位码>`，以及只含密码的输入。
///
/// 用户可能从剪贴板粘整串、可能只粘 ID、也可能手输 6 位码，
/// 这三种输入都要能识别 —— 但**不要把码回显**给用户。
public struct TetherPairingCode: Sendable, Equatable {
    public var endpointId: String?
    public var code: String

    public init(endpointId: String?, code: String) {
        self.endpointId = endpointId
        self.code = code
    }

    /// 解析任意粘贴内容。
    /// - 支持 `id#code`、`id code`、`id\ncode`、纯 6 位码、纯 64 位 ID（配合已保存主机）。
    public static func parse(_ text: String) -> TetherPairingCode? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let separators = CharacterSet(charactersIn: "#\n\r\t ")
        let parts = trimmed.components(separatedBy: separators).filter { !$0.isEmpty }

        var endpointId: String?
        var code: String?

        for part in parts {
            if isEndpointId(part) { endpointId = part.lowercased() }
            else if isSixDigitCode(part) { code = part }
        }

        // 只有 ID、没有码：交给已保存主机簿去补码。
        if let endpointId, code == nil {
            return TetherPairingCode(endpointId: endpointId, code: "")
        }
        guard let code else { return nil }
        return TetherPairingCode(endpointId: endpointId, code: code)
    }

    public static func isEndpointId(_ text: String) -> Bool {
        guard text.count == 64 else { return false }
        return text.allSatisfy { $0.isHexDigit }
    }

    public static func isSixDigitCode(_ text: String) -> Bool {
        guard text.count == 6 else { return false }
        return text.allSatisfy(\.isNumber)
    }
}

/// 一个已配对主机。
public struct TetherHostRecord: Sendable, Codable, Identifiable, Equatable {
    public var id: String            // endpointId（64 hex）
    public var label: String         // 用户起的名字
    public var lastConnectedAt: Date?
    public var lastPathKind: String? // "direct" / "relay"

    public init(id: String, label: String, lastConnectedAt: Date? = nil, lastPathKind: String? = nil) {
        self.id = id
        self.label = label
        self.lastConnectedAt = lastConnectedAt
        self.lastPathKind = lastPathKind
    }

    public var shortId: String { String(id.prefix(12)) }
}

/// 主机簿的存储位置（与 DSHKit 无关，但两端都用同一套目录约定）。
public enum TetherStorage {
    public static func directory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let url = base.appendingPathComponent("DSHPocket", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static func file(_ name: String) -> URL {
        directory().appendingPathComponent(name)
    }
}
