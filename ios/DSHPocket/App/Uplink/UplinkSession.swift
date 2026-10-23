import DSHKit
import Foundation
import Observation

/// 多路接入的**会话层**：探测选档 → 换票 → 供 `HostCoordinator` 读基址与鉴权头。
///
/// 它只解决"怎么连"这一件事：
///   · 按**当前网络类型**先筛掉物理上不可达的档（蜂窝下不探局域网）；
///   · 并行探测配对串里的所有地址，选最快通的那个（800ms 上限）；
///   · 全都不通时跑一次 Bonjour 发现，拿"电脑现在的真实地址"再探一次
///     （配对串里的地址只是配对那一刻的快照，DHCP 一换就失效）；
///   · 用 per-device secret 换一张 900 秒的票据，到期前 60 秒自动续；
///   · 401 时清缓存、重换一次再试，第二次仍 401 才报错。
///
/// **协议层一行不改**：对 DSHKit 来说，这里最终只是"一个 baseURL + 一个 Authorization 头"。
///
/// 注意 `baseURL` 是**本地回环代理**（`http://127.0.0.1:<port>`），不是远端地址：
/// ATS 只放行本地地址，Tailscale 的 100.64/10 与公网 IP 的明文 http 会被 -1022 拒掉。
/// 远端地址在 `currentTier.url` 里，只用于展示与日志。
///
/// 为什么把探测与 HTTP 都做成可注入的闭包：单测要能在毫秒级验证"选最快""粘滞优先"
/// "401 只重换一次"，而这些在真实网络里既慢又不可控（见 `UplinkTests`）。
@MainActor
@Observable
public final class UplinkSession {
    // MARK: 可注入的接缝

    /// 探一个档位。第二个参数是配对串里的 hostId —— 探到"另一台电脑"必须判失败。
    ///
    /// 返回值是 `UplinkProbeResult` 而不是 `Int?`：失败**原因**和"通不通"一样重要
    /// （超时 / 被拒 / 没网 / 认错电脑，四种修法完全不同）。
    public typealias Probe = @Sendable (UplinkTier, String) async -> UplinkProbeResult
    /// 发一个 HTTP 请求。单测用它造假响应。
    public typealias Send = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Bonjour 发现：给 hostId，返回它现在的候选地址。找不到返回空数组。
    public typealias Discover = @Sendable (String) async -> [UplinkTier]

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
    /// Bonjour 发现的等待上限。mDNS 正常是几十毫秒，1.5 秒是给"第一次查询、
    /// 缓存空、要等一次应答周期"留的余量；再长就等于用户按了没反应。
    public static let discoveryTimeout: TimeInterval = 1.5
    /// 发现结果的有效期。DHCP 租约通常几小时，但换 SSID/换网是随时的事，
    /// 10 分钟之后就当它过期，宁可重新发现一次（1.5 秒）也不要用一个死地址。
    public static let discoveredTTL: TimeInterval = 600

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
    /// 每个档位最近一次失败的**原因**。键同上。
    /// 这是"探测失败"从一句话变成可排障信息的关键：超时和被拒要分得开。
    public private(set) var tierFailures: [String: UplinkProbeFailure] = [:]
    /// Bonjour 发现到的地址（本次会话内）。诊断页要能看到"这些不是配对串里的"。
    public private(set) var discoveredTiers: [UplinkTier] = []
    /// 当前网络类型（诊断页显示）。
    public var networkKind: UplinkNetworkKind { network.kind }
    /// 票据到期时间（诊断页用）。
    public private(set) var ticketExpiresAt: Date?
    /// 上次 settle 成功的时间与当时的网络指纹（幂等守卫用）。
    private var lastSettledAt: Date?
    private var lastSettledFingerprint: String?
    public private(set) var isConnecting = false

    // MARK: 依赖

