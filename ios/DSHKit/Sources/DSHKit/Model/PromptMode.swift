import Foundation
import SwiftUI

/// `session/prompt` 的投递模式。**必填** —— 省略它会被边界校验拒掉。
///
/// 读自 `SessionPromptRequest`：`mode: 'queue' | 'steer'`。
public enum PromptMode: String, Sendable, CaseIterable {
    /// 排到下一轮。默认。
    case queue
    /// 插队给**正在跑的这一轮**（DSH 的 steer 语义）。
    case steer

    public var label: LocalizedStringKey {
        switch self {
        case .queue: return "排队发送"
        case .steer: return "插队给这一轮"
        }
    }
}
