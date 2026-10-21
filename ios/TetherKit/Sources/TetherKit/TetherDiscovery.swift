import Darwin
import Foundation

/// 电脑端发布在 iroh DNS 上的寻址信息：`relay=` 与若干 `addr=`。
///
/// 字段名对齐 iroh 的 TXT 记录格式（`iroh-dns/src/attrs.rs`：每条 TXT RR 是
/// 一个 `key=value`，key 用小写 kebab-case，可选值只有 `relay` / `addr` / `user-data`）。
public struct TetherAddressHint: Sendable, Equatable {
    /// 家中继的 URL，例如 `https://aps1-1.relay.n0.iroh.link./`。
    public var relayURL: String?
    /// 直连地址，`ip:port` 形式（iroh 的 `TransportAddr::Ip`）。
    public var addresses: [String]

    public init(relayURL: String? = nil, addresses: [String] = []) {
        self.relayURL = relayURL
        self.addresses = addresses
    }

    public var isEmpty: Bool { relayURL == nil && addresses.isEmpty }
}

/// 一次解析的结果，附带一行**给人看**的说明（直接进日志/诊断页）。
public struct TetherDiscoveryResult: Sendable, Equatable {
    public var hint: TetherAddressHint
    /// 例如 `腾讯 119.29.29.29 · 42ms · relay + 0 条直连`；失败时是失败原因。
    public var detail: String
    public var succeeded: Bool
}

/// 自己解析 `_iroh.<z32 端点 ID>.dns.iroh.link TXT`，**指定国内解析器**。
///
/// ## 为什么要自己解析
///
/// iroh 1.0.3 在 iOS 上拿不到系统 DNS 配置：`DnsResolver::new()` 先读
/// `/etc/resolv.conf`，iOS 沙箱里根本没有这个文件，于是退回 hickory 的
/// `ResolverConfig::default()` —— **硬编码的 8.8.8.8 / 8.8.4.4**。
/// 国内蜂窝网、以及带分流规则的 VPN 都会把发往 8.8.8.8 的 UDP/53 丢掉，
/// 现场表现就是每次建连卡满约 5.5 秒 DNS 超时，然后 iroh 报
/// `No addressing information available`，App 里显示成「找不到这台电脑的地址」。
///
/// 真机日志（2026-10-21）：VPN 开着时 11 次建连全部这样失败、持续 2.5 小时；
/// 关掉 VPN 后同一台电脑 1.1 秒就连上了 —— 电脑端和记录都是好的，卡的就是这一步。
///
/// ## 做了什么
///
/// 自己拼一个 DNS 查询（A 记录不够，要 TXT），用 UDP 直接发给指定的解析器
/// （默认腾讯 119.29.29.29、阿里 223.5.5.5），把 `relay=` / `addr=` 解析出来。
/// 上层据此构造一个**信息完整**的 `EndpointAddr` 交给 iroh，建连就完全不需要
/// iroh 自己的发现流程；解析失败时上层仍会回落到内置发现，所以最坏情况等于没改。
public enum TetherDiscovery {
    /// 解析器，按顺序尝试（并发发出，谁先回用谁）。
    ///
    /// 用两家的公共 DNS 而不是运营商下发的：运营商 DNS 对 `dns.iroh.link` 这类
    /// 境外域名经常不回 TXT 或直接超时，而这两家实测都能查到。
    public static let nameservers: [String] = ["119.29.29.29", "223.5.5.5"]

    /// 记录所在的域（与 iroh 的 `N0_DNS_ENDPOINT_ORIGIN_PROD` 一致）。
    public static let origin = "dns.iroh.link"

    /// 单次查询的超时。DNS 抖动是秒级的事，超过这个数就当它不通、让上层回落。
    public static let timeout: TimeInterval = 2.0

    // MARK: - z-base-32

    /// pkarr 用 z-base-32 编码端点 ID 当域名标签（`iroh-base` 的 `Z_BASE_32`）。
    ///
    /// 和常见的 base32 不同：字母表是 `ybndrfg8ejkmcpqxot1uwisza345h769`，
    /// 而且**位序是高位在前**（`data_encoding::new_encoding!` 的默认值）。
    /// 写错一个字符就查不到记录 —— 所以这里单独抽出来并配了单测。
    static let zBase32Alphabet = Array("ybndrfg8ejkmcpqxot1uwisza345h769")