    private let store: UplinkCredentialStore
    private let settings: AppSettings
    private let logger: (any DSHLogSink)?
    private let probe: Probe
    private let send: Send
    private let discover: Discover
    private let now: () -> Date
    /// 网络类型监控。**只用来筛掉物理上不可达的档**，不参与选档策略。
    private let network: UplinkNetworkMonitor
    /// `127.0.0.1:<port>` → 选中那一档。所有 HTTP / WebSocket 都从这里出去
    /// （ATS 只放行回环，见 `UplinkLocalProxy` 的说明）。
    private let proxy = UplinkLocalProxy()

    private var ticket: String?
    private var ticketExpiry: Date?

    public init(
        store: UplinkCredentialStore,
        settings: AppSettings,
        logger: (any DSHLogSink)? = nil,
        // 用闭包字面量而不是直接引用静态方法：直接引用会被推断成
        // 非 `@Sendable` 的函数值（编译告警），而这两者都要跨任务组使用。
        probe: @escaping Probe = { tier, hostId in
            // **不能用 URLSession 探**：ATS 会把 100.64/10（Tailscale）与公网 IP
            // 的明文 http 判成 -1022，那两档就永远探不通。Network 框架不过 ATS。
            await UplinkTCPProbe.ping(tier: tier, expectedHostId: hostId, timeout: probeTimeout)
        },
        send: @escaping Send = { request in
            try await UplinkSession.urlSessionSend(request)
        },
        discover: @escaping Discover = { hostId in
            await UplinkBonjourBrowser.browse(hostId: hostId, timeout: UplinkSession.discoveryTimeout)
        },
        network: UplinkNetworkMonitor? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        self.store = store
        self.settings = settings
        self.logger = logger
        self.probe = probe
        self.send = send
        self.discover = discover
        self.network = network ?? UplinkNetworkMonitor()
        self.now = now
    }

    /// 开始监听网络类型。由 `AppModel.start()` 调；单测不调（它们注入固定的网络类型）。
    public func startNetworkMonitoring() {
        network.start()
    }

    public func stopNetworkMonitoring() {
        network.stop()
    }

    // MARK: 配对

    public var pairing: UplinkPairing? { store.loadPairing() }
    public var isPaired: Bool { pairing != nil }

    /// 采纳一段配对串。失败返回 nil，并把原因放进 `lastError`。
    @discardableResult
    public func adopt(_ text: String) async -> UplinkPairing? {
        guard let pairing = UplinkPairing.parse(text) else {
            lastError = UplinkError.badPairing.errorDescription
            return nil
        }
        await reset()
        store.save(pairing)
        // 换了一台电脑（或同一台重新配对）：上一台的 lastGood 不再有意义。
        settings.uplinkLastGoodTier = nil
        settings.uplinkStickyUntil = nil
        lastError = nil
        logger?.log(.info, "[uplink] 已配对 \(pairing.hostId.prefix(8))…（\(pairing.urls.count) 个地址）")
        return pairing
    }

    public func forget() async {
        store.clear()
        await reset()
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
        // **幂等守卫**（真机日志的教训）：配对完成与回前台各触发一次 connect，
        // 每次都重新探测 + 重建代理 → 正在跑的 WebSocket 被自己人打断
        //（`mux 断开（连了 1.9s）`）。已经连在同一档、同一网络、还在粘滞窗口内，
        // 就什么都不做，直接返回当前基址。
        if let existing = currentTier, baseURL != nil, isSettledRecently, fingerprintMatches {
            logger?.log(.debug, "[uplink] 已经连在 \(existing.kind.rawValue) 上，跳过这次探测")
            return existing
        }
        return await probeAndSettle()
    }

    /// **显式重建**：只有四种情况该走它 ——
    /// 健康检查失败 / 用户点「重新探测」/ 换网（指纹变了）/ 用户换档。
    ///
    /// 为什么单独开一个入口而不是给 `connect()` 加参数：幂等是默认行为，
    /// 谁要打破它就必须**说出来**（调用点一眼能看出这是有意为之）。
    @discardableResult
    public func reconnect(reason: String) async -> UplinkTier? {
        logger?.log(.info, "[uplink] 重建连接：\(reason)")
        return await probeAndSettle()
    }

