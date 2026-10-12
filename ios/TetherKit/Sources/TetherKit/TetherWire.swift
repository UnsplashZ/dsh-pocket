import Foundation

/// DLP（DSH Link Protocol）v1 的线协议消息。
///
/// 契约真源：`dsh-tether/tether-core/src/lib.rs` 的 `Wire` 枚举。
/// 一连接**一条控制 bi 流**，JSON-lines（`\n` 结尾）；控制流建立之后，
/// 同一连接的**后续每条 bi 流都是代理流**（首行 `{"type":"proxy"}`，之后是原始字节）。
public enum TetherWire {
    /// ALPN，电脑端硬编码，必须一致。
    public static let alpn = "dsh-tether/0"
    /// 控制流单行上限（电脑端 `MAX_LINE`）。
    public static let maxLine = 64 * 1024
    /// 未配对连接首行上限（电脑端 `MAX_UNPAIRED_LINE`）—— 所以 `name` 要短。
    public static let maxUnpairedLine = 512
    /// 设备名在配对串里的长度上限。超过就会被电脑端拒绝（首行 512 字节）。
    public static let maxDeviceNameLength = 40

    /// 手机 → 电脑：连接已配对电脑的首行。
    public static func hello(name: String) -> Data {
        encode(["type": "hello", "name": trimmed(name)])
    }

    /// 手机 → 电脑：首次配对的首行。
    public static func pair(code: String, name: String) -> Data {
        encode(["type": "pair", "code": code, "name": trimmed(name)])
    }

    /// 手机 → 电脑：代理流的首行。
    public static var proxy: Data {
        encode(["type": "proxy"])
    }

    /// 手机 → 电脑：对一个审批请求的决定。
    public static func decision(id: String, outcome: String) -> Data {
        encode(["type": "decision", "id": id, "outcome": outcome])
    }

    private static func trimmed(_ name: String) -> String {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > maxDeviceNameLength else { return cleaned }
        return String(cleaned.prefix(maxDeviceNameLength))
    }

    private static func encode(_ object: [String: String]) -> Data {
        var data = Data()
        // 手写而不是 JSONSerialization：字段少、要 deterministic、且不能有空格。
        let body = object.keys.sorted().map { key in
            "\"\(key)\":\"\(escape(object[key] ?? ""))\"" 
        }.joined(separator: ",")
        data.append(Data(("{\(body)}\n").utf8))
        return data
    }

    private static func escape(_ value: String) -> String {
        var out = ""
        for character in value.unicodeScalars {
            switch character {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if character.value < 0x20 {
                    out += String(format: "\\u%04x", character.value)
                } else {
                    out.unicodeScalars.append(character)
                }
            }
        }
        return out
    }
}

/// 电脑端发来的一条消息。
public enum TetherHostMessage: Sendable, Equatable {
    case pairOk
    case pairFail(reason: String)
    case approval(id: String, toolName: String, reason: String)
    case approvalCancel(id: String)
    /// 认不出的消息（电脑端可能更新）。原样带着，便于诊断页展示与日志。
    case unknown(type: String, raw: String)

    public static func decode(line: String) -> TetherHostMessage? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return nil }

        switch type {
        case "pair-ok":
            return .pairOk
        case "pair-fail":
            return .pairFail(reason: object["reason"] as? String ?? "")
        case "approval":
            guard let id = object["id"] as? String else { return nil }
            return .approval(
                id: id,
                toolName: object["toolName"] as? String ?? "",
                reason: object["reason"] as? String ?? ""
            )
        case "approval-cancel":
            guard let id = object["id"] as? String else { return nil }
            return .approvalCancel(id: id)
        default:
            return .unknown(type: type, raw: line)
        }
    }
}

/// 配对失败的原因码。**线上只传码，由客户端本地化**
/// （电脑端 0.1.16 及更早会直接发中文句子，认不出的原样显示）。
public enum TetherPairFailure: Sendable, Equatable {
    case noWindow
    case expired
    case tooManyAttempts
    case badCode
    /// 电脑端给了我们不认识的原因（老版本发的是人话，原样带出）。
    case other(String)

    public init(reason: String) {
        switch reason {
        case "no-window": self = .noWindow
        case "expired": self = .expired
        case "too-many-attempts": self = .tooManyAttempts
        case "bad-code": self = .badCode
        default: self = .other(reason)
        }
    }

    public var reasonCode: String {
        switch self {
        case .noWindow: return "no-window"
        case .expired: return "expired"
        case .tooManyAttempts: return "too-many-attempts"
        case .badCode: return "bad-code"
        case .other(let raw): return raw
        }
    }
}

/// JSON-lines 读写：控制流消息量极小，逐块读到 `\n` 的代价可以忽略。
struct JsonLineBuffer {
    private var buffer = Data()

    /// 追加新读到的字节，返回其中完整的行（不含换行符）。
    mutating func append(_ chunk: Data) -> [String] {
        buffer.append(chunk)
        var lines: [String] = []
        while let index = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<index]
            buffer.removeSubrange(buffer.startIndex...index)
            if let line = String(data: lineData, encoding: .utf8) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { lines.append(trimmed) }
            }
        }
        // 单行超过上限说明对端在喂垃圾，直接清掉避免无限增长。
        if buffer.count > TetherWire.maxLine { buffer.removeAll() }
        return lines
    }

    mutating func reset() { buffer.removeAll() }
}
