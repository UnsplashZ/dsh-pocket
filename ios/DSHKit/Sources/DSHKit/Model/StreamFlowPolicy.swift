import Foundation

/// 流式帧到达后"要不要发布、多快发布、流式标志怎么变"的决策表。
///
/// 从 `SessionModel.applyStream` 抽出来的**纯函数**（T1 测试债）——
/// 原来的判断散在 App 层的命令式代码里，没法单测；而它恰恰是
/// "流式输出时滚动卡不卡"的关键：
///
///   - `chunk` 来得极快，每帧都全量发布会把 SwiftUI 压垮 → 合帧；
///   - `end` 必须**立刻**落屏，否则最后一段文字晚一帧才出现；
///   - delta 为空的帧不该触发发布（白算一遍时间线）；
///   - 流式标志（`isStreaming`）的翻转规则与发布规则**不一样**：
///     `start` 无条件亮灯，`chunk` 只在真的产生内容时亮灯，`end` 无条件灭灯。
///
/// 定时器本身（16ms 窗口）留在 App 层——它是 MainActor 的 Task，
/// 这里钉住的是"每种帧落到哪个动作"这张表。
public enum StreamFlowPolicy {
    /// 发布动作。
    public enum Publish: String, Sendable, Equatable {
        /// delta 为空：什么都不做。
        case none
        /// 合帧：攒到下一个 ~16ms 窗口一起发布。
        case coalesced
        /// 立刻发布（流收尾）。要同时取消挂在窗口里的待发任务。
        case immediate
    }

    /// 一帧的完整处置决定。
    public struct Decision: Sendable, Equatable {
        public var isStreaming: Bool
        public var publish: Publish

        public init(isStreaming: Bool, publish: Publish) {
            self.isStreaming = isStreaming
            self.publish = publish
        }
    }

    /// 对一帧做决定。
    ///
    /// - Parameters:
    ///   - frame: 到达的流式帧。
    ///   - isStreaming: 当前的流式标志。
    ///   - deltaIsEmpty: `TimelineBuilder.apply(assistantStream:)` 的产物是否为空。
    public static func decide(
        frame: AssistantStreamFrame,
        isStreaming: Bool,
        deltaIsEmpty: Bool
    ) -> Decision {
        switch frame {
        case .start:
            // 无条件亮灯。delta 为空也不发布（此时时间线还没新内容）。
            return Decision(isStreaming: true, publish: deltaIsEmpty ? .none : .coalesced)
        case .end:
            // 无条件灭灯；有内容就立刻落屏（并取消待发），没内容就什么都不用发。
            return Decision(isStreaming: false, publish: deltaIsEmpty ? .none : .immediate)
        case .chunk:
            // chunk 只在真的产生内容时才亮灯、才发布。
            guard !deltaIsEmpty else { return Decision(isStreaming: isStreaming, publish: .none) }
            return Decision(isStreaming: true, publish: .coalesced)
        case .unknown:
            // 认不出的帧不动流式标志；产生了内容就合帧发出去（诊断页要看）。
            return Decision(isStreaming: isStreaming, publish: deltaIsEmpty ? .none : .coalesced)
        }
    }
}
