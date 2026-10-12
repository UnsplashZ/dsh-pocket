import Foundation
import Network
import XCTest

@testable import TetherKit

/// 本地代理永远不会真的开流（这些测试只验端口绑定）。
private struct NeverUsedFactory: TetherStreamFactory {
    func openProxyStream() async throws -> TetherProxyStream {
        throw TetherError.transport("测试不会真的开代理流")
    }
}

/// 传输层里"照抄契约"的那几处：端口公式、线协议文本、配对串解析、原因码。
/// 这些一旦写错，表现是"连不上"或"端口漂移"，很难现场排查 —— 所以在单测里钉死。
final class TetherContractTests: XCTestCase {
    // MARK: 端口派生（必须与电脑端 Rust 公式逐位一致）

    func testProxyPortMatchesRustFormula() {
        // Rust: 20000 + u16::from_be_bytes([b[0], b[1]]) % 12000
        let cases: [(String, UInt16)] = [
            ("0000000000000000000000000000000000000000000000000000000000000000", 20_000),
            ("0100000000000000000000000000000000000000000000000000000000000000", 20_256),   // 0x0100 = 256
            ("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", 20_000 + 65_535 % 12_000),
            ("be06c24ad564eef55a15215002db77e74cbb27301ed565084bb90a259ecfe7a3", 20_000 + 0xbe06 % 12_000),
        ]
        for (hex, expected) in cases {
            XCTAssertEqual(TetherProxyPort.port(for: hex), expected, "端点 \(hex.prefix(8))… 的端口不对")
        }
    }

    func testProxyPortStaysInRange() {
        for _ in 0..<200 {
            var bytes = [UInt8]()
            for _ in 0..<32 { bytes.append(UInt8.random(in: 0...255)) }
            let hex = bytes.map { String(format: "%02x", $0) }.joined()
            let port = TetherProxyPort.port(for: hex)
            XCTAssertGreaterThanOrEqual(port, TetherProxyPort.minimum)
            XCTAssertLessThan(port, TetherProxyPort.minimum + TetherProxyPort.span)
            // 避开 iOS 临时端口区
            XCTAssertLessThan(port, 49_152)
        }
    }

    func testProxyPortFallsBackOnBadInput() {
        XCTAssertEqual(TetherProxyPort.port(for: "not-hex"), TetherProxyPort.minimum)
        XCTAssertEqual(TetherProxyPort.port(for: "abc"), TetherProxyPort.minimum)   // 奇数长度
        XCTAssertNil(TetherProxyPort.bytes(fromHex: "zz"))
    }

    // MARK: 线协议文本

    func testHelloLineIsExactlyWhatHostExpects() {
        XCTAssertEqual(String(decoding: TetherWire.hello(name: "张三的 iPhone"), as: UTF8.self),
                       "{\"name\":\"张三的 iPhone\",\"type\":\"hello\"}\n")
    }

    func testPairLine() {
        XCTAssertEqual(String(decoding: TetherWire.pair(code: "123456", name: "phone"), as: UTF8.self),
                       "{\"code\":\"123456\",\"name\":\"phone\",\"type\":\"pair\"}\n")
    }

    func testProxyLineHasNoTrailingSpaces() {
        XCTAssertEqual(String(decoding: TetherWire.proxy, as: UTF8.self), "{\"type\":\"proxy\"}\n")
    }

    func testDecisionLine() {
        XCTAssertEqual(String(decoding: TetherWire.decision(id: "a1", outcome: "allow"), as: UTF8.self),
                       "{\"id\":\"a1\",\"outcome\":\"allow\",\"type\":\"decision\"}\n")
    }

    /// 电脑端对未配对连接的首行限长 512 字节 —— 设备名太长会被直接拒掉。
    func testDeviceNameIsTruncatedToFitUnpairedBudget() {
        let longName = String(repeating: "很长的设备名字", count: 40)
        let line = TetherWire.hello(name: longName)
        XCTAssertLessThanOrEqual(line.count, TetherWire.maxUnpairedLine, "首行不能超过未配对上限")
        XCTAssertEqual(TetherWire.maxDeviceNameLength, 40)
    }

    func testDeviceNameEscapesQuotesAndNewlines() {
        let line = String(decoding: TetherWire.hello(name: "a\"b\\c\nd"), as: UTF8.self)
        XCTAssertTrue(line.contains(#""name":"a\"b\\c\nd""#), "引号/反斜杠/换行必须转义：\(line)")
        // 转义正确的话，它就是合法 JSON
        let payload = line.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(payload.utf8)))
    }

    // MARK: 电脑端消息

