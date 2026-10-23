import Foundation
import Network
import Observation
import SwiftUI

/// 手机当前在什么网络上。
///
/// **这个类型存在的唯一理由**：判断"某个地址现在物理上可不可达"。
/// 真机事故（0.5.0）：手机只有 5G、没有 Wi-Fi，App 仍然去探 `http://10.8.54.221:18788`
/// 这种私有地址 —— 探 800ms 超时、电脑侧一个包都收不到，日志里只有一句
/// "所有档位都探测失败"，看起来像 App 坏了。实际上它只是**不知道自己在蜂窝网上**。
public enum UplinkNetworkKind: String, Sendable, Equatable {
    case wifi
    case wiredEthernet
    case cellular
    case offline
    /// 有网但认不出接口类型（VPN 接管、模拟器等）。**保守处理：不跳过任何档位**。
    case other
    /// `NWPathMonitor` 还没给出第一条结果。
    case unknown

    public init(path: NWPath) {
        guard path.status == .satisfied else {
            self = .offline
            return
        }
        if path.usesInterfaceType(.wifi) {
            self = .wifi
        } else if path.usesInterfaceType(.wiredEthernet) {
            self = .wiredEthernet
        } else if path.usesInterfaceType(.cellular) {
            self = .cellular
        } else {
            self = .other
        }
    }

    /// 是不是"和电脑在同一个二层网络"的那种网络。Bonjour 只在这种网络上有意义。
    public var isLocalNetwork: Bool {
        self == .wifi || self == .wiredEthernet
    }

    /// 蜂窝下局域网地址**物理上不可达**：探它只会白等 800ms，还给出一句误导的"超时"。
    ///
    /// 只对 `.cellular` 成立 —— `.unknown` / `.other` 一律不跳（保守：宁可多探一次，
    /// 也不要因为监控还没出结果就误判"没网"）。
    public var skipsLocalTiers: Bool {
        self == .cellular
    }

    public var label: LocalizedStringKey {
        switch self {
        case .wifi: return "Wi-Fi"
        case .wiredEthernet: return "有线网络"
        case .cellular: return "蜂窝网络"
        case .offline: return "无网络"
        case .other: return "其他网络"
        case .unknown: return "未知网络"
        }
    }

    /// 已解析的字符串（理由同 `TransportMode.resolvedLabel`）。
    public var resolvedLabel: String {
        switch self {
        case .wifi: return String(localized: "Wi-Fi")
        case .wiredEthernet: return String(localized: "有线网络")
        case .cellular: return String(localized: "蜂窝网络")
        case .offline: return String(localized: "无网络")
        case .other: return String(localized: "其他网络")
        case .unknown: return String(localized: "未知网络")
        }
    }
}

/// `NWPathMonitor` 的薄封装。
///
/// 只做一件事：把"现在是什么网络"变成一个可观察的属性。**不做任何策略判断** ——
/// 该跳哪一档是 `UplinkSession` 的事，这里只提供事实。
@MainActor
@Observable
public final class UplinkNetworkMonitor {
    public private(set) var kind: UplinkNetworkKind

    /// 单测注入：固定成某个网络类型，不启动真正的监控。
    private let fixed: UplinkNetworkKind?
    private let monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "cc.unsplashz.dshpocket.uplink.path")
    private var started = false
    /// 第一条网络事实的等待者（冷启动时 `NWPathMonitor` 要一两百毫秒才回第一条）。
    private var firstUpdate: CheckedContinuation<Void, Never>?

    public init(fixed: UplinkNetworkKind? = nil) {
        self.fixed = fixed
        self.kind = fixed ?? .unknown
        self.monitor = fixed == nil ? NWPathMonitor() : nil
    }

    public func start() {
        guard let monitor, !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let next = UplinkNetworkKind(path: path)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.kind = next
                self.finishFirstUpdate()
            }
        }
        monitor.start(queue: queue)
    }

    #if DEBUG
    /// 单测用：模拟"换网"（Wi-Fi ↔ 蜂窝）。只改内存，不碰真实监控。
    ///
    /// 幂等守卫里"网络指纹变了就重建"这条需要一个能变的事实，
    /// 而 `NWPathMonitor` 在测试里给不出。
    public func overrideKind(_ kind: UplinkNetworkKind) {
        self.kind = kind
    }
    #endif

    public func stop() {
        guard let monitor, started else { return }
        started = false
        monitor.cancel()
        finishFirstUpdate()
    }

    /// 等到"知道自己在什么网络上"为止（最多 `timeout`）。
    ///
    /// 为什么需要：冷启动时 `start()` 和第一轮探测几乎同时发生，而 `NWPathMonitor`
    /// 要一两百毫秒才回第一条。不等这一下，蜂窝用户的第一轮就会照老样子去探局域网
    /// —— 正是这次要修的那个"不知道自己在 5G 上"。
    ///
    /// 监控没启动（单测、或还没跑过 `start`）时立刻返回：不为了一个不确定的事实
    /// 白等 300ms。
    public func waitForFirstUpdate(timeout: TimeInterval = 0.3) async {
        guard fixed == nil, started, kind == .unknown else { return }
        await withCheckedContinuation { continuation in
            firstUpdate = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.finishFirstUpdate()
            }
        }
    }

    private func finishFirstUpdate() {
        guard let continuation = firstUpdate else { return }
        firstUpdate = nil
        continuation.resume()
    }
}
