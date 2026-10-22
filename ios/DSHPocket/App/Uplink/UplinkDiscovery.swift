import Foundation
import Network

/// Bonjour / mDNS **发现**：把"电脑现在到底在哪"从配对那一刻的快照里解出来。
///
/// 为什么必须有它（真机现场）：配对串里只记了配对那一刻的地址（`http://10.8.54.221:18788`）。
/// 电脑的 DHCP 租约一换、换个 SSID、手机出门用 5G —— 那个地址就永久失效了，
/// 而手机**没有任何办法知道新地址**，只能重新配对。电脑端其实一直在广播
/// `_dsh._tcp`（`lib/publish.js`），手机只要 browse 一次就能拿到当前真实地址。
///
/// ## 为什么用 `NetService` 而不是 `NWBrowser`
///
/// `NWBrowser` 的结果里只有**实例名 + TXT**，没有 SRV 的 host，也没有 A 记录 ——
/// 而我们要的恰恰是"这台电脑所有网卡的 IPv4"。用 `NWConnection` 连上去读
/// `currentPath.remoteEndpoint` 只能拿到**一条**（解析器挑的那条），
/// 多个网卡（Wi-Fi + Tailscale + 虚拟网桥）就只剩一个候选。
///
/// `NetService`（Bonjour 的 Objective-C 封装，底层是同一个 mDNSResponder）一次
/// resolve 就给全 `hostName` + `port` + 全部地址记录；再补一次 `getaddrinfo(hostName)`
/// 就是完整的 A 记录列表。代码还短得多。
///
/// ## 能测什么、不能测什么
///
/// 这里的**纯函数**（TXT 解析、sockaddr→IPv4、合并去重、getaddrinfo）有单测；
/// browse 本身需要一个真的 mDNS 应答者，CI 里没有，所以**不测** ——
/// 别为了覆盖率给它造一个假广播器，那测的是假广播器。
public enum UplinkBonjour {
    /// 与电脑端 `lib/publish.js` 的默认服务类型一致。
    public static let serviceType = "_dsh._tcp."
    public static let domain = "local."

    // MARK: TXT

    /// 解 TXT 记录：一串「长度字节 + 内容」，每段是 `key=value`。
    ///
    /// 电脑端广播的是 `id=<hostId>`、`port=<端口>`、`v=<版本>`（见 publish.js）。
    /// `id` 是唯一能把"这条广播"对上"我配对的是哪台电脑"的字段 ——
    /// 同一网段里可能有好几台跑 dsh 的机器。
    public static func parseTXT(_ data: Data) -> [String: String] {
        var out: [String: String] = [:]
        var index = data.startIndex
        while index < data.endIndex {
            let length = Int(data[index])
            index = data.index(after: index)
            guard length > 0, data.distance(from: index, to: data.endIndex) >= length else { break }
            let end = data.index(index, offsetBy: length)
            let entry = String(decoding: data[index..<end], as: UTF8.self)
            index = end
            if let separator = entry.firstIndex(of: "=") {
                let key = String(entry[entry.startIndex..<separator]).lowercased()
                out[key] = String(entry[entry.index(after: separator)...])
            } else {
                out[entry.lowercased()] = ""
            }
        }
        return out
    }

    // MARK: 地址

    /// 从一条 `sockaddr` 数据里取 IPv4。
    ///
    /// 先 `copyBytes` 到对齐的 `sockaddr_in` 里再读 —— 直接 `assumingMemoryBound`
    /// 拿 `Data` 的裸指针在未对齐时是未定义行为（真机偶发崩溃的经典来源）。
    public static func ipv4(from sockaddrData: Data) -> String? {
        guard sockaddrData.count >= MemoryLayout<sockaddr_in>.size else { return nil }
        var address = sockaddr_in()
        withUnsafeMutableBytes(of: &address) { destination in
            _ = sockaddrData.copyBytes(to: destination, count: min(sockaddrData.count, destination.count))
        }
        guard address.sin_family == sa_family_t(AF_INET) else { return nil }
        var raw = address.sin_addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &raw, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        let text = String(cString: buffer)
        return text.isEmpty ? nil : text
    }