    /// 上次成功 settle 到现在是否还在粘滞窗口内。
    private var isSettledRecently: Bool {
        guard let lastSettledAt else { return false }
        return now().timeIntervalSince(lastSettledAt) < Self.stickyWindow
    }

    /// 网络"指纹"是否与上次连上时一致。
    ///
    /// 只认**网络类型**（Wi-Fi / 蜂窝 / 有线）这一级：这是 `NWPathMonitor` 能稳定
    /// 给出的信息，也是"换网之后旧地址会失效"最常见的那一类。同一个 Wi-Fi 下换了
    /// SSID（局域网段变了）不会被发现 —— 那种情况由探测失败后的 Bonjour 重新发现兜住。
    private var fingerprintMatches: Bool {
        lastSettledFingerprint == network.kind.rawValue
    }

    private func probeAndSettle() async -> UplinkTier? {
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

        // ① 先按**当前网络类型**筛一遍。蜂窝下探私有地址是纯粹的白等：
        //    800ms 超时、电脑侧一个包都收不到，还给人一句误导的"超时"。
        //    冷启动时监控可能还没回第一条，先等一眼（监控没启动时立刻返回）。
        await network.waitForFirstUpdate()
        let kind = network.kind
        if kind == .offline {
            lastError = Self.noUsableTierMessage(for: kind, skipped: 0)
            lastSwitchReason = lastError
            logger?.log(.warning, "[uplink] 网络不可用（offline），不探测")
            return nil
        }
        let all = enabledTiers(of: pairing) + cachedDiscoveredTiers()
        guard !all.isEmpty else {
            lastError = String(localized: "所有档位都被关掉了。至少打开一个，或者换回 iroh。")
            return nil
        }
        let usable = all.filter { !shouldSkip($0, on: kind) }
        let skipped = all.filter { shouldSkip($0, on: kind) }
        if !skipped.isEmpty {
            logger?.log(.info, "[uplink] 当前在\(kind.resolvedLabel)，跳过局域网档 \(skipped.count) 个")
        }
        guard !usable.isEmpty else {
            // 全部被跳过：**立刻失败**，别让用户盯着"连接中"等一轮毫无意义的超时。
            lastError = Self.noUsableTierMessage(for: kind, skipped: skipped.count)
            lastSwitchReason = lastError
            logger?.log(.warning, "[uplink] 没有可探测的档位（\(kind.rawValue)，跳过 \(skipped.count) 个）")
            return nil
        }

        // ② 粘滞档位单独先探（它刚才就通，多半还通）。
        if let sticky = stickyTier(in: usable) {
            let result = await probe(sticky, pairing.hostId)
            record(sticky, result)
            if let rtt = result.rtt {
                logger?.log(.debug, "[uplink] 粘滞命中 \(sticky.kind.rawValue) \(rtt)ms")
                return await settle(on: sticky, rtt: rtt, reason: nil)
            }
            logger?.log(.debug, "[uplink] 粘滞档位 \(sticky.kind.rawValue) 这次没通，改为并行探测")
        }

        // ③ 并行探快照里的地址。
        let snapshot = await probeAll(usable, hostId: pairing.hostId)
        if let winner = snapshot.winner {
            return await settle(on: winner.0, rtt: winner.1, reason: switchReason(winner.0))
        }

        // ④ 快照全不可达 → Bonjour 重新发现（配对串里的地址只是**配对那一刻**的快照，
        //    DHCP 续租/换 SSID 之后它就已经死了，而手机没有任何别的办法知道新地址）。
        var failures = snapshot.failures
        var discovered: [UplinkTier] = []
        if kind.isLocalNetwork {
            logger?.log(.info, "[uplink] 快照地址全部不可达，开始 Bonjour 发现")
            discovered = await discover(pairing.hostId)
            logger?.log(.info, "[uplink] Bonjour 发现到 \(discovered.count) 个地址")
        } else {
            logger?.log(.info, "[uplink] 当前不是本地网络（\(kind.rawValue)），跳过 Bonjour 发现")
        }

        if !discovered.isEmpty {
            discoveredTiers = UplinkBonjour.merge(discoveredTiers, discovered)
            // 发现的地址即使这次没通也先记下来（带时间戳，10 分钟就过期）：
            // 下次连的时候它就是一个免费候选，省掉一次 1.5 秒的发现。
            store.saveDiscovered(discovered, at: now())

            let known = Set(usable.map { UplinkPairing.normalized($0.url.absoluteString) })
            let fresh = discovered.filter {
                !known.contains(UplinkPairing.normalized($0.url.absoluteString))
            }.filter { !shouldSkip($0, on: kind) }
            if !fresh.isEmpty {
                let second = await probeAll(fresh, hostId: pairing.hostId)
                if let winner = second.winner {
                    // 通了才**回写**配对材料：把死地址写进去只会让下次多探一个必超时的候选。
                    let merged = pairing.merging(tiers: discovered)
                    if merged != pairing { store.save(merged) }
                    return await settle(on: winner.0, rtt: winner.1, reason: switchReason(winner.0))
                }
                failures += second.failures
            }
        }

        // ⑤ 如实报告：**按失败原因分类**给建议，而不是一句"都失败了"。
        lastError = UplinkProbeFailure.summary(for: failures.map(\.1))
        lastSwitchReason = lastError
        logger?.log(.warning, "[uplink] 所有档位都探测失败（\(failures.count) 个）：\(failures.map { "\($0.0.kind.rawValue)=\($0.1.logLabel)" }.joined(separator: "，"))")
        return nil
    }

