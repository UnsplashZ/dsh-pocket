import Foundation

/// 一个**无损**的 JSON 值。
///
/// 为什么不用 `Codable` + 具体结构体去解事件负载：DSH 的事件负载是
/// "merge-extensible union"（见 `dsh-session/lib/types/surface.js` 的注释），
/// 宿主升级会加字段、加事件类型。如果我们用严格结构体解码，**一个未知字段就会让
/// 整条时间线解码失败**。所以策略是：
///
///   · **信封**（type / seq / time / data / surfaceOp / sourceEventSeqs）严格解码；
///   · **负载**用 `JSONValue` 原样带着，渲染层按需取值，认不出的类型退化成
///     "未知事件"卡片，而不是丢帧或崩。
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - 取值

extension JSONValue {
    public var isNull: Bool { if case .null = self { return true }; return false }

    public var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }

    public var doubleValue: Double? {
        switch self {
        case .number(let v): return v
        case .bool(let v): return v ? 1 : 0
        default: return nil
        }
    }

    public var intValue: Int? {
        guard let d = doubleValue, d.isFinite else { return nil }
        return Int(d)
    }

    public var stringValue: String? { if case .string(let v) = self { return v }; return nil }

    public var arrayValue: [JSONValue]? { if case .array(let v) = self { return v }; return nil }

    public var objectValue: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }

    /// 下标取值；非对象返回 nil。
    public subscript(key: String) -> JSONValue? { objectValue?[key] }

    /// 数组下标；越界或非数组返回 nil。
    public subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }

    /// 点分路径取值。`value(at: "message.content")` 等价于 `self["message"]?["content"]`。
    ///
    /// 为什么给"单键"访问器也加上点分支持：DSH 的负载是嵌套的，
    /// 写 `event.data.array("message.content")` 比写一长串 `?[...]?[...]` 更不容易错，
    /// 而协议里没有哪个字段名真的含点。
    public func value(at path: String) -> JSONValue? {
        var current: JSONValue? = self
        for key in path.split(separator: ".") {
            current = current?[String(key)]
            if current == nil { return nil }
        }
        return current
    }

    public func string(_ path: String) -> String? { value(at: path)?.stringValue }
    public func int(_ path: String) -> Int? { value(at: path)?.intValue }
    public func double(_ path: String) -> Double? { value(at: path)?.doubleValue }
    public func bool(_ path: String) -> Bool? { value(at: path)?.boolValue }
    public func array(_ path: String) -> [JSONValue]? { value(at: path)?.arrayValue }
    public func object(_ path: String) -> [String: JSONValue]? { value(at: path)?.objectValue }

    /// 嵌套路径取值：`value(at: "message", "content")`（变参形式，等价于点分）。
    public func value(at path: String...) -> JSONValue? {
        var current: JSONValue? = self
        for key in path {
            current = current?[key]
            if current == nil { return nil }
        }
        return current
    }
}

// MARK: - 便捷构造

extension JSONValue {
    public static func object(_ pairs: [(String, JSONValue)]) -> JSONValue {
        .object(Dictionary(uniqueKeysWithValues: pairs))
    }

    public static func from(_ any: Any) -> JSONValue {
        switch any {
        case is NSNull:
            return .null
        case let value as Bool:
            return .bool(value)
        case let value as Int:
            return .number(Double(value))
        case let value as Double:
            return .number(value)
        case let value as String:
            return .string(value)
        case let value as [Any]:
            return .array(value.map(JSONValue.from))
        case let value as [String: Any]:
            return .object(value.mapValues(JSONValue.from))
        default:
            return .null
        }
    }
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: String(localized: "不是合法的 JSON 值")
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // 整数值写成整数，避免把 seq / 时间戳写成 `5.0`——DSH 侧校验
            // `Number.isSafeInteger`，`5.0` 解析回来仍是 5，但可读性与 diff 都差。
            if value.rounded() == value, abs(value) < 9_007_199_254_740_992 {
                try container.encode(Int(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - 调试输出

extension JSONValue: CustomStringConvertible {
    public var description: String {
        guard let data = try? JSONEncoder.dshCompact.encode(self),
              let text = String(data: data, encoding: .utf8)
        else { return "<JSONValue>" }
        return text
    }

    /// 供 UI 折叠展示的紧凑单行文本，超长截断。
    public func displayText(limit: Int = 4_000) -> String {
        let text = description
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}

extension JSONEncoder {
    /// 与 DSH 侧的 `JSON.stringify` 对齐：不 pretty、不转义斜杠。
    public static let dshCompact: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return encoder
    }()
}

extension JSONDecoder {
    public static let dsh: JSONDecoder = JSONDecoder()
}