    /// 一串 `sockaddr` → 去重后的 IPv4 列表。回环与 `0.0.0.0` 丢掉：
    /// 从手机的角度看它们永远指自己，探了只会白白超时。
    public static func ipv4Addresses(from sockaddrs: [Data]) -> [String] {
        var out: [String] = []
        for data in sockaddrs {
            guard let address = ipv4(from: data) else { continue }
            if address == "0.0.0.0" || address.hasPrefix("127.") { continue }
            if !out.contains(address) { out.append(address) }
        }
        return out
    }

    /// 用 `getaddrinfo` 解析一个主机名（形如 `MacBook-Pro.local.`），拿**全部** IPv4。
    ///
    /// 这是"多个 IP 就多个候选"的来源：`publish.js` 会把本机所有私有地址都写成
    /// A 记录（Wi-Fi + Tailscale + 虚拟网桥），只取第一条等于自己扔掉备选。
    public static func resolve(hostName: String) -> [String] {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_INET,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(hostName, nil, &hints, &result) == 0, let head = result else { return [] }
        defer { freeaddrinfo(head) }
        var out: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = head
        while let info = cursor {
            defer { cursor = info.pointee.ai_next }
            guard let address = info.pointee.ai_addr else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                address, info.pointee.ai_addrlen,
                &buffer, socklen_t(buffer.count),
                nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }
            let text = String(cString: buffer)
            if text.isEmpty || text.hasPrefix("127.") || text == "0.0.0.0" { continue }
            if !out.contains(text) { out.append(text) }
        }
        return out
    }

    // MARK: 组装

    /// 地址 + 端口 → 候选档位。kind 按地址段推断（Bonjour 的 TXT 里没有 kind）。
    public static func tiers(addresses: [String], port: Int) -> [UplinkTier] {
        guard port > 0, port <= 65535 else { return [] }
        return addresses.compactMap { address in
            guard let url = URL(string: "http://\(address):\(port)") else { return nil }
            return UplinkTier(kind: UplinkTierKind.infer(from: url), url: url)
        }
    }

    /// 合并两批档位：**按 URL 去重，先来的赢**（它带着更可信的 kind）。
    ///
    /// 配对串里的地址是"当时"的、带电脑端给的 kind；发现到的是"现在"的、kind 靠推断。
    /// 同一个 URL 出现两次时保留前者，逐档开关才不会被推断结果带偏。
    public static func merge(_ base: [UplinkTier], _ extra: [UplinkTier]) -> [UplinkTier] {
        var seen = Set(base.map { UplinkPairing.normalized($0.url.absoluteString) })
        var out = base
        for tier in extra {
            let key = UplinkPairing.normalized(tier.url.absoluteString)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(tier)
        }
        return out.sorted { lhs, rhs in
            lhs.kind.priority != rhs.kind.priority
                ? lhs.kind.priority < rhs.kind.priority
                : lhs.url.absoluteString < rhs.url.absoluteString
        }
    }
}

// MARK: - 浏览器

