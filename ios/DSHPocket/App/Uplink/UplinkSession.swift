import DSHKit
import Foundation
import Observation

/// 多路接入的**会话层**：探测选档 → 换票 → 供 `HostCoordinator` 读基址与鉴权头。
///
/// 它只解决"怎么连"这一件事：
///   · 并行探测配对串里的所有地址，选最快通的那个（800ms 上限）；
///   · 用 per-device secret 换一张 900 秒的票据，到期前 60 秒自动续；
///   · 401 时清缓存、重换一次再试，第二次仍 401 才报错。
///
/// **协议层一行不改**：对 DSHKit 来说，这里最终只是"一个 baseURL + 一个 Authorization 头"。
///
/// 为什么把探测与 HTTP 都做成可注入的闭包：单测要能在毫秒级验证"选最快""粘滞优先"
/// "401 只重换一次"，而这些在真实网络里既慢又不可控（见 `UplinkTests`）。
@MainActor
@Observable
public final class UplinkSession {
    // MARK: 可注入的接缝

    /// 探一个档位：返回 RTT（毫秒），不可达返回 nil。
    /// 第二个参数是配对串里的 hostId —— 探到"另一台电脑"必须判失败。
    public typealias Probe = @Sendable (UplinkTier, String) async -> Int?
    /// 发一个 HTTP 请求。单测用它造假响应。
    public typealias Send = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// 单档探测上限。局域网正常是几毫秒，800ms 已经够宽松；
    /// 再长就等于"连不上"，继续等只会拖慢连接。
    public static let probeTimeout: TimeInterval = 0.8
    /// 粘滞窗口：这段时间内重新连接优先回到上一次通的档位。
    ///
    /// 为什么要粘滞：两档同时可达时（比如开着 Tailscale 又在家里的 Wi-Fi 上），
    /// 每次重连都按 RTT 重新选会来回跳，而每跳一次都要重新建连、重订阅所有流。
    /// 5 分钟是"网络没变就别折腾"和"换网了能及时纠正"之间的折中。
    public static let stickyWindow: TimeInterval = 300
    /// 到期前多久续票。票据 900 秒，60 秒足够覆盖一次慢请求。
    public static let refreshLead: TimeInterval = 60

    // MARK: 对外状态

    /// 当前可用的网关基址。`nil` = 还没探测成功 / 已退到后台。
    public private(set) var baseURL: URL?
    public private(set) var currentTier: UplinkTier?
    /// 最近一次失败的可读原因（诊断页与降级日志用）。
    public private(set) var lastError: String?
    /// 最近一次"为什么换档"（诊断页用）。
    public private(set) var lastSwitchReason: String?
    /// 每个档位最近一次测到的 RTT（毫秒）。键是 `UplinkTierKind.rawValue`。
    public private(set) var tierRTTs: [String: Int] = [:]
    /// 票据到期时间（诊断页用）。
    public private(set) var ticketExpiresAt: Date?
    public private(set) var isConnecting = false

    // MARK: 依赖

    private let store: UplinkCredentialStore
    private let settings: AppSettings
    private let logger: (any DSHLogSink)?
    private let probe: Probe
    private let send: Send
    private let now: () -> Date

    private var ticket: String?
    private var ticketExpiry: Date?

    public init(
        store: UplinkCredentialStore,
        settings: AppSettings,
        logger: (any DSHLogSink)? = nil,
        // 用闭包字面量而不是直接引用静态方法：直接引用会被推断成
        // 非 `@Sendable` 的函数值（编译告警），而这两者都要跨任务组使用。
        probe: @escaping Probe = { tier, hostId in
            await UplinkSession.httpProbe(tier: tier, expectedHostId: hostId)
        },
        send: @escaping Send = { request in
            try await UplinkSession.urlSessionSend(request)
        },
        now: @escaping () -> Date = { Date() }
    ) {
        self.store = store
        self.settings = settings
        self.logger = logger
        self.probe = probe
        self.send = send
        self.now = now
    }

    // MARK: 配对

    public var pairing: UplinkPairing? { store.loadPairing() }
    public var isPaired: Bool { pairing != nil }

    /// 采纳一段配对串。失败返回 nil，并把原因放进 `lastError`。
    @discardableResult
    public func adopt(_ text: String) -> UplinkPairing? {
        guard let pairing = UplinkPairing.parse(text) else {
            lastError = UplinkError.badPairing.errorDescription
            return nil
        }
        reset()
        store.save(pairing)
        // 换了一台电脑（或同一台重新配对）：上一台的 lastGood 不再有意义。
        settings.uplinkLastGoodTier = nil
        settings.uplinkStickyUntil = nil
        lastError = nil
        logger?.log(.info, "[uplink] 已配对 \(pairing.hostId.prefix(8))…（\(pairing.urls.count) 个地址）")
        return pairing
    }