    /// 一次探测的结果落到诊断状态里。RTT 与失败原因**互斥** ——
    /// 留着上一轮的 RTT 会让人以为"这档刚才还通"。
    private func record(_ tier: UplinkTier, _ result: UplinkProbeResult) {
        switch result {
        case .reachable(let rtt):
            tierRTTs[tier.kind.rawValue] = rtt
            tierFailures[tier.kind.rawValue] = nil
        case .unreachable(let failure):
            tierRTTs[tier.kind.rawValue] = nil
            tierFailures[tier.kind.rawValue] = failure
            logger?.log(.info, "[uplink] 探测失败 \(tier.kind.rawValue) \(tier.url.absoluteString)：\(failure.logLabel)")
        }
    }

    /// 并行探一批档位，返回最快的成功者与全部失败原因。
    private func probeAll(
        _ tiers: [UplinkTier],
        hostId: String
    ) async -> (winner: (UplinkTier, Int)?, failures: [(UplinkTier, UplinkProbeFailure)]) {
        let results = await race(tiers, hostId: hostId)
        var succeeded: [(UplinkTier, Int)] = []
        var failures: [(UplinkTier, UplinkProbeFailure)] = []
        for (tier, result) in results {
            record(tier, result)
            switch result {
            case .reachable(let rtt):
                succeeded.append((tier, rtt))
            case .unreachable(let failure):
                failures.append((tier, failure))
            }
        }
        return (Self.fastest(succeeded), failures)
    }

    /// 上一次用的档位这次没通、换到别的档时给诊断页的一句话。
    private func switchReason(_ tier: UplinkTier) -> String? {
        guard let previous = settings.uplinkLastGoodTier, previous != tier.kind.rawValue else {
            return nil
        }
        return String(localized: "上一次用的 \(previous) 这次没通，换到 \(tier.kind.resolvedLabel)")
    }

