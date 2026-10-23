import DSHKit
import TetherKit
import XCTest

@testable import DSHPocket

/// 多路接入（uplink）的单测。
///
/// 这里只测**纯逻辑**：配对串解析、HMAC 应答、选档策略、换票与 401 重试。
/// 真实网络行为（DNS、局域网、ATS）在真机上验，不在单测里造。
final class UplinkTests: XCTestCase {
    // MARK: 工具

    /// 一个可控的"电脑端"：按脚本回响应，并记下收到的请求。
    ///
    /// 用 FIFO 而不是按 URL 匹配：这些用例里的调用顺序本身就是被测对象
    /// （先换票 → 再请求 → 401 → 重换 → 重试），顺序错了就该红。
    final class StubServer: @unchecked Sendable {
        private let lock = NSLock()
        private var queue: [(Int, String)]
        private var received: [URLRequest] = []

        init(_ responses: [(Int, String)]) {
            self.queue = responses
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.lock()
            received.append(request)
            let next = queue.isEmpty ? (500, #"{"ok":false,"reason":"unexpected"}"#) : queue.removeFirst()
            lock.unlock()
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "http://localhost/")!,
                statusCode: next.0,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (Data(next.1.utf8), response)
        }

        var requests: [URLRequest] {
            lock.lock(); defer { lock.unlock() }
            return received
        }
    }

    private static let secret = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
    private static let authOK = #"{"ok":true,"ticket":"ticket-1","ttl":900000}"#

    private func makeSuite() -> UserDefaults {
        UserDefaults(suiteName: "test-uplink-\(UUID().uuidString)")!
    }