    public func forget() {
        store.clear()
        reset()
        settings.uplinkLastGoodTier = nil
        settings.uplinkStickyUntil = nil
    }

    // MARK: 连接

    /// 探测 + 换票。成功返回选中的档位，失败返回 nil（原因在 `lastError`）。
    ///
    /// 顺序是**先粘滞、再并行**：
    ///   1. 最近 5 分钟内用过的档位单独探一次 —— 它刚才就通，大概率还通，
    ///      而且能让"同一 Wi-Fi 下反复重连"落在同一个地址上；
    ///   2. 否则并行探所有启用档位，取**最快**的那个成功者。
    @discardableResult
    public func connect() async -> UplinkTier? {
        guard !isConnecting else {
            lastError = String(localized: "上一次探测还在进行中")
            return nil
        }
        isConnecting = true
        defer { isConnecting = false }

        guard let pairing = store.loadPairing() else {
            lastError = UplinkError.notPaired.errorDescription
            return nil
        }
        let candidates = enabledTiers(of: pairing)
        guard !candidates.isEmpty else {
            lastError = String(localized: "所有档位都被关掉了。至少打开一个，或者换回 iroh。")
            return nil
        }

        if let sticky = stickyTier(in: candidates) {
            if let rtt = await probe(sticky, pairing.hostId) {
                logger?.log(.debug, "[uplink] 粘滞命中 \(sticky.kind.rawValue) \(rtt)ms")
                return await settle(on: sticky, rtt: rtt, reason: nil)
            }
            logger?.log(.debug, "[uplink] 粘滞档位 \(sticky.kind.rawValue) 这次没通，改为并行探测")
        }

        let started = now()
        let results = await race(candidates, hostId: pairing.hostId)
        // 先记下**所有**测到的 RTT —— 诊断页要显示"每一档多快"，
        // 只记选中那档的话，用户看不出"局域网 4ms、Tailscale 90ms"这种关键信息。
        for (tier, rtt) in results { tierRTTs[tier.kind.rawValue] = rtt }
        guard let winner = Self.fastest(results) else {
            let elapsed = Int(now().timeIntervalSince(started) * 1000)
            lastError = UplinkError.noTierAvailable.errorDescription
            lastSwitchReason = String(localized: "所有档位都探测失败（\(candidates.count) 个地址，用时 \(String(elapsed))ms）")
            logger?.log(.warning, "[uplink] 所有档位都探测失败（\(candidates.count) 个，\(elapsed)ms）")
            return nil
        }
        let previous = settings.uplinkLastGoodTier
        let reason: String? = previous.flatMap { prev in
            prev == winner.0.kind.rawValue
                ? nil
                : String(localized: "上一次用的 \(prev) 这次没通，换到 \(winner.0.kind.resolvedLabel)")
        }
        return await settle(on: winner.0, rtt: winner.1, reason: reason)
    }

    /// 选定了档位之后：换票、落 lastGood、暴露基址。
    private func settle(on tier: UplinkTier, rtt: Int, reason: String?) async -> UplinkTier? {
        currentTier = tier
        tierRTTs[tier.kind.rawValue] = rtt
        do {
            _ = try await exchangeTicket()
        } catch {
            // 地址通了但换不到票：这台电脑在，但我们的 secret 不被接受
            //（被撤销 / 电脑端重装过插件 / 两边时钟差太多）。
            // **不静默降级** —— 换条路能不能用是 AppModel 的决定，这里只如实报告。
            currentTier = nil
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastSwitchReason = lastError
            logger?.log(.warning, "[uplink] 换票失败（\(tier.kind.rawValue)）：\(lastError ?? "—")")
            return nil
        }
        baseURL = tier.url
        settings.uplinkLastGoodTier = tier.kind.rawValue
        settings.uplinkStickyUntil = now().addingTimeInterval(Self.stickyWindow)
        if let reason { lastSwitchReason = reason }
        lastError = nil
        logger?.log(.info, "[uplink] 选中档位 \(tier.kind.rawValue) \(rtt)ms \(tier.url.absoluteString)")
        return tier
    }

    /// 退到后台：基址立刻作废（`isReady` 跟着为假），但**留着票据** ——
    /// 15 分钟的有效期让回前台重连少一次换票往返。
    public func suspend() {
        baseURL = nil
        currentTier = nil
    }

