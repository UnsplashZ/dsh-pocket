import Foundation

// MARK: - 后台任务（`job/*`）

/// 一个后台任务（`JobView`）。
///
/// 桌面端有专门的面板：能看到实时输出、能停。手机上没有的话，
/// 后台跑起来就**彻底看不见了** —— 这是唯一一类"跑起来就消失"的东西。
public struct BackgroundJob: Sendable, Hashable, Identifiable {
    public var id: String
    /// `bash` / `pwsh` 之类。
    public var kind: String
    public var label: String
    public var status: String
    public var progress: String?
    public var detail: String?
    public var startedAt: Date
    public var finishedAt: Date?
    /// 已产出的字节数。
    public var outputTotal: Int
    /// 输出最早可用的偏移（超出上限的部分会被丢掉，从这里开始）。
    public var outputEarliest: Int

    public init(json: JSONValue) {
        self.id = json.string("id") ?? ""
        self.kind = json.string("kind") ?? ""
        self.label = json.string("label") ?? ""
        self.status = json.string("status") ?? ""
        self.progress = json.string("progress")
        self.detail = json.string("detail")
        self.startedAt = Date(timeIntervalSince1970: (json.double("startedAt") ?? 0) / 1000)
        if let finished = json.double("finishedAt") {
            self.finishedAt = Date(timeIntervalSince1970: finished / 1000)
        }
        self.outputTotal = json.int("output.total") ?? 0
        self.outputEarliest = json.int("output.earliest") ?? 0
    }

    public var isRunning: Bool { status == "running" || status == "stopping" }

    public var statusLabel: String {
        switch status {
        case "running": return String(localized: "运行中")
        case "stopping": return String(localized: "正在停止")
        case "finished", "exited": return String(localized: "已结束")
        case "failed": return String(localized: "失败")
        case "killed": return String(localized: "已停止")
        case "": return String(localized: "后台任务")
        default: return status
        }
    }

    public var duration: TimeInterval? {
        guard let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }
}

/// `job/follow` 的一帧。
public enum JobFollowFrame: Sendable {
    case opened(job: BackgroundJob, from: Int)
    case output(chunks: [(at: Date, text: String)], next: Int, lossy: Bool)
    case status(BackgroundJob)
}

// MARK: - 命令（`commands/*`）

/// 一条斜杠命令（`CommandDescriptor`）。
public struct SlashCommand: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var summary: String
    /// 这个命令要不要带参数（`input` 存在就要）。
    public var takesInput: Bool

    public init(json: JSONValue) {
        self.name = json.string("name") ?? ""
        self.summary = json.string("description") ?? ""
        self.takesInput = json["input"].map { $0 != .null } ?? false
    }
}

// MARK: - 定时提醒（`schedule/*`）

/// 一条定时提醒。
///
/// 线上形状因 `kind` 而异（`after`/`at`/`every`/`daily`/`weekly`/`cron`），
/// 所以这里保留原始 JSON，只解出界面要用的几个字段。
public struct Reminder: Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: String
    public var title: String
    public var prompt: String
    public var scheduledAt: Date?
    /// 只在这个会话里生效；`nil` 表示全局。
    public var sessionId: String?
    public var raw: JSONValue

    public init(json: JSONValue) {
        self.id = json.string("id") ?? ""
        self.kind = json.string("kind") ?? ""
        self.title = json.string("title") ?? String(localized: "提醒")
        self.prompt = json.string("prompt") ?? ""
        if let at = json.string("scheduledAt") { self.scheduledAt = ISO8601DateFormatter().date(from: at) }
        else if let ms = json.double("scheduledAt") { self.scheduledAt = Date(timeIntervalSince1970: ms / 1000) }
        else { self.scheduledAt = nil }
        self.sessionId = json.string("sessionId")
        self.raw = json
    }

    /// 人话说的重复规则。
    public var cadence: String {
        switch kind {
        case "after":
            let seconds = raw.int("afterSeconds") ?? 0
            return String(format: String(localized: "%lld 秒后"), seconds)
        case "at": return String(localized: "指定时刻")
        case "every":
            let seconds = raw.int("everySeconds") ?? 0
            if seconds % 3600 == 0 { return String(format: String(localized: "每 %lld 小时"), seconds / 3600) }
            if seconds % 60 == 0 { return String(format: String(localized: "每 %lld 分钟"), seconds / 60) }
            return String(format: String(localized: "每 %lld 秒"), seconds)
        case "daily": return String(localized: "每天")
        case "weekly": return String(localized: "每周")
        case "cron": return "cron"
        case "": return String(localized: "提醒")
        default: return kind
        }
    }
}

