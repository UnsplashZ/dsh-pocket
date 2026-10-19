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

/// 把日志留在内存里的环形缓冲，**并同步写一份到磁盘**；
/// `PrivacyInfo` 承诺不外发，导出由用户手动触发。
///
/// 为什么要落盘（2026-10-19）：连接类 bug 的日志全在"App 被杀之后"才最有用 ——
/// 而内存缓冲那一刻就没了。以前每次排障都得让用户解锁手机、进设置、手动导出。
/// 现在日志实时追加到 App 容器内的 `Library/Logs/dsh-pocket.log`，
/// 可以一条命令取回来：
/// ```
/// xcrun devicectl device copy from --device <UDID> \
///   --domain-type appDataContainer --domain-identifier cc.unsplashz.dshpocket \
///   --source Library/Logs/dsh-pocket.log --destination /tmp/
/// ```
///
/// 只在**首次写入时**打开文件句柄并追加；写失败就静默放弃（日志不能反过来
/// 影响 App 的正常工作）。文件按 `maxDiskBytes` 滚动：超了就整体重写成
/// 后半段，避免无限增长。
public actor MemoryLogSink: DSHLogSink {
    private var entries: [DSHLogEntry] = []
    private let capacity: Int
    private let minimumLevel: DSHLogLevel
    /// 磁盘镜像的路径。`nil` = 只留内存（测试与库调用方）。
    private let fileURL: URL?
    private var handle: FileHandle?
    private var writtenBytes = 0
    private let maxDiskBytes: Int

    /// - Parameters:
    ///   - fileURL: 磁盘镜像路径。父目录不存在时会自动创建。
    ///   - maxDiskBytes: 文件大小上限，超了保留后半段。
    public init(
        capacity: Int = 2_000,
        minimumLevel: DSHLogLevel = .debug,
        fileURL: URL? = nil,
        maxDiskBytes: Int = 2_000_000
    ) {
        self.capacity = capacity
        self.minimumLevel = minimumLevel
        self.fileURL = fileURL
        self.maxDiskBytes = maxDiskBytes
    }

    public nonisolated func log(_ level: DSHLogLevel, _ message: String) {
        Task { await self.append(level, message) }
    }

    private func append(_ level: DSHLogLevel, _ message: String) {
        guard level >= minimumLevel else { return }
        let entry = DSHLogEntry(level: level, message: message)
        entries.append(entry)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        mirrorToDisk(entry)
    }

    /// 追加一行到磁盘。失败就放弃（不是关键路径）。
    private func mirrorToDisk(_ entry: DSHLogEntry) {
        guard let fileURL else { return }
        let line = "\(Self.timestamp.string(from: entry.time)) [\(entry.level.label)] \(entry.message)\n"
        guard let data = line.data(using: .utf8) else { return }
        do {
            if handle == nil {
                let directory = fileURL.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                }
                let opened = try FileHandle(forWritingTo: fileURL)
                try opened.seekToEnd()
                handle = opened
                writtenBytes = (try? Int(opened.offset())) ?? 0
            }
            try handle?.write(contentsOf: data)
            writtenBytes += data.count
            if writtenBytes > maxDiskBytes { rollOver() }
        } catch {
            // 关掉句柄，下次重试时重新打开。
            try? handle?.close()
            handle = nil
        }
    }

    /// 超过上限就保留后半段，避免文件无限增长。
    private func rollOver() {
        guard let fileURL, let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let keep = String(text.suffix(maxDiskBytes / 2))
        try? handle?.close()
        handle = nil
        try? keep.write(to: fileURL, atomically: true, encoding: .utf8)
        writtenBytes = keep.utf8.count
    }

    private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

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