    /// 彻底清空（切换配对 / 断开连接时）。
    public func reset() {
        baseURL = nil
        currentTier = nil
        ticket = nil
        ticketExpiry = nil
        ticketExpiresAt = nil
        lastError = nil
        lastSwitchReason = nil
        tierRTTs = [:]
    }

    // MARK: 票据

    /// 缓存里的鉴权头（同步）。没换到票时返回空字典。
    public func headers() -> [String: String] {
        guard let ticket else { return [:] }
        return ["Authorization": "Bearer \(ticket)"]
    }

    /// 给 `HostCoordinator` 用：到期前 60 秒先续一张。
    ///
    /// 续失败**不报错也不清缓存**：旧票只要还没过期就继续能用，
    /// 真过期了网关会 401，由 `sendWithTicket` 兜底重换。
    public func headersRefreshingIfNeeded() async -> [String: String] {
        if needsRefresh { _ = try? await exchangeTicket() }
        return headers()
    }

    private var needsRefresh: Bool {
        guard ticket != nil, let ticketExpiry else { return true }
        return ticketExpiry.timeIntervalSince(now()) <= Self.refreshLead
    }

    /// 换一张票。
    ///
    /// `POST <url>/uplink/auth {deviceId, ts, nonce, proof}`，
    /// `proof = hex(HMAC-SHA256(key=hex(secret), "auth|deviceId|ts|nonce"))`。
    /// 长期密钥不上网，只用来算这一条应答（`auth.js` 的设计要点）。
    @discardableResult
    public func exchangeTicket() async throws -> String {
        guard let tier = currentTier, let pairing = store.loadPairing() else {
            throw UplinkError.noTierAvailable
        }
        let ts = Int64(now().timeIntervalSince1970 * 1000)
        let nonce = UplinkCrypto.makeNonce()
        guard let proof = UplinkCrypto.proof(
            secret: pairing.secret, deviceId: pairing.deviceId, ts: ts, nonce: nonce
        ) else {
            throw UplinkError.badPairing
        }
        struct Body: Encodable {
            let deviceId: String
            let ts: Int64
            let nonce: String
            let proof: String
        }
        var request = URLRequest(url: Self.endpoint(tier.url, "uplink/auth"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            Body(deviceId: pairing.deviceId, ts: ts, nonce: nonce, proof: proof)
        )
        request.timeoutInterval = 10

        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            let reason = Self.reason(in: data)
            if response.statusCode == 401 {
                throw UplinkError.unauthorized(reason.isEmpty ? "bad-proof" : reason)
            }
            throw UplinkError.http(status: response.statusCode)
        }
        struct Reply: Decodable {
            let ok: Bool?
            let ticket: String?
            let ttl: Int?
            let reason: String?
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw UplinkError.badResponse(String(localized: "不是 JSON"))
        }
        guard reply.ok == true, let issued = reply.ticket, !issued.isEmpty else {
            throw UplinkError.unauthorized(reply.reason ?? "bad-proof")
        }
        let ttl = Double(reply.ttl ?? 900_000) / 1000
        self.ticket = issued
        self.ticketExpiry = now().addingTimeInterval(ttl)
        self.ticketExpiresAt = self.ticketExpiry
        logger?.log(.debug, "[uplink] 换票成功，\(Int(ttl)) 秒有效")
        return issued
    }