    @MainActor
    private func makeSession(
        suite: UserDefaults,
        server: StubServer,
        probe: @escaping UplinkSession.Probe,
        discover: @escaping UplinkSession.Discover = { _ in [] },
        network: UplinkNetworkKind = .wifi,
        now: @escaping () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) },
        // 传进来的 store 必须复用：`EphemeralSecretStore` 是**进程内**存储，
        // 两个实例互相看不见对方的密钥（表现就是"明明存了却说没配对"）。
        store: UplinkCredentialStore? = nil
    ) -> (UplinkSession, UplinkCredentialStore) {
        let settings = AppSettings(defaults: suite)
        let store = store ?? UplinkCredentialStore(secrets: EphemeralSecretStore(), defaults: suite)
        let session = UplinkSession(
            store: store,
            settings: settings,
            probe: probe,
            send: { request in try await server.send(request) },
            discover: discover,
            network: UplinkNetworkMonitor(fixed: network),
            now: now
        )
        return (session, store)
    }

    private static func pairing(
        urls: [String] = ["http://10.0.0.5:18788", "http://100.64.0.1:18788"],
        secret: String = UplinkTests.secret,
        hintedTiers: [UplinkTier] = [],
        irohEndpointId: String? = nil
    ) -> UplinkPairing {
        UplinkPairing(
            hostId: "host-1234abcd",
            name: "书房的 Mac",
            port: 18788,
            deviceId: "abc123",
            secret: secret,
            urls: urls,
            hintedTiers: hintedTiers,
            irohEndpointId: irohEndpointId,
            issuedAt: 1_700_000_000_000
        )!
    }

    /// 造一条 `sockaddr`（Bonjour 的地址记录就是这个形状）。
    private static func sockaddrData(_ address: String) -> Data {
        var raw = sockaddr_in()
        raw.sin_family = sa_family_t(AF_INET)
        raw.sin_port = in_port_t(18788).bigEndian
        _ = inet_pton(AF_INET, address, &raw.sin_addr)
        return withUnsafeBytes(of: &raw) { Data($0) }
    }

    /// 造一条 TXT 记录（长度字节 + 内容）。
    private static func txtData(_ entries: [String]) -> Data {
        var data = Data()
        for entry in entries {
            let bytes = Data(entry.utf8)
            data.append(UInt8(bytes.count))
            data.append(bytes)
        }
        return data
    }

    // MARK: 档位名（配对串里的 tiers）

    /// 电脑端给了 kind 就必须用它 —— 否则 ZeroTier 会被当成局域网。
    func testPairingPrefersHintedTierKinds() throws {
        let lanURL = try XCTUnwrap(URL(string: "http://10.8.54.221:18788"))
        let ztURL = try XCTUnwrap(URL(string: "http://10.147.20.5:18788"))
        // 两个地址都是 10/8：只按地址推断的话，两个都会变成「局域网」
        let pairing = UplinkPairing(
            hostId: "host-1",
            name: "Mac",
            port: 18788,
            deviceId: "abc123",
            secret: Self.secret,
            urls: [lanURL.absoluteString, ztURL.absoluteString],
            hintedTiers: [
                UplinkTier(kind: .zerotier, url: ztURL),
                UplinkTier(kind: .lan, url: lanURL),
            ],
            issuedAt: 1_700_000_000_000
        )
        let parsed = try XCTUnwrap(UplinkPairing.parse(try XCTUnwrap(pairing).encodedString()))
        XCTAssertEqual(parsed.tiers.map(\.kind), [.lan, .zerotier], "要按优先级排序且保留各自的 kind")
        XCTAssertEqual(parsed.tiers.first?.url, lanURL)
    }

    /// 老版本电脑端不发 tiers：退化成按地址猜，且不因为缺字段而解析失败。
    func testPairingFallsBackToAddressInference() throws {
        let parsed = try XCTUnwrap(UplinkPairing.parse(Self.pairing().encodedString()))
        XCTAssertTrue(parsed.hintedTiers.isEmpty)
        XCTAssertEqual(parsed.tiers.count, parsed.urls.count)
        // 10.x 猜成局域网（这就是没有 kind 时的已知局限）
        XCTAssertEqual(parsed.tiers.first?.kind, .lan)
    }

    /// 认不出的 kind 要丢掉，不能把优先级不明的地址塞进探测列表。
    func testPairingDropsUnknownTierKinds() throws {
        let payload: [String: Any] = [
            "v": 1,
            "hostId": "host-1",
            "name": "Mac",
            "port": 18788,
            "deviceId": "abc123",
            "secret": Self.secret,
            "urls": ["http://10.0.0.5:18788"],
            "tiers": [
                ["kind": "lan", "url": "http://10.0.0.5:18788"],
                ["kind": "wireguard", "url": "http://10.0.0.6:18788"],
                ["kind": "lan"],
            ],
            "issuedAt": 1_700_000_000_000,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let text = "dshuplink://" + data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let parsed = try XCTUnwrap(UplinkPairing.parse(text))
        XCTAssertEqual(parsed.hintedTiers.count, 1)
        XCTAssertEqual(parsed.hintedTiers.first?.kind, .lan)
    }

    // MARK: 配对串

    func testPairingRoundTrip() throws {
        let original = Self.pairing()
        let parsed = try XCTUnwrap(UplinkPairing.parse(original.encodedString()))
        XCTAssertEqual(parsed.hostId, original.hostId)
        XCTAssertEqual(parsed.deviceId, original.deviceId)
        XCTAssertEqual(parsed.secret, original.secret)
        XCTAssertEqual(parsed.urls, original.urls)
        XCTAssertEqual(parsed.port, 18788)
        XCTAssertEqual(parsed.name, "书房的 Mac")
    }

    func testPairingToleratesSurroundingWhitespace() throws {
        // 从聊天窗口复制过来的配对串常带换行与缩进（用户实测）。
        let text = "\n   " + Self.pairing().encodedString() + "  \r\n"
        XCTAssertNotNil(UplinkPairing.parse(text))
    }

    func testPairingIsCaseInsensitiveOnScheme() {
        let encoded = Self.pairing().encodedString()
        let upper = "DSHUPLINK://" + encoded.dropFirst("dshuplink://".count)
        XCTAssertNotNil(UplinkPairing.parse(upper))
    }

    func testPairingRejectsGarbage() {
        XCTAssertNil(UplinkPairing.parse(""), "空串")
        XCTAssertNil(UplinkPairing.parse("   "), "只有空白")
        XCTAssertNil(UplinkPairing.parse("https://example.com"), "scheme 不对")
        XCTAssertNil(UplinkPairing.parse("dshuplink://"), "没有 payload")
        XCTAssertNil(UplinkPairing.parse("dshuplink://not-base64-@@@"), "payload 不是 base64url")
        // 合法 base64url，但不是我们要的 JSON
        XCTAssertNil(UplinkPairing.parse("dshuplink://" + Data("hello".utf8).base64EncodedString()))
    }

    func testPairingRejectsWrongVersionAndBadSecret() {
        func encoded(_ payload: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: payload)
            let b64 = data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            return "dshuplink://" + b64
        }
        let base: [String: Any] = [
            "v": 1, "hostId": "h", "name": "n", "port": 18788,
            "deviceId": "d", "secret": Self.secret, "urls": ["http://10.0.0.5:18788"],
            "issuedAt": 1,
        ]
        XCTAssertNotNil(UplinkPairing.parse(encoded(base)), "基线应当能解析")

        var wrongVersion = base
        wrongVersion["v"] = 2
        XCTAssertNil(UplinkPairing.parse(encoded(wrongVersion)), "版本不认识要拒绝，不能猜")

        var shortSecret = base
        shortSecret["secret"] = "abcd"
        XCTAssertNil(UplinkPairing.parse(encoded(shortSecret)), "secret 必须是 64 位十六进制")

        var noHost = base
        noHost["hostId"] = ""
        XCTAssertNil(UplinkPairing.parse(encoded(noHost)))
    }

    func testPairingWithoutUrlsStillParses() throws {
        // 地址清单可能是空的（电脑端一个档位都没开）。配对本身仍然有效 ——
        // 用户还能靠 iroh 用，只是"多路接入"暂时没路可走。
        let parsed = try XCTUnwrap(UplinkPairing.parse(Self.pairing(urls: []).encodedString()))
        XCTAssertTrue(parsed.tiers.isEmpty)
    }

    // MARK: 档位推断

    func testTierKindInference() {
        XCTAssertEqual(UplinkTierKind.infer(from: URL(string: "http://192.168.1.5:18788")!), .lan)
        XCTAssertEqual(UplinkTierKind.infer(from: URL(string: "http://10.2.3.4:18788")!), .lan)
        XCTAssertEqual(UplinkTierKind.infer(from: URL(string: "http://172.20.0.1:18788")!), .lan)
        XCTAssertEqual(UplinkTierKind.infer(from: URL(string: "http://macbook.local:18788")!), .lan)
        XCTAssertEqual(UplinkTierKind.infer(from: URL(string: "http://100.64.0.9:18788")!), .tailscale)
        XCTAssertEqual(UplinkTierKind.infer(from: URL(string: "http://studio.tail1234.ts.net")!), .tailscale)
        XCTAssertEqual(UplinkTierKind.infer(from: URL(string: "https://dsh.example.com")!), .frp)
        XCTAssertEqual(UplinkTierKind.infer(from: URL(string: "http://8.8.8.8:18788")!), .frp)
    }

    func testTierToleratesMissingScheme() throws {
        let tier = try XCTUnwrap(UplinkTier(urlString: " 10.0.0.5:18788 "))
        XCTAssertEqual(tier.url.absoluteString, "http://10.0.0.5:18788")
        XCTAssertEqual(tier.kind, .lan)
    }

    // MARK: HMAC 应答

    /// 已知向量由电脑端同一算法（`auth.js` 的 `proofFor`）算出：
    /// `node -e 'createHmac("sha256", Buffer.from(secret,"hex")).update("auth|abc123|1700000000000|0123456789abcdef").digest("hex")'`
    func testProofMatchesKnownVector() {
        let proof = UplinkCrypto.proof(
            secret: Self.secret, deviceId: "abc123", ts: 1_700_000_000_000, nonce: "0123456789abcdef"
        )
        XCTAssertEqual(proof, "62a90a270c4def18478224c1ceaa0f6286392354391e24331e3ecc6a418fa41d")
    }

    func testSecondProofVector() {
        let proof = UplinkCrypto.proof(
            secret: "ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100",
            deviceId: "dev-42",
            ts: 1_699_999_999_999,
            nonce: "nonce-42"
        )
        XCTAssertEqual(proof, "383914e86f5a2a3760dbf0c2fa840324969f54b2f566d9f698da891fb12fdfd8")
    }

    func testProofIsNilForBadSecret() {
        XCTAssertNil(UplinkCrypto.proof(secret: "zz", deviceId: "d", ts: 1, nonce: "n"))
        XCTAssertNil(UplinkCrypto.proof(secret: "abc", deviceId: "d", ts: 1, nonce: "n"), "奇数长度")
    }

    func testNonceLooksRandomEnough() {
        let a = UplinkCrypto.makeNonce()
        let b = UplinkCrypto.makeNonce()
        XCTAssertEqual(a.count, 32)
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.allSatisfy(\.isHexDigit))
    }

    // MARK: 选档

    @MainActor
    func testParallelProbePicksFastest() async throws {
        let suite = makeSuite()
        defer { suite.removePersistentDomain(forName: suite.description) }
        let server = StubServer([(200, Self.authOK)])
        let probe: UplinkSession.Probe = { tier, _ in
            switch tier.kind {
            case .lan:
                try? await Task.sleep(for: .milliseconds(150))
                return .reachable(rttMilliseconds: 150)
            case .tailscale:
                try? await Task.sleep(for: .milliseconds(10))
                return .reachable(rttMilliseconds: 10)
            default:
                return .unreachable(.timedOut(milliseconds: 800))
            }
        }
        let (session, store) = makeSession(suite: suite, server: server, probe: probe)
        store.save(Self.pairing())

        let connected = await session.connect()
        let tier = try XCTUnwrap(connected)
        XCTAssertEqual(tier.kind, .tailscale, "慢的那档不能因为排在前头就先赢")
        XCTAssertEqual(session.currentTier?.kind, .tailscale)
        XCTAssertEqual(session.tierRTTs["lan"], 150, "没选中的档位也要留下 RTT，诊断页要显示")
        XCTAssertEqual(session.tierRTTs["tailscale"], 10)
        // baseURL 是**回环代理**（ATS 只放行本地地址），远端地址在 currentTier 里。
        XCTAssertEqual(session.baseURL?.host, "127.0.0.1")
        XCTAssertEqual(session.currentTier?.url.absoluteString, "http://100.64.0.1:18788")
        XCTAssertNil(session.lastError)
    }

    @MainActor
    func testStickyTierWinsEvenWhenSlower() async throws {
        let suite = makeSuite()
        defer { suite.removePersistentDomain(forName: suite.description) }
        let settings = AppSettings(defaults: suite)
        settings.uplinkLastGoodTier = "lan"
        settings.uplinkStickyUntil = Date().addingTimeInterval(240)

        let server = StubServer([(200, Self.authOK)])
        let probed = NSMutableSet()
        let probe: UplinkSession.Probe = { tier, _ in
            probed.add(tier.kind.rawValue)
            return tier.kind == .lan
                ? .reachable(rttMilliseconds: 300)
                : .reachable(rttMilliseconds: 5)
        }
        let store = UplinkCredentialStore(secrets: EphemeralSecretStore(), defaults: suite)
        let session = UplinkSession(
            store: store,
            settings: settings,
            probe: probe,
            send: { request in try await server.send(request) },
            now: { Date() }
        )
        store.save(Self.pairing())

        let connected = await session.connect()
        let tier = try XCTUnwrap(connected)
        XCTAssertEqual(tier.kind, .lan, "粘滞窗口内要回到上次通的档位，而不是每次都按 RTT 重选")
        XCTAssertEqual(probed.count, 1, "粘滞命中后不该再去打扰其它档位")
    }

    @MainActor
    func testStickyTierFallsBackToProbeWhenItFails() async throws {
        let suite = makeSuite()
        defer { suite.removePersistentDomain(forName: suite.description) }
        let settings = AppSettings(defaults: suite)
        settings.uplinkLastGoodTier = "lan"
        settings.uplinkStickyUntil = Date().addingTimeInterval(240)

        let server = StubServer([(200, Self.authOK)])
        let probe: UplinkSession.Probe = { tier, _ in
            tier.kind == .lan
                ? .unreachable(.timedOut(milliseconds: 800))
                : .reachable(rttMilliseconds: 7)
        }
        let store = UplinkCredentialStore(secrets: EphemeralSecretStore(), defaults: suite)
        let session = UplinkSession(
            store: store, settings: settings, probe: probe,
            send: { request in try await server.send(request) }, now: { Date() }
        )
        store.save(Self.pairing())

        let connected = await session.connect()
        let tier = try XCTUnwrap(connected)
        XCTAssertEqual(tier.kind, .tailscale)
        XCTAssertEqual(settings.uplinkLastGoodTier, "tailscale", "换档之后 lastGood 要跟着更新")
    }

    @MainActor
    func testExpiredStickyWindowIsIgnored() async throws {
        let suite = makeSuite()
        defer { suite.removePersistentDomain(forName: suite.description) }
        let settings = AppSettings(defaults: suite)
        settings.uplinkLastGoodTier = "lan"
        settings.uplinkStickyUntil = Date().addingTimeInterval(-1)   // 已经过期

        let server = StubServer([(200, Self.authOK)])
        let probe: UplinkSession.Probe = { tier, _ in
            tier.kind == .lan
                ? .reachable(rttMilliseconds: 400)
                : .reachable(rttMilliseconds: 3)
        }
        let store = UplinkCredentialStore(secrets: EphemeralSecretStore(), defaults: suite)
        let session = UplinkSession(
            store: store, settings: settings, probe: probe,
            send: { request in try await server.send(request) }, now: { Date() }
        )
        store.save(Self.pairing())

        let connected = await session.connect()
        let tier = try XCTUnwrap(connected)
        XCTAssertEqual(tier.kind, .tailscale, "粘滞过期就该按实际 RTT 重选")
    }

    @MainActor
    func testDisabledTiersAreNotProbed() async throws {
        let suite = makeSuite()
        defer { suite.removePersistentDomain(forName: suite.description) }
        let settings = AppSettings(defaults: suite)
        settings.uplinkEnabledTiers = [UplinkTierKind.tailscale.rawValue]

        let server = StubServer([(200, Self.authOK)])
        let probed = NSMutableSet()
        let probe: UplinkSession.Probe = { tier, _ in
            probed.add(tier.kind.rawValue)
            return .reachable(rttMilliseconds: 5)
        }
        let store = UplinkCredentialStore(secrets: EphemeralSecretStore(), defaults: suite)
        let session = UplinkSession(
            store: store, settings: settings, probe: probe,
            send: { request in try await server.send(request) }, now: { Date() }
        )
        store.save(Self.pairing())

        let connected = await session.connect()
        let tier = try XCTUnwrap(connected)
        XCTAssertEqual(tier.kind, .tailscale)
        XCTAssertEqual(probed.count, 1, "被关掉的档位不该被探测（省电，也避免把地址暴露给不该连的网络）")
    }

    @MainActor
    func testAllTiersFailingReportsReason() async {
        let suite = makeSuite()
        defer { suite.removePersistentDomain(forName: suite.description) }
        let server = StubServer([])
        let probe: UplinkSession.Probe = { _, _ in .unreachable(.timedOut(milliseconds: 800)) }
        let (session, store) = makeSession(suite: suite, server: server, probe: probe)
        store.save(Self.pairing())

        let tier = await session.connect()
        XCTAssertNil(tier)
        XCTAssertNil(session.baseURL)
        XCTAssertNotNil(session.lastError)
        XCTAssertNotNil(session.lastSwitchReason)
        XCTAssertTrue(server.requests.isEmpty, "一个地址都不通时不该去换票")
    }

    @MainActor
    func testNotPairedReportsReason() async {
        let suite = makeSuite()
        defer { suite.removePersistentDomain(forName: suite.description) }
        let server = StubServer([])
        let probe: UplinkSession.Probe = { _, _ in .reachable(rttMilliseconds: 1) }
        let (session, _) = makeSession(suite: suite, server: server, probe: probe)

        let tier = await session.connect()
        XCTAssertNil(tier)
        XCTAssertEqual(session.lastError, UplinkError.notPaired.errorDescription)
    }

    // MARK: 换票

    @MainActor
    func testExchangeSendsSignedBody() async throws {
        let suite = makeSuite()
        defer { suite.removePersistentDomain(forName: suite.description) }
        let server = StubServer([(200, Self.authOK)])
        let probe: UplinkSession.Probe = { _, _ in .reachable(rttMilliseconds: 3) }
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let (session, store) = makeSession(suite: suite, server: server, probe: probe, now: { fixed })
        store.save(Self.pairing())

        let connected = await session.connect()
        XCTAssertNotNil(connected)

        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.url?.path, "/uplink/auth")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["deviceId"] as? String, "abc123")
        let ts = try XCTUnwrap(json["ts"] as? Int64 ?? (json["ts"] as? Int).map(Int64.init))
        XCTAssertEqual(ts, 1_700_000_000_000, "ts 必须是毫秒")
        let nonce = try XCTUnwrap(json["nonce"] as? String)
        let expected = try XCTUnwrap(UplinkCrypto.proof(
            secret: Self.secret, deviceId: "abc123", ts: ts, nonce: nonce
        ))
        XCTAssertEqual(json["proof"] as? String, expected, "proof 必须与服务端算法一致")
    }

    @MainActor
    func testHeadersCarryCachedTicket() async throws {
        let suite = makeSuite()
        defer { suite.removePersistentDomain(forName: suite.description) }
        let server = StubServer([(200, Self.authOK)])
        let probe: UplinkSession.Probe = { _, _ in .reachable(rttMilliseconds: 3) }
        let (session, store) = makeSession(suite: suite, server: server, probe: probe)
        store.save(Self.pairing())

        XCTAssertTrue(session.headers().isEmpty, "没换票时不能假装有票")
        let connected = await session.connect()
        XCTAssertNotNil(connected)
        XCTAssertEqual(session.headers()["Authorization"], "Bearer ticket-1")
        XCTAssertEqual(session.ticketRemainingSeconds, 900)
    }

    @MainActor
    func testTicketIsRefreshedBeforeExpiry() async throws {
        let suite = makeSuite()
        defer { suite.removePersistentDomain(forName: suite.description) }
        let server = StubServer([
            (200, Self.authOK),
            (200, #"{"ok":true,"ticket":"ticket-2","ttl":900000}"#),
        ])
        let probe: UplinkSession.Probe = { _, _ in .reachable(rttMilliseconds: 3) }
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let (session, store) = makeSession(suite: suite, server: server, probe: probe, now: { clock })
        store.save(Self.pairing())
        let connected = await session.connect()
        XCTAssertNotNil(connected)

        // 还早：不该换票
        clock = clock.addingTimeInterval(600)
        let early = await session.headersRefreshingIfNeeded()
        XCTAssertEqual(early["Authorization"], "Bearer ticket-1")
        XCTAssertEqual(server.requests.count, 1)

        // 只剩 30 秒（< 60 秒提前量）：要换
        clock = clock.addingTimeInterval(270)
        let refreshed = await session.headersRefreshingIfNeeded()
        XCTAssertEqual(refreshed["Authorization"], "Bearer ticket-2")
        XCTAssertEqual(server.requests.count, 2)
    }

    // MARK: 401 重换票

    @MainActor
    func testUnauthorizedRefreshesTicketOnceAndRetries() async throws {
        let suite = makeSuite()
        defer { suite.removePersistentDomain(forName: suite.description) }
        let server = StubServer([
            (200, Self.authOK),                                        // connect 时换票
            (401, #"{"ok":false,"reason":"expired"}"#),                // 业务请求被拒
            (200, #"{"ok":true,"ticket":"ticket-2","ttl":900000}"#),   // 重换
            (200, #"{"ok":true}"#),                                    // 重试成功
        ])
        let probe: UplinkSession.Probe = { _, _ in .reachable(rttMilliseconds: 3) }
        let (session, store) = makeSession(suite: suite, server: server, probe: probe)
        store.save(Self.pairing())
        let connected = await session.connect()
        XCTAssertNotNil(connected)

        let request = URLRequest(url: URL(string: "http://10.0.0.5:18788/api/session/list")!)
        let (_, response) = try await session.sendWithTicket(request)
        XCTAssertEqual(response.statusCode, 200)

        let requests = server.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer ticket-1")
        XCTAssertEqual(requests[2].url?.path, "/uplink/auth", "401 之后必须先换票")
        XCTAssertEqual(requests[3].value(forHTTPHeaderField: "Authorization"), "Bearer ticket-2")
    }

    @MainActor
    func testUnauthorizedTwiceThrowsWithoutLooping() async throws {
        let suite = makeSuite()
        defer { suite.removePersistentDomain(forName: suite.description) }
        let server = StubServer([
            (200, Self.authOK),
            (401, #"{"ok":false,"reason":"unknown-device"}"#),
            (200, #"{"ok":true,"ticket":"ticket-2","ttl":900000}"#),
            (401, #"{"ok":false,"reason":"unknown-device"}"#),
        ])
        let probe: UplinkSession.Probe = { _, _ in .reachable(rttMilliseconds: 3) }
        let (session, store) = makeSession(suite: suite, server: server, probe: probe)
        store.save(Self.pairing())
        let connected = await session.connect()
        XCTAssertNotNil(connected)

        let request = URLRequest(url: URL(string: "http://10.0.0.5:18788/api/session/list")!)
        do {
            _ = try await session.sendWithTicket(request)
            XCTFail("两次 401 必须报错")
        } catch let error as UplinkError {
            XCTAssertEqual(error, .ticketRejected("unknown-device"))
        }
        XCTAssertEqual(server.requests.count, 4, "只重试一次，不能死循环（电脑端还有限流）")
    }

    @MainActor
    func testBadProofSurfacesAsUnauthorized() async {
        let suite = makeSuite()
        defer { suite.removePersistentDomain(forName: suite.description) }
        let server = StubServer([(401, #"{"ok":false,"reason":"bad-proof"}"#)])
        let probe: UplinkSession.Probe = { _, _ in .reachable(rttMilliseconds: 3) }
        let (session, store) = makeSession(suite: suite, server: server, probe: probe)
        store.save(Self.pairing())

        let tier = await session.connect()
        XCTAssertNil(tier, "换不到票就不算连上")
        XCTAssertEqual(session.lastError, UplinkError.unauthorized("bad-proof").errorDescription)
        XCTAssertNil(session.baseURL)
    }

    // MARK: 凭据存储

    @MainActor
    func testCredentialStoreRoundTrip() throws {
        let suite = makeSuite()
        defer { suite.removePersistentDomain(forName: suite.description) }
        let secrets = EphemeralSecretStore()
        let store = UplinkCredentialStore(secrets: secrets, defaults: suite)
        XCTAssertNil(store.loadPairing(), "没存过就是没配对")

        store.save(Self.pairing())
        let loaded = try XCTUnwrap(store.loadPairing())
        XCTAssertEqual(loaded.deviceId, "abc123")
        XCTAssertEqual(loaded.secret, Self.secret)
        XCTAssertEqual(loaded.urls.count, 2)

        // secret 在 Keychain（这里是内存替身），不在 UserDefaults 里
        let raw = suite.dictionaryRepresentation()
        XCTAssertFalse(raw.values.contains { ($0 as? String) == Self.secret }, "密钥不能落到 UserDefaults")

        store.clear()
        XCTAssertNil(store.loadPairing())
    }

    @MainActor
    func testHalfPairingIsTreatedAsNotPaired() throws {
        let suite = makeSuite()
        defer { suite.removePersistentDomain(forName: suite.description) }
        let store = UplinkCredentialStore(secrets: EphemeralSecretStore(), defaults: suite)
        store.save(Self.pairing())
        // 模拟 Keychain 被清掉（换机、重装）
        let wiped = UplinkCredentialStore(secrets: EphemeralSecretStore(), defaults: suite)
        XCTAssertNil(wiped.loadPairing(), "只有一半的配对材料比没有更危险")
    }

    // MARK: 设置

    @MainActor
    func testUplinkSettingsRoundTrip() {
        let suite = makeSuite()
        defer { suite.removePersistentDomain(forName: suite.description) }
        let settings = AppSettings(defaults: suite)
        XCTAssertEqual(settings.transportMode, .uplink, "全新安装默认「自动（多路接入）」")
        XCTAssertTrue(settings.uplinkEnabledTiers.isEmpty, "空集合 = 全开")

        settings.transportMode = .uplink
        settings.uplinkEnabledTiers = ["lan", "frp"]
        settings.uplinkLastGoodTier = "frp"
        settings.uplinkStickyUntil = Date(timeIntervalSince1970: 1_700_000_100)

        let reloaded = AppSettings(defaults: suite)
        XCTAssertEqual(reloaded.transportMode, .uplink)
        XCTAssertEqual(reloaded.uplinkEnabledTiers, ["lan", "frp"])
        XCTAssertEqual(reloaded.uplinkLastGoodTier, "frp")
        XCTAssertEqual(reloaded.uplinkStickyUntil?.timeIntervalSince1970, 1_700_000_100)
    }

    // MARK: HostCoordinator 接线

    @MainActor
    func testCoordinatorServesUplinkBaseURLAndTicket() async throws {
        let suite = makeSuite()
        defer { suite.removePersistentDomain(forName: suite.description) }
        let settings = AppSettings(defaults: suite)
        settings.transportMode = .uplink

        let server = StubServer([(200, Self.authOK)])
        let probe: UplinkSession.Probe = { _, _ in .reachable(rttMilliseconds: 3) }
        let store = UplinkCredentialStore(secrets: EphemeralSecretStore(), defaults: suite)
        let uplink = UplinkSession(
            store: store, settings: settings, probe: probe,
            send: { request in try await server.send(request) }, now: { Date() }
        )
        store.save(Self.pairing())
        let coordinator = HostCoordinator(
            settings: settings,
            session: TetherSession(store: EphemeralSecretStore(), deviceName: "test"),
            uplink: uplink
        )

        // 还没探测成功：不能假装在线
        do {
            _ = try await coordinator.baseURL()
            XCTFail("没探到档位时不该给出基址")
        } catch let error as DSHTransportError {
            XCTAssertEqual(error, .notConnected)
        }
        let readyBefore = await coordinator.isReady()
        XCTAssertFalse(readyBefore)

        let tier = await uplink.connect()
        XCTAssertNotNil(tier)
        coordinator.setUplinkBaseURL(uplink.baseURL)

        // 两档 RTT 相同（都是 3ms）时按档位优先级 —— 局域网优先，与电脑端一致。
        // 交给协议层的是**回环代理**：ATS 只放行本地地址（tailnet / 公网 IP 会 -1022）。
        let base = try await coordinator.baseURL()
        XCTAssertEqual(base.host, "127.0.0.1")
        XCTAssertEqual(uplink.currentTier?.url.absoluteString, "http://10.0.0.5:18788")
        let socket = try await coordinator.webSocketURL()
        XCTAssertEqual(socket.scheme, "ws")
        XCTAssertEqual(socket.host, "127.0.0.1")
        let readyAfter = await coordinator.isReady()
        XCTAssertTrue(readyAfter)

        let headers = await coordinator.requestHeaders()
        XCTAssertEqual(headers["Authorization"], "Bearer ticket-1", "uplink 的每个请求都要带票")
        XCTAssertEqual(coordinator.mode, .uplink(kind: "lan"))
    }

    @MainActor
    func testCoordinatorDropsTicketAfterFallingBackToIroh() async throws {
        let suite = makeSuite()
        defer { suite.removePersistentDomain(forName: suite.description) }
        let settings = AppSettings(defaults: suite)
        settings.transportMode = .uplink
        settings.gatewayToken = "should-not-leak"

        let server = StubServer([(200, Self.authOK)])
        let probe: UplinkSession.Probe = { _, _ in .reachable(rttMilliseconds: 3) }
        let store = UplinkCredentialStore(secrets: EphemeralSecretStore(), defaults: suite)
        let uplink = UplinkSession(
            store: store, settings: settings, probe: probe,
            send: { request in try await server.send(request) }, now: { Date() }
        )
        store.save(Self.pairing())
        let coordinator = HostCoordinator(
            settings: settings,
            session: TetherSession(store: EphemeralSecretStore(), deviceName: "test"),
            uplink: uplink
        )
        let tier = await uplink.connect()
        XCTAssertNotNil(tier)
        coordinator.setUplinkBaseURL(uplink.baseURL)

        // 降级：清掉 uplink 基址、改由 iroh 的本地代理提供基址
        coordinator.setUplinkBaseURL(nil)
        coordinator.setRemoteBaseURL(URL(string: "http://127.0.0.1:51234")!)

        let base = try await coordinator.baseURL()
        XCTAssertEqual(base.absoluteString, "http://127.0.0.1:51234")
        let headers = await coordinator.requestHeaders()
        XCTAssertTrue(headers.isEmpty, "走回 iroh 之后票据与网关令牌都不该带上")
    }

    // MARK: Bonjour 发现（纯逻辑）

    /// 一条 SRV 可能对应多条 A 记录（Wi-Fi + Tailscale + 虚拟网桥）。
    /// 只取第一条等于自己扔掉备选 —— 手机经常是"Wi-Fi 通、Tailscale 也通"。
    func testSockaddrParsingYieldsEveryIPv4() {
        let blobs = [
            Self.sockaddrData("10.8.54.221"),
            Self.sockaddrData("100.64.0.9"),
            Self.sockaddrData("127.0.0.1"),        // 回环：从手机看永远指自己，丢掉
            Data([0x01, 0x02]),                    // 太短，不是 sockaddr
        ]
        let addresses = UplinkBonjour.ipv4Addresses(from: blobs)
        XCTAssertEqual(addresses, ["10.8.54.221", "100.64.0.9"])
        XCTAssertEqual(UplinkBonjour.tiers(addresses: addresses, port: 18788).map(\.kind), [.lan, .tailscale])
    }

    func testTXTRecordParsing() {
        let txt = Self.txtData(["id=abc123", "port=18788", "v=0.3.0"])
        let parsed = UplinkBonjour.parseTXT(txt)
        XCTAssertEqual(parsed["id"], "abc123", "id 是唯一能把广播对上\"我配对的是哪台电脑\"的字段")
        XCTAssertEqual(parsed["port"], "18788")
        XCTAssertEqual(parsed["v"], "0.3.0")
        XCTAssertTrue(UplinkBonjour.parseTXT(Data()).isEmpty)
    }

    func testTiersNeedUsablePort() {
        XCTAssertTrue(UplinkBonjour.tiers(addresses: ["10.0.0.5"], port: 0).isEmpty)
        XCTAssertTrue(UplinkBonjour.tiers(addresses: ["10.0.0.5"], port: 70000).isEmpty)
        XCTAssertEqual(UplinkBonjour.tiers(addresses: ["10.0.0.5"], port: 18788).first?.url.absoluteString,
                       "http://10.0.0.5:18788")
    }

    /// `getaddrinfo` 这条只做"回环会被过滤"的断言：它不依赖任何网络，
    /// 而"真能解析出多 IP"要靠真实 mDNS 应答，CI 里没有。
    func testResolveHostFiltersLoopback() {
        XCTAssertTrue(UplinkBonjour.resolve(hostName: "localhost").isEmpty,
                      "回环地址不该进候选：从手机看 127.0.0.1 永远指自己")
    }

    func testMergeDedupesByNormalizedURL() throws {
        let a = try XCTUnwrap(UplinkTier(urlString: "http://10.0.0.5:18788"))
        let duplicate = try XCTUnwrap(UplinkTier(urlString: "http://10.0.0.5:18788/"))
        let other = try XCTUnwrap(UplinkTier(urlString: "http://192.168.1.9:18788"))
        let merged = UplinkBonjour.merge([a], [duplicate, other])
        XCTAssertEqual(merged.count, 2, "同一个地址（只差结尾斜杠）只能留一条")
        XCTAssertEqual(merged.first?.kind, a.kind, "先来的那条带着更可信的 kind，要留住")
    }

    // MARK: 探测失败原因

    func testURLErrorMapping() {
        XCTAssertEqual(UplinkProbeFailure(urlError: URLError(.timedOut), milliseconds: 832),
                       .timedOut(milliseconds: 832))
        XCTAssertEqual(UplinkProbeFailure(urlError: URLError(.cannotConnectToHost), milliseconds: 12),
                       .refused(milliseconds: 12))
        XCTAssertEqual(UplinkProbeFailure(urlError: URLError(.notConnectedToInternet), milliseconds: 3),
                       .offline(milliseconds: 3))
        XCTAssertEqual(UplinkProbeFailure(urlError: URLError(.networkConnectionLost), milliseconds: 4),
                       .offline(milliseconds: 4))
        XCTAssertEqual(UplinkProbeFailure(urlError: URLError(.cannotFindHost), milliseconds: 5),
                       .unknownHost(milliseconds: 5))
        XCTAssertEqual(UplinkProbeFailure(urlError: URLError(.badServerResponse), milliseconds: 7).category, .other)
    }

    func testFailureLogLabelIsStableAndNotLocalized() {
        // 日志里要能直接 grep 出 URLError 的语义（翻译过反而对不上系统日志）。
        XCTAssertEqual(UplinkProbeFailure.timedOut(milliseconds: 832).logLabel, "timedOut(832ms)")
        XCTAssertEqual(UplinkProbeFailure.refused(milliseconds: 12).logLabel, "refused(12ms)")
        XCTAssertEqual(UplinkProbeFailure.hostMismatch(milliseconds: 5).category, .mismatch)
    }

    func testFailureSummaryPicksTheMostActionableCategory() {
        let timeout = UplinkProbeFailure.summary(for: [.timedOut(milliseconds: 800)])
        let refused = UplinkProbeFailure.summary(for: [.refused(milliseconds: 10)])
        let offline = UplinkProbeFailure.summary(for: [.offline(milliseconds: 2)])
        // 三类成因的文案必须互不相同 —— 糊成一句就等于什么都没说。
        XCTAssertNotEqual(timeout, refused)
        XCTAssertNotEqual(refused, offline)
        // 没网能解释其余一切：优先级最高（文案里带条数，所以用同样两条来比）。
        XCTAssertEqual(
            UplinkProbeFailure.summary(for: [.timedOut(milliseconds: 800), .offline(milliseconds: 2)]),
            UplinkProbeFailure.summary(for: [.offline(milliseconds: 2), .offline(milliseconds: 9)])
        )
        // 超时比"被拒"更可能是根因（被拒说明地址是通的）。
        XCTAssertEqual(
            UplinkProbeFailure.summary(for: [.timedOut(milliseconds: 800), .refused(milliseconds: 10)]),
            UplinkProbeFailure.summary(for: [.timedOut(milliseconds: 800), .timedOut(milliseconds: 801)])
        )
        XCTAssertFalse(UplinkProbeFailure.summary(for: []).isEmpty)
    }

    // MARK: 网络类型（蜂窝跳过局域网）

    /// 真机 0.5.0 的事故形状：手机只有 5G，配对串里只有一个私有地址。
    /// 正确行为是**立刻说清楚**，而不是探 800ms 再报一句"都失败了"。
    @MainActor
    func testCellularSkipsLanTiersWithoutProbing() async {
        let suite = makeSuite()
        defer { suite.removePersistentDomain(forName: suite.description) }
        let counter = Counter()
        let probe: UplinkSession.Probe = { _, _ in
            counter.count += 1
            return .reachable(rttMilliseconds: 5)
        }
        let (session, store) = makeSession(
            suite: suite, server: StubServer([]), probe: probe, network: .cellular
        )
        store.save(Self.pairing(urls: ["http://10.8.54.221:18788"]))

        let tier = await session.connect()
        XCTAssertNil(tier)
        XCTAssertEqual(counter.count, 0, "蜂窝下探私有地址是纯粹的白等，一个包都不该发")
        XCTAssertEqual(session.lastError, UplinkSession.noUsableTierMessage(for: .cellular, skipped: 1))
        XCTAssertTrue(session.lastError?.contains("iroh") == true, "文案要指出缺的是 iroh / Tailscale / 自建中转")
    }

    @MainActor
    func testCellularStillProbesTailscaleAndRelay() async throws {
        let suite = makeSuite()
        defer { suite.removePersistentDomain(forName: suite.description) }
        let server = StubServer([(200, Self.authOK)])
        var probed: [UplinkTierKind] = []
        let probe: UplinkSession.Probe = { tier, _ in
            probed.append(tier.kind)
            return .reachable(rttMilliseconds: 5)
        }
        let (session, store) = makeSession(
            suite: suite, server: server, probe: probe, network: .cellular
        )
        store.save(Self.pairing(urls: ["http://10.8.54.221:18788", "http://100.64.0.1:18788"]))

        let connected = await session.connect()
        let tier = try XCTUnwrap(connected)
        XCTAssertEqual(tier.kind, .tailscale, "Tailscale 走自己的隧道，蜂窝下照样能连")
        XCTAssertFalse(probed.contains(.lan), "局域网档仍然要被跳过")
    }

    @MainActor
    func testCellularSkipsBonjourDiscovery() async {
        let suite = makeSuite()
        defer { suite.removePersistentDomain(forName: suite.description) }
        let counter = Counter()
        let probe: UplinkSession.Probe = { _, _ in .unreachable(.timedOut(milliseconds: 800)) }
        let (session, store) = makeSession(
            suite: suite,
            server: StubServer([]),
            probe: probe,
            discover: { _ in counter.count += 1; return [] },
            network: .cellular
        )
        store.save(Self.pairing(urls: ["http://100.64.0.1:18788"]))

        _ = await session.connect()
        XCTAssertEqual(counter.count, 0, "mDNS 只在链路本地有意义，蜂窝下发现等于白等 1.5 秒")
    }

    // MARK: Bonjour 兜底探测

    @MainActor
    func testDiscoveryRunsAfterSnapshotFailsAndPersists() async throws {
        let suite = makeSuite()
        defer { suite.removePersistentDomain(forName: suite.description) }
        let discovered = "http://192.168.1.50:18788"
        let server = StubServer([(200, Self.authOK)])
        let probe: UplinkSession.Probe = { tier, _ in
            tier.url.absoluteString == discovered
                ? .reachable(rttMilliseconds: 4)
                : .unreachable(.timedOut(milliseconds: 800))
        }
        let (session, store) = makeSession(
            suite: suite,
            server: server,
            probe: probe,
            discover: { _ in [UplinkTier(kind: .lan, url: URL(string: discovered)!)] }
        )
        store.save(Self.pairing(urls: ["http://10.8.54.221:18788"]))

        let connected = await session.connect()
        let tier = try XCTUnwrap(connected)
        XCTAssertEqual(tier.url.absoluteString, discovered, "快照地址死了就该用发现到的地址")
        XCTAssertEqual(session.currentTier?.url.absoluteString, discovered)
        XCTAssertEqual(session.baseURL?.host, "127.0.0.1", "协议层拿到的是回环代理")
        // 回写配对材料：下次启动不用再发现一次。
        XCTAssertEqual(store.loadPairing()?.urls.contains(discovered), true)
        XCTAssertEqual(store.loadDiscovered()?.tiers.first?.url.absoluteString, discovered)
    }

    @MainActor
    func testDiscoveryIsNotRunWhenSnapshotAlreadyWorks() async throws {
        let suite = makeSuite()
        defer { suite.removePersistentDomain(forName: suite.description) }
        let counter = Counter()
        let (session, store) = makeSession(
            suite: suite,
            server: StubServer([(200, Self.authOK)]),
            probe: { _, _ in .reachable(rttMilliseconds: 3) },
            discover: { _ in counter.count += 1; return [] }
        )
        store.save(Self.pairing())

        let connected = await session.connect()
        XCTAssertNotNil(connected)
        XCTAssertEqual(counter.count, 0, "能连上就别去打扰 mDNS")
    }

    @MainActor
    func testDiscoveredAddressesAreCandidatesNextTime() async throws {
        let suite = makeSuite()
        defer { suite.removePersistentDomain(forName: suite.description) }
        let store = UplinkCredentialStore(secrets: EphemeralSecretStore(), defaults: suite)
        let url = try XCTUnwrap(URL(string: "http://192.168.1.77:18788"))
        store.save(Self.pairing(urls: []))
        store.saveDiscovered([UplinkTier(kind: .lan, url: url)], at: Date())

        let (session, _) = makeSession(
            suite: suite,
            server: StubServer([(200, Self.authOK)]),
            probe: { _, _ in .reachable(rttMilliseconds: 2) },
            store: store
        )
        let connected = await session.connect()
        XCTAssertNotNil(connected, "连不上：\(session.lastError ?? "—")")
        let tier = try XCTUnwrap(connected)
        XCTAssertEqual(tier.url.absoluteString, url.absoluteString,
                       "上次发现到的地址在有效期内要直接当候选，不用再发现一次")
    }

    // MARK: iroh 配对窗口

    func testIrohPairingStringParsing() throws {
        let issued = try XCTUnwrap(UplinkIrohPairing(
            pairingString: "cc8a1078aabbccdd#741231", endpointId: "cc8a1078aabbccdd", expiresInSec: 600
        ))
        XCTAssertEqual(issued.endpointId, "cc8a1078aabbccdd")
        XCTAssertEqual(issued.code, "741231")
        XCTAssertEqual(issued.expiresInSec, 600)

        XCTAssertNil(UplinkIrohPairing(pairingString: "no-separator", endpointId: nil, expiresInSec: 0))
        XCTAssertNil(UplinkIrohPairing(pairingString: "abc#", endpointId: nil, expiresInSec: 0))
        // endpointId 字段和串里的对不上：宁可不信，也别拿一个连不上的组合去白试。
        XCTAssertNil(UplinkIrohPairing(pairingString: "abc#123456", endpointId: "def", expiresInSec: 600))
    }

    @MainActor
    func testRequestIrohPairingUsesTicket() async throws {
        let suite = makeSuite()
        defer { suite.removePersistentDomain(forName: suite.description) }
        let server = StubServer([
            (200, Self.authOK),
            (200, #"{"ok":true,"endpointId":"cc8a1078","pairingString":"cc8a1078#741231","expiresInSec":600}"#),
        ])
        let (session, store) = makeSession(
            suite: suite, server: server, probe: { _, _ in .reachable(rttMilliseconds: 3) }
        )
        store.save(Self.pairing())
        let connected = await session.connect()
        XCTAssertNotNil(connected)

        let issued = try await session.requestIrohPairing()
        XCTAssertEqual(issued.endpointId, "cc8a1078")
        XCTAssertEqual(issued.code, "741231")

        let request = try XCTUnwrap(server.requests.last)
        XCTAssertEqual(request.url?.path, "/uplink/iroh-pairing")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer ticket-1",
                       "这条路由要票：票据是唯一的凭据")
    }

    @MainActor
    func testRequestIrohPairingWithoutTicketFails() async {
        let suite = makeSuite()
        defer { suite.removePersistentDomain(forName: suite.description) }
        let (session, store) = makeSession(
            suite: suite, server: StubServer([]), probe: { _, _ in .reachable(rttMilliseconds: 3) }
        )
        store.save(Self.pairing())
        do {
            _ = try await session.requestIrohPairing()
            XCTFail("没有票就不该能换到配对码")
        } catch let error as UplinkIrohPairingError {
            XCTAssertEqual(error, .noTicket)
        } catch {
            XCTFail("错误的错误类型：\(error)")
        }
    }

    @MainActor
    func testRequestIrohPairingUnavailableOn503() async throws {
        let suite = makeSuite()
        defer { suite.removePersistentDomain(forName: suite.description) }
        let server = StubServer([
            (200, Self.authOK),
            (503, #"{"ok":false,"reason":"iroh-unavailable"}"#),
        ])
        let (session, store) = makeSession(
            suite: suite, server: server, probe: { _, _ in .reachable(rttMilliseconds: 3) }
        )
        store.save(Self.pairing())
        let connected = await session.connect()
        XCTAssertNotNil(connected)
        do {
            _ = try await session.requestIrohPairing()
            XCTFail("503 要当成「这一档不可用」")
        } catch let error as UplinkIrohPairingError {
            XCTAssertEqual(error, .unavailable)
        }
    }

    // MARK: iroh 兜底编排

    /// 主路：配对串里带着码 → 第一次连就把码带上，成了就再也不请求那条路由。
    ///
    /// 这是死锁修复的核心：配对走 iroh 通道本身，**不需要任何 HTTP 请求**，
    /// 所以 5G + 局域网完全不可达也能配上。
    @MainActor
    func testIrohFallbackUsesPairingCodeWithoutAnyHTTP() async throws {
        var calls: [(String, String?)] = []
        var pairingRequests = 0
        let outcome = await UplinkIrohFallback.run(
            endpointId: "cc8a1078",
            pairingCode: "741231",
            connect: { host, code in
                calls.append((host, code))
                return .connected
            },
            requestPairing: { pairingRequests += 1; return .failure(.noTicket) }
        )
        XCTAssertEqual(outcome, .connected)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].0, "cc8a1078")
        XCTAssertEqual(calls[0].1, "741231", "配对串里的码要直接用上")
        XCTAssertEqual(pairingRequests, 0, "配上了就别再请求 /uplink/iroh-pairing")
    }

    /// 没有码、也没有票（网关全不可达）→ 如实说"需要配对但没有票"，不假装在重试。
    @MainActor
    func testIrohFallbackWithoutCodeOrTicket() async {
        var calls = 0
        let outcome = await UplinkIrohFallback.run(
            endpointId: "cc8a1078",
            pairingCode: nil,
            connect: { _, _ in calls += 1; return .needsPairing("还没有和这台电脑配对") },
            requestPairing: { .failure(.noTicket) }
        )
        XCTAssertEqual(outcome, .needsPairingWithoutTicket)
        XCTAssertEqual(calls, 1, "只连一次：没有码就没有第二次可试的")
    }

    /// 带了码却被拒（窗口过期）+ 网关不可达 → **明确报"码过期"**，不静默重试。
    @MainActor
    func testIrohFallbackReportsExpiredCode() async {
        var calls = 0
        var pairingRequests = 0
        let outcome = await UplinkIrohFallback.run(
            endpointId: "cc8a1078",
            pairingCode: "111111",
            connect: { _, _ in calls += 1; return .codeRejected("配对窗口已过期。") },
            requestPairing: { pairingRequests += 1; return .failure(.noTicket) }
        )
        XCTAssertEqual(outcome, .pairingCodeExpired)
        XCTAssertEqual(calls, 1, "过期的码不要再试第二遍")
        XCTAssertEqual(pairingRequests, 1, "先问一次能不能刷新（有票就能刷新，没票才报过期）")
    }

    /// 码被拒但网关可达 → 用票据刷新一次，拿到新码再连。
    @MainActor
    func testIrohFallbackRefreshesCodeWhenGatewayReachable() async throws {
        var calls: [(String, String?)] = []
        let outcome = await UplinkIrohFallback.run(
            endpointId: "old",
            pairingCode: "111111",
            connect: { host, code in
                calls.append((host, code))
                return code == "111111" ? .codeRejected("bad-code") : .connected
            },
            requestPairing: {
                .success(UplinkIrohPairing(
                    pairingString: "cc8a1078#741231", endpointId: "cc8a1078", expiresInSec: 600
                )!)
            }
        )
        XCTAssertEqual(outcome, .connected)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[1].0, "cc8a1078", "第二次要用电脑端给的 endpointId")
        XCTAssertEqual(calls[1].1, "741231")
    }

    @MainActor
    func testIrohFallbackSkipsPairingWhenAlreadyPaired() async {
        var calls = 0
        var pairingRequests = 0
        let outcome = await UplinkIrohFallback.run(
            endpointId: "known",
            pairingCode: nil,
            connect: { _, code in
                calls += 1
                XCTAssertNil(code, "已配对时不该带配对码（电脑端会判成协议错误）")
                return .connected
            },
            requestPairing: { pairingRequests += 1; return .failure(.noTicket) }
        )
        XCTAssertEqual(outcome, .connected)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(pairingRequests, 0, "已经配对过就不要再请求这条路由")
    }

    @MainActor
    func testIrohFallbackStopsOn503() async {
        var calls = 0
        let outcome = await UplinkIrohFallback.run(
            endpointId: "old",
            pairingCode: "111111",
            connect: { _, _ in calls += 1; return .codeRejected("bad-code") },
            requestPairing: { .failure(.unavailable) }
        )
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertEqual(calls, 1, "503 = 电脑端没跑 iroh 档，不重试")
    }

    @MainActor
    func testIrohFallbackDoesNotPairOnNetworkFailure() async {
        var calls = 0
        var pairingRequests = 0
        let outcome = await UplinkIrohFallback.run(
            endpointId: "old",
            pairingCode: "111111",
            connect: { _, _ in calls += 1; return .failed("连接失败：超时") },
            requestPairing: { pairingRequests += 1; return .failure(.noTicket) }
        )
        XCTAssertEqual(outcome, .failed("连接失败：超时"))
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(pairingRequests, 0, "网络类失败换配对码也没用，别去骚扰电脑端")
    }

    // MARK: 配对码的有效期

    func testPairingCodeExpiry() throws {
        let now = Date(timeIntervalSince1970: 1_792_000_000)
        let fresh = try XCTUnwrap(UplinkPairing(
            hostId: "h", name: "n", port: 18788, deviceId: "d", secret: Self.secret,
            urls: [], irohEndpointId: "cc8a1078", irohCode: "123456",
            irohExpiresAt: Int64(now.addingTimeInterval(300).timeIntervalSince1970 * 1000),
            issuedAt: 1
        ))
        XCTAssertFalse(fresh.irohCodeExpired(now: now))
        XCTAssertTrue(fresh.canPairIroh(now: now))

        let stale = try XCTUnwrap(UplinkPairing(
            hostId: "h", name: "n", port: 18788, deviceId: "d", secret: Self.secret,
            urls: [], irohEndpointId: "cc8a1078", irohCode: "123456",
            irohExpiresAt: Int64(now.addingTimeInterval(-1).timeIntervalSince1970 * 1000),
            issuedAt: 1
        ))
        XCTAssertTrue(stale.irohCodeExpired(now: now))
        XCTAssertFalse(stale.canPairIroh(now: now), "过期的码不能拿去试：电脑端会记一次失败")

        // 没有 expiresAt 的老配对串：按"未过期"处理，试一次才知道行不行。
        let legacy = try XCTUnwrap(UplinkPairing(
            hostId: "h", name: "n", port: 18788, deviceId: "d", secret: Self.secret,
            urls: [], irohEndpointId: "cc8a1078", irohCode: "123456", issuedAt: 1
        ))
        XCTAssertFalse(legacy.irohCodeExpired(now: now))
    }

    func testPairingCarriesIrohCodeThroughEncodeDecode() throws {
        let original = try XCTUnwrap(UplinkPairing(
            hostId: "host-1", name: "Mac", port: 18788, deviceId: "d", secret: Self.secret,
            urls: [], irohEndpointId: "cc8a1078aabb", irohRelay: "https://relay.example",
            irohCode: "741231", irohExpiresAt: 1_792_670_400_000, issuedAt: 1
        ))
        let parsed = try XCTUnwrap(UplinkPairing.parse(original.encodedString()))
        XCTAssertEqual(parsed.irohEndpointId, "cc8a1078aabb")
        XCTAssertEqual(parsed.irohCode, "741231", "码必须跟着配对串走 —— 否则 iroh 兜底又回到死锁")
        XCTAssertEqual(parsed.irohExpiresAt, 1_792_670_400_000)
        XCTAssertEqual(parsed.irohRelay, "https://relay.example")
    }

    // MARK: iroh endpoint 的来源

    @MainActor
    func testIrohHostIdPrefersPairingEndpoint() {
        let pairing = Self.pairing(irohEndpointId: "pairing-endpoint")
        XCTAssertEqual(AppModel.irohHostId(pairing: pairing, activeHostId: "stale-endpoint"),
                       "pairing-endpoint",
                       "配对串里的 endpointId 才是这台电脑现在的身份")
        XCTAssertEqual(AppModel.irohHostId(pairing: nil, activeHostId: "stale-endpoint"), "stale-endpoint",
                       "没有配对串信息时才退回上次配对的身份")
        XCTAssertNil(AppModel.irohHostId(pairing: nil, activeHostId: "  "))
        XCTAssertEqual(AppModel.irohHostId(pairing: Self.pairing(irohEndpointId: ""), activeHostId: "old"),
                       "old", "空的 endpointId 不能顶掉有效值")
    }

    @MainActor
    func testCredentialStorePersistsTiersAndIrohEndpoint() throws {
        let suite = makeSuite()
        defer { suite.removePersistentDomain(forName: suite.description) }
        let store = UplinkCredentialStore(secrets: EphemeralSecretStore(), defaults: suite)
        let url = try XCTUnwrap(URL(string: "http://10.147.20.5:18788"))
        store.save(Self.pairing(
            urls: [url.absoluteString],
            hintedTiers: [UplinkTier(kind: .zerotier, url: url)],
            irohEndpointId: "cc8a1078"
        ))

        let loaded = try XCTUnwrap(store.loadPairing())
        XCTAssertEqual(loaded.hintedTiers.first?.kind, .zerotier,
                       "kind 必须持久化，否则重启后 ZeroTier 会被重新猜成局域网")
        XCTAssertEqual(loaded.irohEndpointId, "cc8a1078",
                       "iroh endpoint 必须持久化，否则降级时只能退回那个已失效的旧身份")
    }

    // MARK: 连接方式迁移（0.5.2：App 里只保留 uplink）

    /// 三条规则：有 uplink 配对就迁；没有但还有 iroh 主机就留着；
    /// 什么都没有（全新安装）就走 uplink。
    func testTransportModeMigrationRules() {
        // ① 老用户装过一次、也粘过配对串 → 迁到 uplink
        XCTAssertEqual(
            TransportMode.resolvedTransportMode(stored: .remote, hasUplinkPairing: true, hasIrohHost: true),
            .uplink
        )
        XCTAssertEqual(
            TransportMode.resolvedTransportMode(stored: .remote, hasUplinkPairing: true, hasIrohHost: false),
            .uplink
        )

        // ② 只有旧的 iroh 配对 → **保持 .remote**，静默继续用 iroh
        //    （切成 uplink 会让他在粘新配对串之前彻底连不上）
        XCTAssertEqual(
            TransportMode.resolvedTransportMode(stored: .remote, hasUplinkPairing: false, hasIrohHost: true),
            .remote
        )

        // ③ 全新安装 / 什么都没配 → uplink
        XCTAssertEqual(
            TransportMode.resolvedTransportMode(stored: .remote, hasUplinkPairing: false, hasIrohHost: false),
            .uplink
        )

        // 幂等：已经是 uplink 的永远不动（否则每次启动都会写一遍）
        XCTAssertEqual(
            TransportMode.resolvedTransportMode(stored: .uplink, hasUplinkPairing: false, hasIrohHost: true),
            .uplink
        )

        // 开发者模式（defaults write 打开的）不参与迁移
        XCTAssertEqual(
            TransportMode.resolvedTransportMode(stored: .devDirect, hasUplinkPairing: true, hasIrohHost: true),
            .devDirect
        )
        XCTAssertEqual(
            TransportMode.resolvedTransportMode(stored: .directGateway, hasUplinkPairing: true, hasIrohHost: true),
            .directGateway
        )
    }

    /// 老值必须仍然能解码（不能因为删了 UI 就让老用户的 defaults 解析失败）。
    func testLegacyTransportModeRawValuesStillDecode() {
        XCTAssertEqual(TransportMode(rawValue: "remote"), .remote)
        XCTAssertEqual(TransportMode(rawValue: "devDirect"), .devDirect)
        XCTAssertEqual(TransportMode(rawValue: "directGateway"), .directGateway)
        XCTAssertEqual(TransportMode(rawValue: "uplink"), .uplink)
    }

    /// 全新安装默认就是 uplink（App 里不再有"另一种连接方式"可选）。
    @MainActor
    func testFreshInstallDefaultsToUplink() {
        let suite = makeSuite()
        defer { suite.removePersistentDomain(forName: suite.description) }
        XCTAssertEqual(AppSettings(defaults: suite).transportMode, .uplink)
    }
}

/// 计数盒子：`@Sendable` 闭包里改可变状态用（Swift 并发下不能用裸 `var`）。
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var count: Int {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}
