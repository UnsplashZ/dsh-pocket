import Foundation

/// 对一条助手消息的评价。
///
/// 线上是 `messageFeedback/{list,put,delete}`（`dsh-message-feedback` 插件）。
/// **`put` / `delete` 的线上形状是扁平的**，不是那个带 `item` 的 TS 接口：
/// ```
/// put    {request: {sessionId, messageId, rating, note?, category?, ifVersion}}
/// delete {request: {sessionId, messageId, ifVersion}}
/// ```
/// `ifVersion` 是**乐观并发控制**：传你上次看到的版本，没有就传 `null`；
/// 别人在你之后改过会被拒，而不是悄悄覆盖。
public enum MessageFeedbackRating: String, Sendable, Hashable {
    case positive
    case negative

    public var symbol: String {
        switch self {
        case .positive: return "hand.thumbsup"
        case .negative: return "hand.thumbsdown"
        }
    }
}

/// 一条已存的评价。
public struct MessageFeedback: Sendable, Hashable {
    public var messageId: String
    public var rating: MessageFeedbackRating
    /// 这条评价的版本 —— 改/删时当 `ifVersion` 传回去。
    public var version: String
    public var note: String?

    public init(json: JSONValue) {
        self.messageId = json.string("messageId") ?? ""
        self.rating = MessageFeedbackRating(rawValue: json.string("rating") ?? "") ?? .positive
        self.version = json.string("version") ?? ""
        self.note = json.string("note")
    }

    public init(messageId: String, rating: MessageFeedbackRating, version: String, note: String? = nil) {
        self.messageId = messageId
        self.rating = rating
        self.version = version
        self.note = note
    }
}
