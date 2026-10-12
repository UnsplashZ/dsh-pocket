import Foundation

/// 日志级别。
public enum DSHLogLevel: Int, Sendable, Comparable, CaseIterable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    public static func < (lhs: DSHLogLevel, rhs: DSHLogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERROR"
        }
    }
}

/// 一条日志。
public struct DSHLogEntry: Sendable, Identifiable {
    public let id = UUID()
    public let time: Date
    public let level: DSHLogLevel
    public let message: String

    public init(time: Date = Date(), level: DSHLogLevel, message: String) {
        self.time = time
        self.level = level
        self.message = message
    }
}

/// 日志出口。诊断页与"导出日志"都靠它。
public protocol DSHLogSink: Sendable {
    func log(_ level: DSHLogLevel, _ message: String)
}

extension DSHLogSink {
    public func log(_ level: DSHLogLevel, _ message: String) {}
}

/// 把日志留在内存里的环形缓冲；`PrivacyInfo` 承诺不外发，导出由用户手动触发。
public actor MemoryLogSink: DSHLogSink {
    private var entries: [DSHLogEntry] = []
    private let capacity: Int
    private let minimumLevel: DSHLogLevel

    public init(capacity: Int = 2_000, minimumLevel: DSHLogLevel = .debug) {
        self.capacity = capacity
        self.minimumLevel = minimumLevel
    }

    public nonisolated func log(_ level: DSHLogLevel, _ message: String) {
        Task { await self.append(level, message) }
    }

    private func append(_ level: DSHLogLevel, _ message: String) {
        guard level >= minimumLevel else { return }
        entries.append(DSHLogEntry(level: level, message: message))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    public func snapshot() -> [DSHLogEntry] { entries }

    public func clear() { entries.removeAll() }

    /// 导出为纯文本，供 ShareLink 分享。
    public func exportText() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return entries
            .map { "\(formatter.string(from: $0.time)) [\($0.level.label)] \($0.message)" }
            .joined(separator: "\n")
    }
}

/// 什么都不做的出口（测试与库调用方默认值）。
public struct NullLogSink: DSHLogSink {
    public init() {}
}
