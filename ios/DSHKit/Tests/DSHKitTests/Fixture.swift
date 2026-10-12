import Foundation
import XCTest

@testable import DSHKit

/// 测试用的构造助手。
///
/// 这里的事件负载**逐字段照着活服务器抓下来的样本写**（见 tools/capture-session.mjs），
/// 不是拍脑袋编的形状 —— 协议漂移时这些测试会先红。
///
/// 所有自由文本都过 `esc()`，避免在 JSON 字符串里漏转义（这是手写 fixture 最常见的坑）。
enum Fixture {
    static func esc(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    static func json(_ text: String) -> JSONValue {
        let data = Data(text.utf8)
        return (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
    }

    static func event(_ text: String) throws -> SessionEvent {
        try SessionEvent.decode(json(text))
    }

    static func snapshot(_ events: [String], cursor: Int? = nil, hasMore: Bool = false) throws -> SessionSnapshot {
        let records = events.map { "{\"type\":\"event\",\"event\":\($0)}" }.joined(separator: ",")
        let cursorValue = cursor ?? (events.count - 1)
        let text = """
        {"type":"snapshot","header":{"version":4,"id":"session-test","createdAt":1791727785344,"cwd":"/Users/example/dev/Github","isSeeded":false,"delegationDepth":0,"agentPreset":"standard"},"cursor":\(cursorValue),"records":[\(records)],"hasMore":\(hasMore),"projections":{"asOfSeq":\(cursorValue),"values":{"title":"测试会话"}},"assistantStream":{"revision":1}}
        """
        return try SessionSnapshot.decode(json(text))
    }

    // MARK: 事件字面量

    static func turnStart(_ turn: Int, seq: Int, time: Int = 1_791_777_000_000) -> String {
        """
        {"type":"turn/start","seq":\(seq),"time":\(time),"data":{"turn":\(turn)}}
        """
    }

    static func turnEnd(_ turn: Int, seq: Int, kind: String = "completed") -> String {
        """
        {"type":"turn/end","seq":\(seq),"time":1791777001000,"data":{"turn":\(turn),"reason":{"kind":"\(kind)"}}}
        """
    }

    static func stepStart(turn: Int, step: Int, seq: Int) -> String {
        """
        {"type":"step/start","seq":\(seq),"time":1791777000000,"data":{"turn":\(turn),"step":\(step)}}
        """
    }

    static func stepEnd(turn: Int, step: Int, seq: Int) -> String {
        """
        {"type":"step/end","seq":\(seq),"time":1791777000500,"data":{"turn":\(turn),"step":\(step)}}
        """
    }

    static func userMessage(_ text: String, seq: Int, rpcId: String = "rpc-1") -> String {
        """
        {"type":"user/message","seq":\(seq),"time":1791777000000,"data":{"content":[{"type":"text","text":"\(esc(text))"}],"source":{"kind":"user","rpcId":"\(rpcId)","clientTimeZone":"Asia/Shanghai"},"role":"user","id":"msg-\(seq)"},"surfaceOp":"append"}
        """
    }

    static func assistantMessage(
        text: String,
        reasoning: String? = nil,
        toolCall: (id: String, name: String, arguments: String)? = nil,
        turn: Int = 1,
        step: Int = 1,
        seq: Int,
        surfaceOp: String = "\"append\"",
        interrupted: Bool = false
    ) -> String {
        var blocks: [String] = []
        if let reasoning {
            blocks.append("{\"type\":\"reasoning\",\"text\":\"\(esc(reasoning))\"}")
        }
        if !text.isEmpty {
            blocks.append("{\"type\":\"text\",\"text\":\"\(esc(text))\"}")
        }
        if let toolCall {
            blocks.append("{\"type\":\"tool-call\",\"id\":\"\(toolCall.id)\",\"name\":\"\(toolCall.name)\",\"arguments\":\"\(esc(toolCall.arguments))\"}")
        }
        let extra = interrupted ? ",\"interrupted\":true" : ""
        return """
        {"type":"assistant/message","seq":\(seq),"time":1791777000200,"data":{"turn":\(turn),"step":\(step),"message":{"role":"assistant","content":[\(blocks.joined(separator: ","))],"source":{"kind":"model","provider":"wb","model":"deepseek-v4.1-flash"}}\(extra)},"surfaceOp":\(surfaceOp)}
        """
    }

    /// 只带 usage 的空助手消息（max-tokens 步会这样）。
    static func emptyAssistantMessage(seq: Int, turn: Int = 1, step: Int = 1) -> String {
        """
        {"type":"assistant/message","seq":\(seq),"time":1791777000200,"data":{"turn":\(turn),"step":\(step),"message":{"role":"assistant","content":[],"source":{"kind":"model","provider":"wb","model":"deepseek-v4.1-flash"}}},"surfaceOp":"append"}
        """
    }

    static func toolCall(_ callId: String, name: String = "bash", arguments: String = #"{"command":"ls"}"#, turn: Int = 1, step: Int = 1, seq: Int) -> String {
        """
        {"type":"tool/call","seq":\(seq),"time":1791777000300,"data":{"turn":\(turn),"step":\(step),"callId":"\(callId)","name":"\(name)","arguments":"\(esc(arguments))"}}
        """
    }

    static func toolResult(_ callId: String, output: String, isError: Bool = false, turn: Int = 1, step: Int = 1, seq: Int) -> String {
        """
        {"type":"tool/result","seq":\(seq),"time":1791777000900,"data":{"turn":\(turn),"step":\(step),"message":{"role":"tool","source":{"kind":"tool","callId":"\(callId)"},"toolCallId":"\(callId)","isError":\(isError),"content":[{"type":"text","text":"\(esc(output))"}]}},"surfaceOp":"append"}
        """
    }

    static func approvalAsked(id: String, toolName: String = "bash", reason: String = "要跑一条写文件的命令", seq: Int) -> String {
        """
        {"type":"approval/asked","seq":\(seq),"time":1791777000300,"data":{"id":"\(id)","toolName":"\(toolName)","reason":"\(esc(reason))"}}
        """
    }

    static func approvalDecided(id: String, outcome: String, seq: Int) -> String {
        """
        {"type":"approval/decided","seq":\(seq),"time":1791777000400,"data":{"id":"\(id)","outcome":"\(outcome)"}}
        """
    }

    static func todoWrite(_ items: [(String, String)], seq: Int) -> String {
        let encoded = items
            .map { "{\"content\":\"\(esc($0.0))\",\"status\":\"\($0.1)\"}" }
            .joined(separator: ",")
        return """
        {"type":"todo/write","seq":\(seq),"time":1791777000300,"data":{"todos":[\(encoded)]}}
        """
    }

    static func compactionSummary(seq: Int, startSeq: Int, endSeq: Int, summary: String = "把前面几轮压成一段摘要") -> String {
        """
        {"type":"compaction/summary","seq":\(seq),"time":1791777000300,"data":{"compactionId":"c1","summary":[{"type":"text","text":"\(esc(summary))"}],"shadowedRange":{"start":\(startSeq),"end":\(endSeq)},"shadowedSeqs":[],"shadowedTokenCount":100,"provider":"wb","model":"deepseek-v4.1-flash"},"surfaceOp":{"op":"replace","startSeq":\(startSeq),"endSeq":\(endSeq)}}
        """
    }

    static func systemMessageReplaced(seq: Int, startSeq: Int, endSeq: Int, text: String = "新的系统提示") -> String {
        """
        {"type":"system/message","seq":\(seq),"time":1791777000300,"data":{"turn":1,"step":1,"message":{"role":"system","content":[{"type":"text","text":"\(esc(text))"}]}},"surfaceOp":{"op":"replace","startSeq":\(startSeq),"endSeq":\(endSeq)}}
        """
    }

    static func inboxSpliced(_ text: String, rpcId: String, seq: Int, target: String = "next-turn") -> String {
        """
        {"type":"agent/inbox/spliced","seq":\(seq),"time":1791777000000,"data":{"target":"\(target)","start":0,"inserted":[{"content":[{"type":"text","text":"\(esc(text))"}],"source":{"kind":"user","rpcId":"\(rpcId)"},"role":"user","id":"m-\(seq)"}]}}
        """
    }

    static func requestHeader(seq: Int, model: String = "deepseek-v4.1-flash") -> String {
        """
        {"type":"request/header","seq":\(seq),"time":1791777000000,"data":{"header":{"config":{"provider":"wb","model":"\(model)"}},"reason":{"kind":"initial"}}}
        """
    }

    /// 机器注入的上下文 —— 它同样是 `user/message` 事件，但 `source.kind` 不是 `user`。
    static func injectedContext(_ text: String, kind: String, seq: Int) -> String {
        """
        {"type":"user/message","seq":\(seq),"time":1791777000000,"data":{"content":[{"type":"text","text":"\(esc(text))"}],"source":{"kind":"\(kind)"},"role":"user","id":"ctx-\(seq)"},"surfaceOp":"append"}
        """
    }

    static func unknownEvent(type: String, seq: Int, ignorable: Bool = false) -> String {
        let marker = ignorable ? ",\"ignorable\":true" : ""
        return """
        {"type":"\(type)","seq":\(seq),"time":1791777000300,"data":{"whatever":1}\(marker)}
        """
    }

    // MARK: 实时帧

    static func streamStart(attemptId: String, turn: Int = 1, step: Int = 1, startedAfterSeq: Int = 1) -> JSONValue {
        json("""
        {"type":"start","attemptId":"\(attemptId)","revision":1,"startedAfterSeq":\(startedAfterSeq),"turn":\(turn),"step":\(step)}
        """)
    }

    static func streamText(_ text: String, attemptId: String, index: Int) -> JSONValue {
        json("""
        {"type":"chunk","attemptId":"\(attemptId)","revision":1,"index":\(index),"time":1791777000600,"chunk":{"type":"text-delta","index":0,"text":"\(esc(text))"}}
        """)
    }

    static func streamReasoning(_ text: String, attemptId: String, index: Int) -> JSONValue {
        json("""
        {"type":"chunk","attemptId":"\(attemptId)","revision":1,"index":\(index),"time":1791777000600,"chunk":{"type":"reasoning-delta","index":0,"text":"\(esc(text))"}}
        """)
    }

    static func streamToolCallDelta(_ argumentsDelta: String, callId: String, name: String, attemptId: String, index: Int) -> JSONValue {
        json("""
        {"type":"chunk","attemptId":"\(attemptId)","revision":1,"index":\(index),"time":1791777000600,"chunk":{"type":"tool-call-delta","index":1,"id":"\(callId)","name":"\(name)","argumentsDelta":"\(esc(argumentsDelta))"}}
        """)
    }

    static func streamEnd(attemptId: String, index: Int, kind: String = "committed", seq: Int = 5) -> JSONValue {
        let outcome = kind == "abandoned"
            ? "{\"kind\":\"abandoned\"}"
            : "{\"kind\":\"committed\",\"eventType\":\"assistant/message\",\"seq\":\(seq)}"
        return json("""
        {"type":"end","attemptId":"\(attemptId)","revision":1,"index":\(index),"outcome":\(outcome)}
        """)
    }

    // MARK: waterfall 帧

    static func waterfallApproval(eventId: String, toolName: String = "bash", reason: String = "要跑 rm") -> WaterfallRequest {
        WaterfallRequest(json: json("""
        {"type":"waterfall","event":"approval/request","eventId":"\(eventId)","agentId":"session-test","request":{"toolName":"\(toolName)","callId":"call-1","reason":"\(esc(reason))"}}
        """))
    }

    static func waterfallQuestion(eventId: String) -> WaterfallRequest {
        WaterfallRequest(json: json("""
        {"type":"waterfall","event":"user-questions/request","eventId":"\(eventId)","agentId":"session-test","request":{"callId":"call-9","questions":[{"id":"q1","question":"用哪个方案？","header":"方案","multiSelect":false,"options":[{"label":"甲","description":"快"},{"label":"乙"}]},{"id":"q2","question":"补充说明？"}]}}
        """))
    }

    static func ready(clientId: String) -> JSONValue {
        json("""
        {"type":"ready","clientId":"\(clientId)","host":{"home":"/Users/example"}}
        """)
    }
}


extension JSONEncoder {
    /// 与 App 侧 `SessionCache` 用同一套日期策略 —— 测的是"落盘能不能原样读回"，
    /// 两边策略不一致的话这条测试就没有意义了。
    static let cacheForTests: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension JSONDecoder {
    static let cacheForTests: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