    /// 这一档在当前网络下要不要跳过。
    ///
    /// 只跳**局域网**：Tailscale / ZeroTier / 自建中转都建立在自己的隧道或公网上，
    /// 蜂窝下照样能用（`frp` 尤其 —— 它存在的意义就是"在外面也能连"）。
    ///
    /// 边界：老配对串没有 `tiers` 时，ZeroTier 的 10.x 地址会被推断成 `.lan`，
    /// 于是蜂窝下也被跳过。电脑端现在会在配对串里带 kind（`descriptor.js` 的 `tiers`），
    /// 那时 `kind == .zerotier`，就不会被误跳。
    private func shouldSkip(_ tier: UplinkTier, on kind: UplinkNetworkKind) -> Bool {
        guard kind.skipsLocalTiers else { return false }
        return tier.kind == .lan
    }

    /// 没有任何档位可探时的文案。**按网络类型分支** —— 蜂窝下那句必须说清
    /// "要配 iroh / Tailscale / 自建中转"，否则用户只会以为 App 坏了。
    static func noUsableTierMessage(for kind: UplinkNetworkKind, skipped: Int) -> String {
        switch kind {
        case .cellular:
            return String(localized: "当前在蜂窝网络，局域网地址不可达。需要配置 iroh 兜底 / Tailscale / 自建中转才能在外面连。")
        case .offline:
            return String(localized: "手机现在没有网络连接。先确认 Wi-Fi 或蜂窝数据是开的。")
        default:
            return String(localized: "当前网络下没有可用的地址（跳过 \(String(skipped)) 个档位）。")
        }
    }

    /// 上次 Bonjour 发现到的地址（未过期才用）。
    private func cachedDiscoveredTiers() -> [UplinkTier] {
        guard let cached = store.loadDiscovered() else { return [] }
        guard now().timeIntervalSince(cached.at) < Self.discoveredTTL else { return [] }
        return cached.tiers
    }

    /// 选定了档位之后：起本地代理 → 换票 → 落 lastGood → 暴露基址。
    private func settle(on tier: UplinkTier, rtt: Int, reason: String?) async -> UplinkTier? {
        guard let target = UplinkLocalProxy.Target(url: tier.url) else {
            lastError = String(localized: "这一档的地址解析不出 host/port，已跳过。")
            lastSwitchReason = lastError
            return nil
        }
        do {
            // 先把回环代理指向这一档：之后的换票、RPC、WebSocket 全部经过它。
            baseURL = try await proxy.start(target: target)
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastSwitchReason = lastError
            logger?.log(.warning, "[uplink] 本地代理起不来（\(tier.kind.rawValue)）：\(lastError ?? "—")")
            return nil
        }
        currentTier = tier
        tierRTTs[tier.kind.rawValue] = rtt
        do {
            _ = try await exchangeTicket()
        } catch {
            // 地址通了但换不到票：这台电脑在，但我们的 secret 不被接受
            //（被撤销 / 电脑端重装过插件 / 两边时钟差太多）。
            // **不静默降级** —— 换条路能不能用是 AppModel 的决定，这里只如实报告。
            currentTier = nil
            baseURL = nil
            await proxy.stop()
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastSwitchReason = lastError
            logger?.log(.warning, "[uplink] 换票失败（\(tier.kind.rawValue)）：\(lastError ?? "—")")
            return nil
        }
        settings.uplinkLastGoodTier = tier.kind.rawValue
        settings.uplinkStickyUntil = now().addingTimeInterval(Self.stickyWindow)
        lastSettledAt = now()
        lastSettledFingerprint = network.kind.rawValue
        if let reason { lastSwitchReason = reason }
        lastError = nil
        logger?.log(.info, "[uplink] 选中档位 \(tier.kind.rawValue) \(rtt)ms \(tier.url.absoluteString)")
        return tier
    }

    /// 退到后台：基址立刻作废（`isReady` 跟着为假）、代理收掉，
    /// 但**留着票据** —— 15 分钟的有效期让回前台重连少一次换票往返。
    public func suspend() async {
        baseURL = nil
        currentTier = nil
        lastSettledAt = nil
        lastSettledFingerprint = nil
        await proxy.stop()
    }