/// 一次 browse 的生命周期。
///
/// 为什么是一个 class 而不是几个 async 函数：`NetServiceBrowser` 是**回调 + runloop**
/// 的世界，delegate 必须在调用期间活着；用 continuation 把它包成一次 await 最省事。
@MainActor
public final class UplinkBonjourBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private var browser: NetServiceBrowser?
    private var pending: [NetService] = []
    private var found: [UplinkTier] = []
    private var expectedHostId = ""
    private var timeout: TimeInterval = 1.5
    private var continuation: CheckedContinuation<[UplinkTier], Never>?
    private var deadline: Task<Void, Never>?

    /// 找一台电脑的当前地址。找不到就返回空数组（**不抛**：发现失败不是错误路径，
    /// 调用方会用配对串里的旧地址兜底）。
    public static func browse(hostId: String, timeout: TimeInterval = 1.5) async -> [UplinkTier] {
        let browser = UplinkBonjourBrowser()
        return await browser.run(hostId: hostId, timeout: timeout)
    }

    private func run(hostId: String, timeout: TimeInterval) async -> [UplinkTier] {
        // 上一次还没收尾（调用方连按两次「重新探测」）：先把它落定，别把两个 continuation 搅在一起。
        finish()
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.expectedHostId = hostId
            self.timeout = timeout
            self.found = []
            self.pending = []

            let browser = NetServiceBrowser()
            browser.delegate = self
            self.browser = browser
            browser.searchForServices(ofType: UplinkBonjour.serviceType, inDomain: UplinkBonjour.domain)

            self.deadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                self?.finish()
            }
        }
    }

    /// 收尾：**幂等**。delegate 回调、超时、`stop()` 触发的停止搜索都会走到这里，
    /// 而 continuation 只能 resume 一次（resume 两次会直接崩）。
    private func finish() {
        deadline?.cancel()
        deadline = nil
        browser?.delegate = nil
        browser?.stop()
        browser = nil
        for service in pending {
            service.delegate = nil
            service.stop()
        }
        pending = []
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: found)
    }

    private func checkDone() {
        guard pending.isEmpty else { return }
        finish()
    }

    // MARK: 发现

    private func handleFound(_ service: NetService) {
        let txt = service.txtRecordData().map(UplinkBonjour.parseTXT) ?? [:]
        let id = txt["id"] ?? ""
        // hostId 对不上就是别的电脑：**不要**去 resolve 它，省一次解析也少一分暴露。
        guard expectedHostId.isEmpty || id == expectedHostId else { return }
        guard !pending.contains(where: { $0 === service }) else { return }
        pending.append(service)
        service.delegate = self
        service.resolve(withTimeout: timeout)
    }

    private func handleResolved(_ service: NetService) {
        pending.removeAll { $0 === service }
        let txt = service.txtRecordData().map(UplinkBonjour.parseTXT) ?? [:]
        let port = service.port > 0 ? service.port : (Int(txt["port"] ?? "") ?? 0)

        // 两条来源取并集：NetService 缓存里的地址，加上 getaddrinfo 现查的。
        // 只信前者会漏掉"缓存里只有一条"的情况；只信后者会在 mDNS 缓存过期时全空。
        var addresses = UplinkBonjour.ipv4Addresses(from: service.addresses ?? [])
        if let host = service.hostName {
            for address in UplinkBonjour.resolve(hostName: host) where !addresses.contains(address) {
                addresses.append(address)
            }
        }
        guard port > 0, !addresses.isEmpty else {
            checkDone()
            return
        }
        found = UplinkBonjour.merge(found, UplinkBonjour.tiers(addresses: addresses, port: port))
        checkDone()
    }

    // MARK: NetServiceBrowserDelegate

    public nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        // `NetServiceBrowser` 的回调落在**调度它的那个 runloop**（这里就是主 runloop），
        // 所以 assumeIsolated 是安全的，而且省掉一次 hop 带来的时序抖动。
        MainActor.assumeIsolated { self.handleFound(service) }
    }

    public nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        // 服务消失（电脑关机 / 换网）：已经收集到的地址留着 —— 这次探测会告诉我们它通不通。
    }

    public nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String: NSNumber]
    ) {
        MainActor.assumeIsolated { self.finish() }
    }

    public nonisolated func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        MainActor.assumeIsolated { self.finish() }
    }

    // MARK: NetServiceDelegate

    public nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        MainActor.assumeIsolated { self.handleResolved(sender) }
    }

    public nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        MainActor.assumeIsolated {
            self.pending.removeAll { $0 === sender }
            self.checkDone()
        }
    }
}
