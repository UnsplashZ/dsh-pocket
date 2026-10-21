import Foundation
import XCTest

@testable import TetherKit

/// 寻址解析（`TetherDiscovery`）里那些"抄契约"的部分。
///
/// 这些地方一旦写错，表现是**连不上**，而且错得很安静：z-base-32 少算一位就查不到
/// 记录，TXT 解析少处理一种形状就会把 relay 丢掉 —— 真机上只会看到
/// 「找不到这台电脑的地址」。所以逐条钉死。
final class TetherDiscoveryTests: XCTestCase {
    // MARK: z-base-32

    /// 用真实端点 ID 钉住编码结果。
    ///
    /// 期望值来自实测：按这个字符串拼出的 `_iroh.<z32>.dns.iroh.link` 在
    /// 119.29.29.29 / 223.5.5.5 上都能查到这台电脑发布的 TXT 记录
    /// （2026-10-21，`relay=https://aps1-1.relay.n0.iroh.link./`）。
    func testZ32MatchesPublishedRecordName() {
        let host = "69c0863dfe74df71e868edd9ce11f8d4d46d3e80ed4d1a269ca4c83d896b59ad"
        XCTAssertEqual(
            TetherDiscovery.z32(host),
            "p8yecxx6quxzd4de7zchhrxa4ukg4xwy7igtwjwhwurd5nmmmgso"
        )
        XCTAssertEqual(
            TetherDiscovery.txtName(hostHexId: host),
            "_iroh.p8yecxx6quxzd4de7zchhrxa4ukg4xwy7igtwjwhwurd5nmmmgso.dns.iroh.link"
        )
    }

    /// 字母表是 z-base-32，不是常见的 RFC4648 base32 —— 混了就连不上。
    func testZ32UsesZBase32AlphabetNotRfc4648() {
        // 全 0 → 全是字母表首字符 'y'（RFC4648 会给 'a'）
        XCTAssertEqual(
            TetherDiscovery.z32(String(repeating: "0", count: 64)),
            String(repeating: "y", count: 52)
        )
        // 全 1 → 每 5 位都是 0b11111 = 31 → 字母表最后一个字符 '9'；
        // 32 字节 = 256 位 = 51 组零 1 位，最后那一位在高位、低位补零 → 索引 16 → 'o'
        // （data-encoding 的 MSB-first 就是这个补法，抄错会算出一个查不到记录的名字）
        XCTAssertEqual(
            TetherDiscovery.z32(String(repeating: "ff", count: 32)),
            String(repeating: "9", count: 51) + "o"
        )
    }

    func testZ32RejectsMalformedId() {
        XCTAssertNil(TetherDiscovery.z32(""))
        XCTAssertNil(TetherDiscovery.z32("abc"))
        XCTAssertNil(TetherDiscovery.z32(String(repeating: "z", count: 64)))   // 非十六进制
        XCTAssertNil(TetherDiscovery.txtName(hostHexId: "not-an-endpoint-id"))
    }

    // MARK: 查询报文

    func testQueryIsWellFormedTXTQuestion() {
        let name = "_iroh.p8yecxx6quxzd4de7zchhrxa4ukg4xwy7igtwjwhwurd5nmmmgso.dns.iroh.link"
        guard let packet = TetherDiscovery.makeQuery(name: name) else {
            return XCTFail("构造查询失败")
        }
        XCTAssertEqual(packet[2], 0x01, "RD 位应当置上")
        XCTAssertEqual(Array(packet[4..<6]), [0x00, 0x01], "QDCOUNT 应为 1")
        XCTAssertEqual(Array(packet[6..<8]), [0x00, 0x00], "ANCOUNT 应为 0")
        XCTAssertEqual(Array(packet[10..<12]), [0x00, 0x01], "ARCOUNT 应为 1（EDNS0）")

        // 第一个标签必须是 _iroh
        XCTAssertEqual(packet[12], 5)
        XCTAssertEqual(String(decoding: packet[13..<18], as: UTF8.self), "_iroh")

        // 末尾：QTYPE=TXT(16)、QCLASS=IN(1)、然后是 OPT（type=41、载荷 1232）
        let tail = Array(packet.suffix(15))          // QTYPE + QCLASS + OPT
        XCTAssertEqual(Array(tail[0..<2]), [0x00, 0x10], "QTYPE 应为 TXT")
        XCTAssertEqual(Array(tail[2..<4]), [0x00, 0x01], "QCLASS 应为 IN")
        XCTAssertEqual(tail[4], 0x00, "OPT 的名字应为根")
        XCTAssertEqual(Array(tail[5..<7]), [0x00, 0x29], "OPT 的 type 应为 41")
        XCTAssertEqual(Array(tail[7..<9]), [0x04, 0xD0], "EDNS0 载荷应为 1232")
    }

    // MARK: 应答解析

    /// 正常应答：一条 `relay=` + 一条 `addr=`。
    func testParsesRelayAndDirectAddress() {
        let response = makeResponse(answers: [
            txt("relay=https://aps1-1.relay.n0.iroh.link./"),
            txt("addr=192.168.1.23:54321"),
        ])
        guard case .success(let hint) = TetherDiscovery.parseAnswer(response) else {
            return XCTFail("应当解析成功")
        }
        XCTAssertEqual(hint.relayURL, "https://aps1-1.relay.n0.iroh.link./")
        XCTAssertEqual(hint.addresses, ["192.168.1.23:54321"])
        XCTAssertFalse(hint.isEmpty)
    }