    func testHostMessageDecoding() {
        XCTAssertEqual(TetherHostMessage.decode(line: #"{"type":"pair-ok"}"#), .pairOk)
        XCTAssertEqual(TetherHostMessage.decode(line: #"{"type":"pair-fail","reason":"bad-code"}"#), .pairFail(reason: "bad-code"))
        XCTAssertEqual(
            TetherHostMessage.decode(line: #"{"type":"approval","id":"a1","toolName":"bash","reason":"跑测试"}"#),
            .approval(id: "a1", toolName: "bash", reason: "跑测试")
        )
        XCTAssertEqual(TetherHostMessage.decode(line: #"{"type":"approval-cancel","id":"a1"}"#), .approvalCancel(id: "a1"))
        guard case .unknown(let type, _)? = TetherHostMessage.decode(line: #"{"type":"something-new","x":1}"#) else {
            return XCTFail("未知类型应落到 .unknown 而不是被丢掉")
        }
        XCTAssertEqual(type, "something-new")
        XCTAssertNil(TetherHostMessage.decode(line: "not json"))
    }

    // MARK: 配对原因码

    func testPairFailureCodesMapToLocalizedText() {
        let codes = ["no-window", "expired", "too-many-attempts", "bad-code"]
        for code in codes {
            let failure = TetherPairFailure(reason: code)
            XCTAssertEqual(failure.reasonCode, code)
            XCTAssertFalse(failure.localizedDescription.isEmpty)
            // 文案必须是人话，不能把码本身显示给用户
            XCTAssertFalse(failure.localizedDescription.contains(code), "原因码 \(code) 不该直接出现在文案里")
        }
    }

    func testUnknownPairFailureKeepsRawText() {
        // 电脑端 0.1.16 及更早发的就是中文句子
        let failure = TetherPairFailure(reason: "主机上没有开着的配对窗口")
        XCTAssertEqual(failure.reasonCode, "主机上没有开着的配对窗口")
        XCTAssertEqual(failure.localizedDescription, "主机上没有开着的配对窗口")
    }

    // MARK: 配对串解析（扫码 / 粘贴 / 手输三条输入路径）

    func testPairingStringWithEndpointAndCode() {
        let id = String(repeating: "ab", count: 32)
        let parsed = TetherPairingCode.parse("\(id)#654321")
        XCTAssertEqual(parsed?.endpointId, id)
        XCTAssertEqual(parsed?.code, "654321")
    }

    func testPairingStringToleratesWhitespaceAndNewlines() {
        let id = String(repeating: "cd", count: 32)
        XCTAssertEqual(TetherPairingCode.parse("\(id)\n  654321  ")?.code, "654321")
        XCTAssertEqual(TetherPairingCode.parse("\(id) 654321")?.endpointId, id)
        XCTAssertEqual(TetherPairingCode.parse("\(id)\t654321")?.code, "654321")
    }

    func testPairingStringCodeOnly() {
        let parsed = TetherPairingCode.parse("123456")
        XCTAssertNil(parsed?.endpointId)
        XCTAssertEqual(parsed?.code, "123456")
    }

    func testPairingStringEndpointOnlyLeavesCodeEmptyForHostBookLookup() {
        let id = String(repeating: "ef", count: 32)
        let parsed = TetherPairingCode.parse(id)
        XCTAssertEqual(parsed?.endpointId, id)
        XCTAssertEqual(parsed?.code, "")
    }

    func testPairingStringRejectsGarbage() {
        XCTAssertNil(TetherPairingCode.parse(""))
        XCTAssertNil(TetherPairingCode.parse("   "))
        XCTAssertNil(TetherPairingCode.parse("hello world"))
        XCTAssertNil(TetherPairingCode.parse("12345"))
        XCTAssertNil(TetherPairingCode.parse("1234567"))
    }

    func testPairingStringIsCaseInsensitiveForEndpointId() {
        let id = String(repeating: "AB", count: 32)
        XCTAssertEqual(TetherPairingCode.parse("\(id)#111111")?.endpointId, id.lowercased())
    }

    // MARK: JSON-lines 缓冲

    func testJsonLineBufferSplitsAcrossChunks() {
        var buffer = JsonLineBuffer()
        XCTAssertEqual(buffer.append(Data(#"{"type":"pa"#.utf8)), [])
        XCTAssertEqual(buffer.append(Data("ir-ok\"}\n".utf8)), [#"{"type":"pair-ok"}"#])
    }

    func testJsonLineBufferHandlesMultipleLinesAndBlankLines() {
        var buffer = JsonLineBuffer()
        let chunk = Data("\n{\"a\":1}\n\n{\"b\":2}\n".utf8)
        XCTAssertEqual(buffer.append(chunk), [#"{"a":1}"#, #"{"b":2}"#])
    }

    func testJsonLineBufferDropsOverlongRunaway() {
        var buffer = JsonLineBuffer()
        _ = buffer.append(Data(repeating: 0x41, count: TetherWire.maxLine + 1))
        // 超长之后缓冲被清空，重新开始计数
        XCTAssertEqual(buffer.append(Data("{\"ok\":1}\n".utf8)), [#"{"ok":1}"#])
    }

    // MARK: 存储

    func testIdentityIsStableAcrossLoads() throws {
        let store = EphemeralSecretStore()
        let first = try TetherIdentity.loadOrCreate(store: store)
        let second = try TetherIdentity.loadOrCreate(store: store)
        XCTAssertEqual(first.endpointId, second.endpointId, "同一份存储必须给出同一把身份")
        XCTAssertEqual(first.endpointId.count, 64)
        XCTAssertTrue(first.endpointId.allSatisfy(\.isHexDigit))
    }

    func testIdentityResetChangesKey() throws {
        let store = EphemeralSecretStore()
        let first = try TetherIdentity.loadOrCreate(store: store)
        let reset = try TetherIdentity.reset(store: store)
        XCTAssertNotEqual(first.endpointId, reset.endpointId)
        XCTAssertEqual(try TetherIdentity.loadOrCreate(store: store).endpointId, reset.endpointId)
    }

    func testFileSecretStoreRoundTripAndPermissions() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tether-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileSecretStore(directory: directory)
        XCTAssertNil(try store.read("missing"))
        try store.write("k", Data([1, 2, 3]))
        XCTAssertEqual(try store.read("k"), Data([1, 2, 3]))

        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("k.secret").path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(permissions & 0o777, 0o600, "身份文件必须只有属主可读写")

        try store.delete("k")
        XCTAssertNil(try store.read("k"))
    }

    // MARK: 主机簿

    func testHostBookRoundTripAndOrdering() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hostbook-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        var book = TetherHostBook()
        book.upsert(TetherHostRecord(id: "a", label: "旧", lastConnectedAt: Date(timeIntervalSince1970: 100)))
        book.upsert(TetherHostRecord(id: "b", label: "新", lastConnectedAt: Date(timeIntervalSince1970: 200)))
        book.upsert(TetherHostRecord(id: "a", label: "改名后", lastConnectedAt: Date(timeIntervalSince1970: 300)))
        XCTAssertEqual(book.hosts.count, 2, "同 id 是更新不是追加")
        XCTAssertEqual(book.host(id: "a")?.label, "改名后")
        XCTAssertEqual(book.hosts.first?.id, "a", "最近连接的排前面")

        book.save(to: url)
        let reloaded = TetherHostBook.load(from: url)
        XCTAssertEqual(reloaded.hosts.count, 2)
        XCTAssertEqual(reloaded.host(id: "a")?.label, "改名后")

        var removed = reloaded
        removed.remove(id: "a")
        XCTAssertNil(removed.host(id: "a"))
        XCTAssertEqual(removed.hosts.count, 1)
    }

    func testHostRecordShortId() {
        let record = TetherHostRecord(id: String(repeating: "a", count: 32) + String(repeating: "b", count: 32), label: "x")
        XCTAssertEqual(record.shortId.count, 12)
    }

    // MARK: 首行消息（hello / pair 二选一）

    /// 电脑端的校验是**严格二选一**的，选错就是"连不上"，而且报错信息毫无指向性
    /// （只有 `close(1, b"protocol")`）。所以这条决策必须有单测。
    func testFirstMessageIsHelloWhenAlreadyPaired() {
        // 已经配对过：就算用户又填了一次配对码，也只能发 hello。
        // 这是真机上踩到的坑：配对成功后重开配对页再点一次，发出去的是 pair，
        // 电脑端 `(paired=true, Pair)` → 协议错误 → 直接断开。
        XCTAssertEqual(TetherSession.firstMessage(alreadyPaired: true, pairingCode: "123456"), .hello)
        XCTAssertEqual(TetherSession.firstMessage(alreadyPaired: true, pairingCode: nil), .hello)
        XCTAssertEqual(TetherSession.firstMessage(alreadyPaired: true, pairingCode: ""), .hello)
    }

    func testFirstMessageIsPairOnlyWhenUnpaired() {
        XCTAssertEqual(TetherSession.firstMessage(alreadyPaired: false, pairingCode: "123456"), .pair(code: "123456"))
        // 没配对过又没有码：不该发 hello 去撞墙，而是明确地"还不会连"
        XCTAssertNil(TetherSession.firstMessage(alreadyPaired: false, pairingCode: nil))
        XCTAssertNil(TetherSession.firstMessage(alreadyPaired: false, pairingCode: ""))
    }

    /// 主机簿是"已配对"的唯一依据 —— 它得真的记得住。
    func testHostBookDrivesTheAlreadyPairedDecision() {
        var book = TetherHostBook()
        let hostId = String(repeating: "ab", count: 32)
        XCTAssertNil(book.host(id: hostId))
        XCTAssertEqual(TetherSession.firstMessage(alreadyPaired: book.host(id: hostId) != nil, pairingCode: "123456"),
                       .pair(code: "123456"))

        book.upsert(TetherHostRecord(id: hostId, label: "我的 Mac"))
        XCTAssertEqual(TetherSession.firstMessage(alreadyPaired: book.host(id: hostId) != nil, pairingCode: "123456"),
                       .hello)
    }

    // MARK: 本地代理端口

    /// 首选端口被占用时必须**回退到系统分配**，而不是报错。
    ///
    /// 这个 bug 在真机上长这样：`本地代理启动失败：Network.NWError 错误 48 - Address
    /// already in use`。根因是 `NWListener(using:on:)` 在端口冲突时**不会同步抛错** ——
    /// 绑定失败是异步地从 stateUpdateHandler 送来的，所以只 catch 同步错误是没用的。
    func testLocalProxyFallsBackWhenPreferredPortIsTaken() async throws {
        let occupied = try occupyEphemeralPort()
        defer { occupied.cancel() }

        let server = LocalProxyServer(
            factory: NeverUsedFactory(),
            preferredPort: occupied.port!.rawValue
        )
        let url = try await server.start()
        defer { Task { await server.stop() } }

        let bound = UInt16(url.port ?? 0)
        XCTAssertNotEqual(bound, occupied.port!.rawValue, "被占用的端口不该被抢到")
        XCTAssertGreaterThan(bound, 0, "应该回退到系统分配并拿到真实端口")
    }

    /// 连续起两个同端口偏好的代理：第二个必须自己让路，而不是把第一个顶掉。
    func testTwoProxiesWithSamePreferredPortCoexist() async throws {
        let first = LocalProxyServer(factory: NeverUsedFactory(), preferredPort: 28_123)
        let firstURL = try await first.start()
        defer { Task { await first.stop() } }

        let second = LocalProxyServer(factory: NeverUsedFactory(), preferredPort: 28_123)
        let secondURL = try await second.start()
        defer { Task { await second.stop() } }

        XCTAssertEqual(firstURL.port, 28_123, "第一个应该拿到首选端口")
        XCTAssertNotEqual(secondURL.port, firstURL.port, "第二个必须回退，不能撞在一起")
    }

    /// 停掉之后端口**不会立刻**释放 —— `NWListener.cancel()` 是异步的。
    ///
    /// 这条测试记录的是一个实测事实，而不是一个理想：重启监听时很容易撞上
    /// 自己刚刚放掉的那个端口。所以"能起来"才是要求，"拿到同一个端口"不是 ——
    /// 上层因此**不要缓存 authority**（端口可能变）。
    func testRestartAfterStopStillBindsEvenIfPortIsNotYetFree() async throws {
        let server = LocalProxyServer(factory: NeverUsedFactory(), preferredPort: 28_124)
        let first = try await server.start()
        XCTAssertEqual(first.port, 28_124, "第一次应该拿到首选端口")
        await server.stop()

        // 同一个端口偏好再起一个：不管拿到首选端口还是回退端口，**都必须能起来**。
        let again = LocalProxyServer(factory: NeverUsedFactory(), preferredPort: 28_124)
        let second = try await again.start()
        defer { Task { await again.stop() } }
        XCTAssertGreaterThan(second.port ?? 0, 0, "停掉后重起必须成功（可以回退到别的端口）")
    }

    /// 占一个临时端口，用来模拟"端口已被占用"。
    private func occupyEphemeralPort() throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = false
        let listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 5)
        return listener
    }

    // MARK: 错误文案

    func testEveryTetherErrorHasAUserFacingSentence() {
        let errors: [TetherError] = [
            .notPaired,
            .pairingFailed(.noWindow),
            .invalidEndpointId("zz"),
            .transport("连接被重置"),
            .proxyUnavailable("端口被占用"),
            .proxyRefused,
            .controlClosed("对端关闭"),
        ]
        for error in errors {
            let text = error.errorDescription ?? ""
            XCTAssertFalse(text.isEmpty, "\(error) 没有给用户看的文案")
            XCTAssertFalse(text.contains("TetherError"), "不要把 Swift 类型名漏给用户：\(text)")
        }
    }
}