    /// 带票据的请求。**401 时清掉缓存、重换一次票再重试**；第二次还是 401 才算失败。
    ///
    /// 为什么只重试一次：401 有两种成因 —— "票据过期 / 电脑端轮换了密钥"（重换就好）
    /// 和"这台设备被撤销"（换多少次都没用）。只重一次既能自愈前者，
    /// 又不会在后者上打出一串没意义的请求（电脑端对失败还有 10 次/分钟的限流）。
    ///
    /// 注意：DSH 的 RPC 面是 DSHKit 直接发请求的，这里插不进去（协议层一行不改），
    /// 所以 RPC 的票据靠 `headersRefreshingIfNeeded` 提前续期规避过期。
    public func sendWithTicket(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var first = request
        if let header = (await headersRefreshingIfNeeded())["Authorization"] {
            first.setValue(header, forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await send(first)
        guard response.statusCode == 401 else { return (data, response) }

        logger?.log(.debug, "[uplink] 票据被拒（401），清缓存重换一次")
        ticket = nil
        ticketExpiry = nil
        ticketExpiresAt = nil
        _ = try? await exchangeTicket()

        var retry = request
        if let header = headers()["Authorization"] {
            retry.setValue(header, forHTTPHeaderField: "Authorization")
        }
        let (retryData, retryResponse) = try await send(retry)
        guard retryResponse.statusCode != 401 else {
            let reason = Self.reason(in: retryData)
            throw UplinkError.ticketRejected(reason.isEmpty ? "unauthorized" : reason)
        }
        return (retryData, retryResponse)
    }

    // MARK: 诊断

    /// 每个档位一行，给诊断页用。
    public struct TierStatus: Identifiable, Sendable {
        public let tier: UplinkTier
        public let enabled: Bool
        public let rttMilliseconds: Int?
        public let isCurrent: Bool
        public var id: String { tier.id }
    }

    public var tierStatuses: [TierStatus] {
        let current = currentTier
        return (pairing?.tiers ?? []).map { tier in
            TierStatus(
                tier: tier,
                enabled: isEnabled(tier),
                rttMilliseconds: tierRTTs[tier.kind.rawValue],
                isCurrent: current == tier
            )
        }
    }

    /// 票据还剩多少秒（诊断页用）。没换到票时 nil。
    public var ticketRemainingSeconds: Int? {
        guard let ticketExpiry, ticket != nil else { return nil }
        return max(0, Int(ticketExpiry.timeIntervalSince(now())))
    }

    // MARK: 内部

    /// 档位是否允许使用。空集合 = 还没设置过 → 全开
    /// （新装用户不该看到"什么都没开"这种死局）。
    ///
    /// 一个地址可能属于多档（内网段分不出局域网与 ZeroTier，见
    /// `UplinkTierKind.infer`），所以是"任一开着就算开"。
    private func isEnabled(_ tier: UplinkTier) -> Bool {
        let enabled = settings.uplinkEnabledTiers
        guard !enabled.isEmpty else { return true }
        return tier.kinds.contains { enabled.contains($0.rawValue) }
    }

    private func enabledTiers(of pairing: UplinkPairing) -> [UplinkTier] {
        pairing.tiers.filter(isEnabled)
    }

    private func stickyTier(in candidates: [UplinkTier]) -> UplinkTier? {
        guard let kind = settings.uplinkLastGoodTier,
              let until = settings.uplinkStickyUntil,
              until > now() else { return nil }
        return candidates.first { $0.kind.rawValue == kind }
    }

    /// 并行探所有档位，**全部返回后再挑最快的**。
    ///
    /// 为什么不像"先到先得"那样一有结果就收工：每档都有自己的 800ms 上限，
    /// 所以最坏只等 800ms（和单档探测一个量级），但能拿到**每一档**的 RTT ——
    /// 诊断页"各档 RTT"才有内容，用户也才看得出"局域网 4ms、Tailscale 90ms"。
    private func race(_ tiers: [UplinkTier], hostId: String) async -> [(UplinkTier, Int)] {
        let probe = self.probe
        return await withTaskGroup(of: (UplinkTier, Int)?.self) { group in
            for tier in tiers {
                group.addTask {
                    guard let rtt = await probe(tier, hostId) else { return nil }
                    return (tier, rtt)
                }
            }
            var succeeded: [(UplinkTier, Int)] = []
            for await result in group {
                if let result { succeeded.append(result) }
            }
            return succeeded
        }
    }

    /// 最快者胜；RTT 相同（同机同网很常见，都是 1~2ms）时按档位优先级。
    static func fastest(_ results: [(UplinkTier, Int)]) -> (UplinkTier, Int)? {
        results.min { lhs, rhs in
            lhs.1 != rhs.1 ? lhs.1 < rhs.1 : lhs.0.kind.priority < rhs.0.kind.priority
        }
    }

    nonisolated private static func endpoint(_ base: URL, _ path: String) -> URL {
        var url = base
        for segment in path.split(separator: "/") {
            url.appendPathComponent(String(segment))
        }
        return url
    }

    nonisolated private static func reason(in data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reason = object["reason"] as? String else { return "" }
        return reason
    }

    // MARK: 默认实现

    /// `GET <url>/uplink/ping` → `{ok, hostId, v}`（免票）。
    ///
    /// **必须核对 hostId**：同一网段里可能有好几台跑 dsh 的电脑，
    /// 连错人比连不上更糟（会把配对串里的 secret 交给别人算应答）。
    public nonisolated static func httpProbe(tier: UplinkTier, expectedHostId: String) async -> Int? {
        var request = URLRequest(url: endpoint(tier.url, "uplink/ping"))
        request.timeoutInterval = probeTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let started = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            guard object["ok"] as? Bool == true else { return nil }
            if let got = object["hostId"] as? String, got != expectedHostId { return nil }
            return max(1, Int(Date().timeIntervalSince(started) * 1000))
        } catch {
            return nil
        }
    }

    public nonisolated static func urlSessionSend(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UplinkError.badResponse(String(localized: "不是 HTTP 响应"))
        }
        return (data, http)
    }
}