    /// 一条 TXT 里的多个 character-string 要拼起来再解析
    /// （iroh 侧 `TxtRecordData` 的 Display 就是无分隔符拼接）。
    func testConcatenatesCharacterStringsWithinOneRecord() {
        let response = makeResponse(answers: [
            txtChunks(["relay=https://aps1-1.relay.n0.iroh.", "link./"]),
        ])
        guard case .success(let hint) = TetherDiscovery.parseAnswer(response) else {
            return XCTFail("应当解析成功")
        }
        XCTAssertEqual(hint.relayURL, "https://aps1-1.relay.n0.iroh.link./")
    }

    /// 只有 relay 没有直连地址，也是**可用**的结果（当前这台电脑就是这样）。
    func testRelayOnlyIsUsable() {
        let response = makeResponse(answers: [txt("relay=https://aps1-1.relay.n0.iroh.link./")])
        guard case .success(let hint) = TetherDiscovery.parseAnswer(response) else {
            return XCTFail("应当解析成功")
        }
        XCTAssertEqual(hint.addresses, [])
        XCTAssertFalse(hint.isEmpty, "只有 relay 也算拿到了寻址信息")
    }

    /// 认不出的 key（`user-data`）和脏地址都要被忽略，而不是让整次建连失败。
    func testIgnoresUnknownKeysAndBadAddresses() {
        let response = makeResponse(answers: [
            txt("relay=https://aps1-1.relay.n0.iroh.link./"),
            txt("user-data=hello"),
            txt("addr=not-an-address"),
            txt("addr=[2001:db8::1]:4242"),
        ])
        guard case .success(let hint) = TetherDiscovery.parseAnswer(response) else {
            return XCTFail("应当解析成功")
        }
        XCTAssertEqual(hint.addresses, ["[2001:db8::1]:4242"])
    }

    func testNXDomainIsReportedNotCrashed() {
        let response = makeResponse(answers: [], rcode: 3)
        guard case .failure(let reason) = TetherDiscovery.parseAnswer(response) else {
            return XCTFail("NXDOMAIN 应当报失败")
        }
        XCTAssertTrue(reason.contains("NXDOMAIN"), reason)
    }

    func testTruncatedFlagIsReported() {
        var response = makeResponse(answers: [])
        response[2] = response[2] | 0x02   // TC=1
        guard case .failure(let reason) = TetherDiscovery.parseAnswer(response) else {
            return XCTFail("截断应当报失败")
        }
        XCTAssertTrue(reason.contains("截断"), reason)
    }

    func testShortPacketIsReportedNotCrashed() {
        guard case .failure = TetherDiscovery.parseAnswer([0x00, 0x01, 0x02]) else {
            return XCTFail("过短的报文应当报失败")
        }
    }

    // MARK: 地址校验

    func testSocketAddressValidation() {
        XCTAssertTrue(TetherDiscovery.isSocketAddress("1.2.3.4:5678"))
        XCTAssertTrue(TetherDiscovery.isSocketAddress("[2001:db8::1]:443"))
        XCTAssertFalse(TetherDiscovery.isSocketAddress("1.2.3.4"))          // 缺端口
        XCTAssertFalse(TetherDiscovery.isSocketAddress("1.2.3.4:0"))        // 端口 0 无意义
        XCTAssertFalse(TetherDiscovery.isSocketAddress("example.com:80"))   // 域名不是 SocketAddr
        XCTAssertFalse(TetherDiscovery.isSocketAddress("relay=https://x"))  // 混进来的别的 key
    }

    // MARK: - 构造应答

    private func txt(_ text: String) -> [UInt8] {
        let bytes = Array(text.utf8)
        let rdataLength = 1 + bytes.count                 // 长度字节 + 内容
        return [0x00, 0x10, 0x00, 0x01, 0x00, 0x00, 0x00, 0x1E]   // TYPE=TXT CLASS=IN TTL=30
            + [UInt8(rdataLength >> 8), UInt8(rdataLength & 0xFF)]
            + [UInt8(bytes.count)] + bytes
    }

    private func txtChunks(_ chunks: [String]) -> [UInt8] {
        var rdata: [UInt8] = []
        for chunk in chunks {
            let bytes = Array(chunk.utf8)
            rdata.append(UInt8(bytes.count))
            rdata.append(contentsOf: bytes)
        }
        return [0x00, 0x10, 0x00, 0x01, 0x00, 0x00, 0x00, 0x1E]
            + [UInt8(rdata.count >> 8), UInt8(rdata.count & 0xFF)]
            + rdata
    }

    /// 拼一条应答：问题段用 `_iroh.<x>.dns.iroh.link`，回答段用压缩指针指回问题名。
    private func makeResponse(answers: [[UInt8]], rcode: UInt8 = 0) -> [UInt8] {
        var packet: [UInt8] = [
            0x12, 0x34,                       // ID
            0x81, 0x80 | (rcode & 0x0F),      // QR=1 RD=1 RA=1，rcode
            0x00, 0x01,                       // QDCOUNT
            UInt8(answers.count >> 8), UInt8(answers.count & 0xFF),
            0x00, 0x00,                       // NSCOUNT
            0x00, 0x00,                       // ARCOUNT
        ]
        for label in "_iroh.abc.dns.iroh.link".split(separator: ".") {
            packet.append(UInt8(label.utf8.count))
            packet.append(contentsOf: label.utf8)
        }
        packet.append(0x00)
        packet.append(contentsOf: [0x00, 0x10, 0x00, 0x01])   // QTYPE=TXT QCLASS=IN
        for answer in answers {
            packet.append(contentsOf: [0xC0, 0x0C])           // 指向问题名
            packet.append(contentsOf: answer)
        }
        return packet
    }
}
