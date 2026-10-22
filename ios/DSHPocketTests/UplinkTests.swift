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
        now: @escaping () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) }
    ) -> (UplinkSession, UplinkCredentialStore) {
        let settings = AppSettings(defaults: suite)
        let store = UplinkCredentialStore(secrets: EphemeralSecretStore(), defaults: suite)
        let session = UplinkSession(
            store: store,
            settings: settings,
            probe: probe,
            send: { request in try await server.send(request) },
            now: now
        )
        return (session, store)
    }

    private static func pairing(
        urls: [String] = ["http://10.0.0.5:18788", "http://100.64.0.1:18788"],
        secret: String = UplinkTests.secret
    ) -> UplinkPairing {
        UplinkPairing(
            hostId: "host-1234abcd",
            name: "书房的 Mac",
            port: 18788,
            deviceId: "abc123",
            secret: secret,
            urls: urls,
            issuedAt: 1_700_000_000_000
        )!
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
                return 150
            case .tailscale:
                try? await Task.sleep(for: .milliseconds(10))
                return 10
            default:
                return nil
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
        XCTAssertEqual(session.baseURL?.absoluteString, "http://100.64.0.1:18788")
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
            return tier.kind == .lan ? 300 : 5
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
            tier.kind == .lan ? nil : 7
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
            tier.kind == .lan ? 400 : 3
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
            return 5
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
        let probe: UplinkSession.Probe = { _, _ in nil }
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
        let probe: UplinkSession.Probe = { _, _ in 1 }
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
        let probe: UplinkSession.Probe = { _, _ in 3 }
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
        let probe: UplinkSession.Probe = { _, _ in 3 }
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
        let probe: UplinkSession.Probe = { _, _ in 3 }
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
        let probe: UplinkSession.Probe = { _, _ in 3 }
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
        let probe: UplinkSession.Probe = { _, _ in 3 }
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
        let probe: UplinkSession.Probe = { _, _ in 3 }
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
        XCTAssertEqual(settings.transportMode, .remote, "老用户默认仍然是 iroh")
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
        let probe: UplinkSession.Probe = { _, _ in 3 }
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
        let base = try await coordinator.baseURL()
        XCTAssertEqual(base.absoluteString, "http://10.0.0.5:18788")
        let socket = try await coordinator.webSocketURL()
        XCTAssertEqual(socket.absoluteString, "ws://10.0.0.5:18788")
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
        let probe: UplinkSession.Probe = { _, _ in 3 }
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
}