    /// 64 位十六进制端点 ID → z-base-32 字符串（52 字符）。非法输入返回 nil。
    public static func z32(_ hexId: String) -> String? {
        guard let bytes = hexBytes(hexId) else { return nil }
        var output: [Character] = []
        var accumulator: UInt32 = 0
        var bits = 0
        for byte in bytes {
            accumulator = (accumulator << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                output.append(zBase32Alphabet[Int((accumulator >> UInt32(bits)) & 0x1F)])
            }
        }
        if bits > 0 {
            output.append(zBase32Alphabet[Int((accumulator << UInt32(5 - bits)) & 0x1F)])
        }
        return String(output)
    }

    static func hexBytes(_ hex: String) -> [UInt8]? {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard cleaned.count == 64, cleaned.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    /// 完整查询名：`_iroh.<z32>.dns.iroh.link`。
    public static func txtName(hostHexId: String) -> String? {
        guard let label = z32(hostHexId) else { return nil }
        return "_iroh.\(label).\(origin)"
    }

    // MARK: - 对外入口

    /// 解析一台电脑的寻址信息。
    ///
    /// 两个解析器并发发出，第一个成功的回答胜出；都失败就返回 `succeeded == false`
    /// 和一句可读的原因（调用方据此回落 iroh 内置发现，并把原因写进日志）。
    public static func resolve(hostHexId: String) async -> TetherDiscoveryResult {
        guard let name = txtName(hostHexId: hostHexId) else {
            return TetherDiscoveryResult(
                hint: TetherAddressHint(),
                detail: "端点 ID 不是合法的 64 位十六进制",
                succeeded: false
            )
        }
        guard let packet = makeQuery(name: name) else {
            return TetherDiscoveryResult(
                hint: TetherAddressHint(),
                detail: "查询报文构造失败",
                succeeded: false
            )
        }

        let started = Date()
        var lastFailure = "没有解析器返回结果"
        var sawTruncated = false

        let outcome: (server: String, data: [UInt8])? = await withTaskGroup(
            of: (String, [UInt8])?.self
        ) { group in
            for server in nameservers {
                group.addTask {
                    do {
                        return (server, try await queryUDP(server: server, packet: packet))
                    } catch {
                        return nil
                    }
                }
            }
            var winner: (String, [UInt8])?
            for await result in group {
                if let result, winner == nil {
                    winner = result
                    group.cancelAll()
                }
            }
            return winner
        }

        guard let outcome else {
            return TetherDiscoveryResult(
                hint: TetherAddressHint(),
                detail: "两个解析器都没回（\(lastFailure)）",
                succeeded: false
            )
        }

        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        switch parseAnswer(outcome.data) {
        case .failure(let reason):
            if reason.contains("截断") { sawTruncated = true }
            lastFailure = reason
            return TetherDiscoveryResult(
                hint: TetherAddressHint(),
                detail: "\(outcome.server) · \(elapsed)ms · \(lastFailure)\(sawTruncated ? "" : "")",
                succeeded: false
            )
        case .success(let hint):
            guard !hint.isEmpty else {
                return TetherDiscoveryResult(
                    hint: hint,
                    detail: "\(outcome.server) · \(elapsed)ms · 记录存在但没有任何地址",
                    succeeded: false
                )
            }
            var parts = ["\(outcome.server)", "\(elapsed)ms"]
            parts.append(hint.relayURL == nil ? "无 relay" : "relay")
            parts.append("\(hint.addresses.count) 条直连")
            return TetherDiscoveryResult(
                hint: hint,
                detail: parts.joined(separator: " · "),
                succeeded: true
            )
        }
    }

    // MARK: - 报文

    /// 构造一条 TXT 查询。
    ///
    /// 带一条 EDNS0 OPT（UDP 载荷 1232 字节）：iroh 的记录里可能同时有 relay 和多个
    /// 直连地址，512 字节的老上限容易被截断（截断的应答里拿不到完整信息）。
    static func makeQuery(name: String) -> [UInt8]? {
        var packet: [UInt8] = []
        let identifier = UInt16.random(in: 1...UInt16.max)
        packet.append(UInt8(identifier >> 8))
        packet.append(UInt8(identifier & 0xFF))
        packet.append(contentsOf: [0x01, 0x00])   // RD=1
        packet.append(contentsOf: [0x00, 0x01])   // QDCOUNT
        packet.append(contentsOf: [0x00, 0x00])   // ANCOUNT
        packet.append(contentsOf: [0x00, 0x00])   // NSCOUNT
        packet.append(contentsOf: [0x00, 0x01])   // ARCOUNT（OPT）

        for label in name.split(separator: ".") {
            guard label.utf8.count <= 63 else { return nil }
            packet.append(UInt8(label.utf8.count))
            packet.append(contentsOf: label.utf8)
        }
        packet.append(0x00)                        // 名字结束
        packet.append(contentsOf: [0x00, 0x10])    // QTYPE = TXT
        packet.append(contentsOf: [0x00, 0x01])    // QCLASS = IN

        // OPT：name=root、type=41、class=UDP 载荷大小、ttl=0、rdata 空
        packet.append(0x00)
        packet.append(contentsOf: [0x00, 0x29])
        packet.append(contentsOf: [0x04, 0xD0])    // 1232
        packet.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        packet.append(contentsOf: [0x00, 0x00])
        return packet
    }

    enum AnswerParse {
        case success(TetherAddressHint)
        case failure(String)
    }

    /// 解析应答，只取 TXT 记录里的 `relay=` / `addr=`。
    ///
    /// 名字可能是压缩指针，所以要按 DNS 的规则跳名字而不是"读到 0 为止"。
    static func parseAnswer(_ data: [UInt8]) -> AnswerParse {
        guard data.count >= 12 else { return .failure("应答太短") }
        let flags = UInt16(data[2]) << 8 | UInt16(data[3])
        if flags & 0x0200 != 0 { return .failure("应答被截断") }
        let rcode = flags & 0x000F
        let answerCount = Int(UInt16(data[6]) << 8 | UInt16(data[7]))
        let questionCount = Int(UInt16(data[4]) << 8 | UInt16(data[5]))

        if rcode != 0 {
            // 3 = NXDOMAIN：这台电脑还没发布记录（或发布已过期）。
            return .failure(rcode == 3 ? "记录不存在（NXDOMAIN）" : "解析器返回错误码 \(rcode)")
        }

        var offset = 12
        for _ in 0..<questionCount {
            guard let next = skipName(data, offset) else { return .failure("问题段损坏") }
            offset = next + 4
            guard offset <= data.count else { return .failure("问题段损坏") }
        }

        var hint = TetherAddressHint()
        for _ in 0..<answerCount {
            guard let afterName = skipName(data, offset) else { return .failure("应答段损坏") }
            offset = afterName
            guard offset + 10 <= data.count else { return .failure("应答段损坏") }
            let type = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
            let length = Int(UInt16(data[offset + 8]) << 8 | UInt16(data[offset + 9]))
            offset += 10
            guard offset + length <= data.count else { return .failure("应答段损坏") }
            let rdata = Array(data[offset..<(offset + length)])
            offset += length
            guard type == 16 else { continue }

            // 一条 TXT 里的多个 character-string 要**拼起来**再解析
            // （iroh 侧 `TxtRecordData` 的 Display 就是无分隔符拼接）。
            var text = ""
            var cursor = 0
            while cursor < rdata.count {
                let chunkLength = Int(rdata[cursor])
                cursor += 1
                guard cursor + chunkLength <= rdata.count else { break }
                text += String(decoding: rdata[cursor..<(cursor + chunkLength)], as: UTF8.self)
                cursor += chunkLength
            }
            for entry in text.split(separator: "\n") {
                apply(entry: String(entry), to: &hint)
            }
        }
        return .success(hint)
    }

    /// 把一条 `key=value` 落进结果。认不出的 key 直接忽略（iroh 还有 `user-data`）。
    static func apply(entry: String, to hint: inout TetherAddressHint) {
        guard let separator = entry.firstIndex(of: "=") else { return }
        let key = entry[entry.startIndex..<separator].trimmingCharacters(in: .whitespaces).lowercased()
        let value = String(entry[entry.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        switch key {
        case "relay":
            hint.relayURL = value
        case "addr":
            // iroh 侧的 `EndpointAddr::new` 要求 `ip:port`，喂进去解析不了会直接抛错。
            // 所以这里先筛一遍，宁可少一条地址，也不要整个建连因为一条脏数据失败。
            if isSocketAddress(value) { hint.addresses.append(value) }
        default:
            break
        }
    }

    /// `1.2.3.4:5678` 或 `[::1]:5678`。
    static func isSocketAddress(_ value: String) -> Bool {
        if value.hasPrefix("[") {
            guard let closing = value.firstIndex(of: "]") else { return false }
            let host = value[value.index(after: value.startIndex)..<closing]
            let rest = value[value.index(after: closing)...]
            guard rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()) else { return false }
            return port > 0 && IPv6AddressIsValid(String(host))
        }
        guard let colon = value.lastIndex(of: ":") else { return false }
        guard let port = UInt16(value[value.index(after: colon)...]), port > 0 else { return false }
        let host = String(value[value.startIndex..<colon])
        var addr = in_addr()
        return inet_pton(AF_INET, host, &addr) == 1
    }

    static func IPv6AddressIsValid(_ host: String) -> Bool {
        var addr = in6_addr()
        return inet_pton(AF_INET6, host, &addr) == 1
    }

    /// 跳过（可能是压缩指针的）域名，返回紧随其后的偏移。
    static func skipName(_ data: [UInt8], _ start: Int) -> Int? {
        var offset = start
        var guardCount = 0
        while offset < data.count {
            guardCount += 1
            if guardCount > 128 { return nil }
            let length = Int(data[offset])
            if length == 0 { return offset + 1 }
            if length & 0xC0 == 0xC0 {
                // 压缩指针占两字节，后面就是下一段的偏移
                return offset + 2
            }
            offset += 1 + length
        }
        return nil
    }

    // MARK: - UDP

    /// 一次 UDP 查询（带超时）。
    ///
    /// 用 POSIX socket 而不是 `NWConnection`：这里只要一问一答，用连接状态机反而
    /// 容易在超时和回调之间打架（continuation 重复 resume 会让进程崩掉）。
    /// 调用点把阻塞读放在 detached 任务里，不会占住协作线程池。
    static func queryUDP(server: String, packet: [UInt8]) async throws -> [UInt8] {
        try await Task.detached(priority: .userInitiated) {
            try queryUDPBlocking(server: server, packet: packet)
        }.value
    }

    static func queryUDPBlocking(server: String, packet: [UInt8]) throws -> [UInt8] {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw TetherDiscoveryFailure.socket("socket() 失败") }
        defer { close(descriptor) }

        var timeout = timeval(
            tv_sec: Int(TetherDiscovery.timeout),
            tv_usec: suseconds_t((TetherDiscovery.timeout - Double(Int(TetherDiscovery.timeout))) * 1_000_000)
        )
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var target = sockaddr_in()
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = in_port_t(53).bigEndian
        guard inet_pton(AF_INET, server, &target.sin_addr) == 1 else {
            throw TetherDiscoveryFailure.socket("解析器地址不合法：\(server)")
        }

        let sent = withUnsafePointer(to: &target) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                sendto(
                    descriptor,
                    packet,
                    packet.count,
                    0,
                    address,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard sent == packet.count else {
            throw TetherDiscoveryFailure.socket("发送失败（\(sent)）")
        }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let received = recv(descriptor, &buffer, buffer.count, 0)
        guard received > 0 else { throw TetherDiscoveryFailure.socket("\(server) 没有回应") }
        return Array(buffer[0..<received])
    }
}

enum TetherDiscoveryFailure: Error, Sendable {
    case socket(String)
}