    /// 彻底清空（切换配对 / 断开连接时）。
    public func reset() async {
        await proxy.stop()
        baseURL = nil
        currentTier = nil
        lastSettledAt = nil
        lastSettledFingerprint = nil
        ticket = nil
        ticketExpiry = nil
        ticketExpiresAt = nil
        lastError = nil
        lastSwitchReason = nil
        tierRTTs = [:]
        tierFailures = [:]
        discoveredTiers = []
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
        // 走 `baseURL`（回环代理），不是 `tier.url` —— 远端可能是 tailnet / 公网 IP，
        // 直连会被 ATS 判 -1022。
        guard let baseURL, let pairing = store.loadPairing() else {
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
        var request = URLRequest(url: Self.endpoint(baseURL, "uplink/auth"))
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

    /// 用当前票据换一张 **iroh 配对窗口**（`POST /uplink/iroh-pairing`）。
    ///
    /// 有了它，iroh 兜底不再需要用户"去电脑上开窗口抄 6 位码"：
    /// 电脑端自己起 sidecar、把 `endpointId#code` 交给我们。
    ///
    /// 前提是**手上有一张能用的票**：票据只能在已配对、且当前可达的地址上换到。
    /// 一个地址都不通时这里直接抛 `.noTicket` —— 假装在重试没有意义。
    public func requestIrohPairing() async throws -> UplinkIrohPairing {
        guard let baseURL else {
            throw UplinkIrohPairingError.noTicket
        }
        var request = URLRequest(url: Self.endpoint(baseURL, "uplink/iroh-pairing"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10

        let (data, response) = try await sendWithTicket(request)
        switch response.statusCode {
        case 200:
            break
        case 503:
            // 电脑端没跑 iroh 档。这一档就是不可用 —— **不重试**。
            throw UplinkIrohPairingError.unavailable
        default:
            throw UplinkIrohPairingError.failed("http-\(response.statusCode)")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["ok"] as? Bool == true,
              let pairingString = object["pairingString"] as? String,
              let issued = UplinkIrohPairing(
                  pairingString: pairingString,
                  endpointId: object["endpointId"] as? String,
                  expiresInSec: object["expiresInSec"] as? Int ?? 0
              ) else {
            throw UplinkIrohPairingError.failed("bad-body")
        }
        logger?.log(.info, "[uplink] 拿到 iroh 配对窗口：\(issued.endpointId.prefix(16))…（\(issued.expiresInSec)s）")
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
        /// 最近一次探测失败的原因（没探过或探通了就是 nil）。
        public let failure: UplinkProbeFailure?
        /// 这一档被"当前网络类型"跳过了（例如蜂窝下的局域网）。
        public let skipReason: String?
        public let isCurrent: Bool
        public var id: String { tier.id }
    }

    public var tierStatuses: [TierStatus] {
        let current = currentTier
        let kind = network.kind
        // 配对串里的 + 本次发现到的：用户要知道"这个地址是哪来的"，
        // 也要能看出"发现了但没通"。
        let all = UplinkBonjour.merge(pairing?.tiers ?? [], discoveredTiers)
        return all.map { tier in
            let skipped = shouldSkip(tier, on: kind)
            return TierStatus(
                tier: tier,
                enabled: isEnabled(tier),
                rttMilliseconds: skipped ? nil : tierRTTs[tier.kind.rawValue],
                failure: skipped ? nil : tierFailures[tier.kind.rawValue],
                skipReason: skipped ? String(localized: "当前在蜂窝网络，局域网不可达") : nil,
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
    private func race(_ tiers: [UplinkTier], hostId: String) async -> [(UplinkTier, UplinkProbeResult)] {
        let probe = self.probe
        return await withTaskGroup(of: (UplinkTier, UplinkProbeResult).self) { group in
            for tier in tiers {
                group.addTask {
                    (tier, await probe(tier, hostId))
                }
            }
            var results: [(UplinkTier, UplinkProbeResult)] = []
            for await result in group { results.append(result) }
            return results
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

    public nonisolated static func urlSessionSend(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UplinkError.badResponse(String(localized: "不是 HTTP 响应"))
        }
        return (data, http)
    }
}