// MARK: - 上下文明细

/// 上下文里各部分占了多少 token（`contextBreakdown`）。
///
/// 桌面端把它做成了一个悬浮面板。手机上有三个数就够了 ——
/// 用户真正想知道的只有"是不是历史太长了"。
public struct ContextBreakdown: Sendable, Hashable {
    public var systemTokens: Int = 0
    public var toolsTokens: Int = 0
    public var messageTokens: Int = 0

    public init(json: JSONValue) {
        systemTokens = json.int("systemTokens") ?? 0
        toolsTokens = json.int("toolsTokens") ?? 0
        messageTokens = json.int("messageTokens") ?? 0
    }

    public var total: Int { systemTokens + toolsTokens + messageTokens }
    public var isEmpty: Bool { total == 0 }

    public var parts: [(label: String, tokens: Int)] {
        [
            (String(localized: "系统提示"), systemTokens),
            (String(localized: "工具定义"), toolsTokens),
            (String(localized: "对话历史"), messageTokens),
        ]
    }
}

// MARK: - 目标

/// 会话的长期目标（`projections.goal`）。
public struct SessionGoal: Sendable, Hashable {
    public var phase: String
    public var objective: String?
    public var revision: Int

    public init(json: JSONValue) {
        self.phase = json.string("phase") ?? ""
        self.objective = json.string("objective")
        self.revision = json.int("revision") ?? 0
    }

    public var isActive: Bool { phase == "active" }

    public var phaseLabel: String {
        switch phase {
        case "active": return String(localized: "进行中的目标")
        case "paused": return String(localized: "已暂停的目标")
        case "blocked": return String(localized: "受阻的目标")
        case "": return String(localized: "未运行的目标")
        default: return phase
        }
    }
}


/// 一条会话搜索命中。
public struct SessionSearchHit: Sendable, Hashable, Identifiable {
    public var id: String
    public var sessionId: String
    public var title: String
    public var snippet: String
    public var seq: Double?

    public init(json: JSONValue) {
        let sessionId = json.string("sessionId") ?? json.string("id") ?? ""
        self.sessionId = sessionId
        self.id = json.string("messageId") ?? json.string("seq") ?? sessionId
        self.title = json.string("title") ?? ""
        self.snippet = json.string("snippet") ?? json.string("text") ?? ""
        self.seq = json.double("seq")
    }
}


// MARK: - `@` 引用

/// 一个可引用的工作区文件。
public struct FileReferenceCandidate: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public var path: String
    public var isDirectory: Bool

    public init(json: JSONValue) {
        self.path = json.string("path") ?? ""
        self.isDirectory = (json.string("kind") ?? "file") == "directory"
    }
}

/// 一个可引用的别的会话。
public struct SessionReferenceCandidate: Sendable, Hashable, Identifiable {
    public var id: String { sessionId }
    public var sessionId: String
    public var label: String
    public var title: String?
    public var cwd: String?
    public var sameWorkspace: Bool

    public init(json: JSONValue) {
        self.sessionId = json.string("sessionId") ?? ""
        self.label = json.string("label") ?? ""
        self.title = json.string("displayTitle")
        self.cwd = json.string("cwd")
        self.sameWorkspace = json.bool("sameWorkspace") ?? false
    }

    public var display: String { title?.isEmpty == false ? title! : label }
}
