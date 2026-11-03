import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import Crypto
import VoiceRemoteProtocol
@testable import Pairing

private actor FakeSocket: WebSocket {
    var sent: [String] = []
    var messages: [WebSocketMessage] = []
    var closed = false
    var pings = 0
    var silent = false
    var failSend = false
    func send(text: String) throws {
        guard !closed, !failSend else { throw PairingError.closedTransport }
        sent.append(text)
    }
    func receive() throws -> WebSocketMessage {
        guard !closed, !messages.isEmpty else { throw PairingError.closedTransport }
        return messages.removeFirst()
    }
    func ping() async throws {
        pings += 1
        if silent { try await Task.sleep(for: .seconds(1000)) }
        guard !closed else { throw PairingError.closedTransport }
    }
    func close() { closed = true }
    func configure(messages: [WebSocketMessage] = [], silent: Bool = false, failSend: Bool = false) {
        self.messages = messages; self.silent = silent; self.failSend = failSend
    }
}

/// Independently checks exact request hashes and Ed25519 signatures. It never
/// uses RelayClient's signing helpers to verify a client proof.
private actor MemberRelay: RelayHTTP, WebSocketConnector {
    private(set) var socket = FakeSocket()
    let route: RelayRoute
    let token = Data(repeating: 7, count: 32).base64EncodedString()
    private var key: Curve25519.Signing.PublicKey?
    private var proof: String?
    private var joined = false
    private var serverTime: Int64 = 1
    private var refusal = false
    private var loseJoin = false
    private var consumed = false
    private var failures = 0
    private var challengeFault = 0
    private var dropped = "17"
    var connects = 0
    var revokes = 0
    init(route: RelayRoute) { self.route = route }
    func configure(failures: Int = 0, fault: Int = 0, dropped: String = "17") { self.failures = failures; challengeFault = fault; self.dropped = dropped }
    func setServerTime(_ value: Int64) { serverTime = value }
    func refuseMember() { refusal = true }
    func loseJoinResponse() { loseJoin = true }
    private func bytes(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes, .sortedKeys]) }
    private func signature(_ text: String?, message: Data, publicKey: Curve25519.Signing.PublicKey) throws {
        guard let text, let signature = Data(base64Encoded: text), publicKey.isValidSignature(signature, for: message) else { throw PairingError.invalidMessage }
    }
    func perform(_ request: RelayRequest) throws -> RelayResponse {
        XCTAssertEqual(request.method, "POST"); XCTAssertEqual(request.url.scheme, "https")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        let operation = request.url.lastPathComponent
        if operation == "join" {
            XCTAssertEqual(Set(body.keys), ["device_id", "public_key", "one_use_token", "expires_at", "signature"])
            guard !joined, body["device_id"] as? String == route.device, body["one_use_token"] as? String == token,
                  body["expires_at"] as? Int == 120_001 else { return .init(status: 403, body: Data()) }
            let rawKey = try XCTUnwrap(body["public_key"] as? String)
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: XCTUnwrap(Data(base64Encoded: rawKey)))
            try signature(body["signature"] as? String, message: bytes(["voiceremote-relay-join-v1", route.account, route.room, route.device, rawKey, token, 120_001]), publicKey: publicKey)
            key = publicKey; joined = true
            if loseJoin { loseJoin = false; throw PairingError.closedTransport }
            return .init(status: 201, body: Data("{\"joined\":true}".utf8))
        }
        if refusal { return .init(status: 403, body: Data()) }
        let key = try XCTUnwrap(key)
        if operation == "challenge" {
            XCTAssertEqual(Set(body.keys), ["device_id", "operation", "body_sha256"])
            let digest = Data(SHA256.hash(data: request.body)).base64EncodedString()
            try signature(request.headers["X-Relay-Signature"], message: bytes(["voiceremote-relay-challenge-v1", route.account, route.room, digest]), publicKey: key)
            let op = try XCTUnwrap(body["operation"] as? String)
            let hash = try XCTUnwrap(body["body_sha256"] as? String)
            let nonce = Data(repeating: 9, count: 32).base64EncodedString()
            let values: [Any] = ["voiceremote-relay-auth-v1", challengeFault == 1 ? "wrong" : route.account, route.room, route.device, op, hash, nonce, serverTime + 60_000]
            let message = String(decoding: try bytes(values), as: UTF8.self)
            proof = message; consumed = false
            var response: [String: Any] = ["challenge": nonce, "message": message, "expires_at": serverTime + 60_000, "server_time": serverTime]
            if challengeFault == 2 { response["expires_at"] = 1 }
            if challengeFault == 3 { response["extra"] = "refuse" }
            var raw = try bytes(response)
            if challengeFault == 4 { raw = Data(String(decoding: raw, as: UTF8.self).replacingOccurrences(of: "60001", with: "60001.0").utf8) }
            if challengeFault == 5 { raw = Data(("{\"server_time\":1," + String(decoding: raw.dropFirst(), as: UTF8.self)).utf8) }
            if challengeFault == 6 { response["server_time"] = 60_001; raw = try bytes(response) }
            return .init(status: 200, body: raw)
        }
        if operation == "revoke" {
            try authorize(request)
            revokes += 1; return .init(status: 200, body: Data("{\"revoked\":true}".utf8))
        }
        throw PairingError.invalidMessage
    }
    private func authorize(_ request: RelayRequest) throws {
        guard !consumed, let proof, let key, request.headers["X-Relay-Challenge"] == Data(repeating: 9, count: 32).base64EncodedString() else { throw PairingError.invalidMessage }
        try signature(request.headers["X-Relay-Signature"], message: Data(proof.utf8), publicKey: key)
        // Exact body binding includes the empty GET body.
        let array = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(proof.utf8)) as? [Any])
        XCTAssertEqual(array[4] as? String, request.url.lastPathComponent)
        XCTAssertEqual(array[5] as? String, Data(SHA256.hash(data: request.body)).base64EncodedString())
        consumed = true
    }
    func verifyProxy(_ request: URLRequest, operation: String, bytes expectedBytes: Data) throws {
        let proof = try XCTUnwrap(proof), key = try XCTUnwrap(key)
        let values = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(proof.utf8)) as? [Any])
        XCTAssertEqual(values[4] as? String, operation)
        XCTAssertEqual(values[5] as? String, Data(SHA256.hash(data: expectedBytes)).base64EncodedString())
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Relay-Challenge"), Data(repeating: 9, count: 32).base64EncodedString())
        try signature(request.value(forHTTPHeaderField: "X-Relay-Signature"), message: Data(proof.utf8), publicKey: key)
    }
    func connect(_ request: RelayRequest) throws -> WebSocketUpgrade {
        XCTAssertEqual(request.method, "GET"); XCTAssertEqual(request.url.scheme, "wss"); XCTAssertTrue(request.body.isEmpty)
        try authorize(request); connects += 1
        if failures > 0 { failures -= 1; throw PairingError.closedTransport }
        socket = FakeSocket()
        return .init(socket: socket, headers: ["X-Relay-Dropped-Frames": dropped])
    }
}
private actor RecordingSleeper: RelaySleeper {
    var delays: [Duration] = []
    let cancelAfter: Int?
    init(cancelAfter: Int? = nil) { self.cancelAfter = cancelAfter }
    func sleep(for duration: Duration) throws {
        delays.append(duration)
        if delays.count == cancelAfter { throw CancellationError() }
    }
}

final class NoiseRelayTests: XCTestCase, @unchecked Sendable {
    private func setup(loseResponse: Bool = false) async throws -> (RelayClient, MemberRelay, PairingInvitation) {
        let route = try RelayRoute(account: "synthetic", room: String(repeating: "a", count: 32), device: "phone")
        let fake = MemberRelay(route: route)
        let client = try RelayClient(origin: URL(string: "https://relay.invalid")!, route: route, signingKey: .init(), http: fake, connector: fake, clock: TestClock(now: 1))
        let payload = PairingPayload(account_id: route.account, desktop_public_key: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString(), one_use_token: Data(repeating: 7, count: 32).base64EncodedString(), expires_at: 120_001, relay_room_id: route.room)
        let invitation = try PairingInvitation(qr: ProtocolCodec.encode(payload), expectedAccount: route.account, clock: TestClock(now: 1))
        if loseResponse { await fake.loseJoinResponse() }
        try await client.redeem(invitation)
        return (client, fake, invitation)
    }
    func testFirstJoinOwnKeyChallengeConnectDropCountAndRevoke() async throws {
        try await testDeadline(seconds: 20) { [self] in
            let (client, fake, invitation) = try await setup()
            try await client.redeem(invitation) // existing member proves possession; no token reuse
            let transport = try await client.connect()
            let dropped = await transport.droppedFrames; XCTAssertEqual(dropped, 17)
            let sent = await fake.socket.sent
            XCTAssertEqual(sent.count, 1)
            let presence = try ProtocolCodec.decode(RelayPresence.self, from: Data(sent[0].utf8))
            XCTAssertEqual(presence.state, .online)
            try await client.revoke(device: "desktop")
            let revokes = await fake.revokes; XCTAssertEqual(revokes, 1)
            await transport.close()
        }
    }
    func testChallengeContextGrammarAndExpiryFailClosed() async throws {
        try await testDeadline(seconds: 20) { [self] in
            for fault in 1...6 {
                let (client, fake, _) = try await setup(); await fake.configure(fault: fault)
                do { _ = try await client.connect(); XCTFail("challenge fault \(fault) accepted") } catch {}
                let connects = await fake.connects; XCTAssertEqual(connects, 0)
            }
        }
    }
    func testReconnectBackoffCapsAndCancellation() async throws {
        try await testDeadline(seconds: 20) { [self] in
            let (client, fake, _) = try await setup(); await fake.configure(failures: 8)
            let sleeper = RecordingSleeper()
            let transport = try await client.reconnect(sleeper: sleeper)
            let delays = await sleeper.delays
            XCTAssertEqual(delays, [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30), .seconds(30)])
            await transport.close()
            let (other, failing, _) = try await setup(); await failing.configure(failures: 100)
            do { _ = try await other.reconnect(sleeper: RecordingSleeper(cancelAfter: 1)); XCTFail() } catch is CancellationError {} catch { XCTFail("wrong cancellation") }
        }
    }
    func testRelayFramingRouteMetadataAndLimits() async throws {
        try await testDeadline(seconds: 20) { [self] in
            for variant in 0..<7 {
                let (client, fake, _) = try await setup()
                let transport = RelayTransport(socket: await fake.socket, route: client.route, droppedFrames: 0,
                    records: RelayRecords(established: Data(repeating: 1, count: 64)))
                let route = client.route
                let packet = Data([1, 2, 3])
                let frame = RelayCiphertext(account_id: variant == 1 ? "wrong" : route.account, room_id: route.room,
                    sender_device_id: variant == 2 ? route.device : "desktop", ciphertext: RelayRecords.encode(5, epoch: Data(repeating: 1, count: 64), payload: variant == 3 ? Data(repeating: 1, count: 11_001) : packet).base64EncodedString())
                let message: WebSocketMessage
                switch variant {
                case 4: message = .binary(Data([1]))
                case 5: message = .text(String(repeating: " ", count: 16_385))
                case 6: message = .text("{}")
                default: message = .text(String(decoding: try ProtocolCodec.encode(frame), as: UTF8.self))
                }
                await fake.socket.configure(messages: [message])
                if variant == 0 {
                    let received = try await transport.receive(); XCTAssertEqual(received, packet)
                    try await transport.send(packet)
                    let sent = await fake.socket.sent
                    let wire = try ProtocolCodec.decode(RelayCiphertext.self, from: Data(sent.last!.utf8))
                    XCTAssertEqual(Data(base64Encoded: wire.ciphertext), RelayRecords.encode(5, epoch: Data(repeating: 1, count: 64), payload: packet))
                } else {
                    do { _ = try await transport.receive(); XCTFail("invalid relay frame \(variant)") } catch {}
                    let closed = await fake.socket.closed; XCTAssertTrue(closed)
                }
                await transport.close()
            }
        }
    }
    func testPingPongAndSilentKeepaliveTimeoutAndSendFailureClose() async throws {
        try await testDeadline(seconds: 20) { [self] in
            let (client, fake, _) = try await setup(); let transport = try await client.connect()
            try await transport.keepalive()
            let pings = await fake.socket.pings; XCTAssertEqual(pings, 1)
            await fake.socket.configure(silent: true)
            do { try await transport.keepalive(timeout: .milliseconds(10)); XCTFail("silent peer retained") } catch {}
            let closed = await fake.socket.closed; XCTAssertTrue(closed)
            let (second, server, _) = try await setup(); let other = try await second.connect()
            await server.socket.configure(failSend: true)
            do { try await other.send(Data([1])); XCTFail() } catch {}
            let failedClosed = await server.socket.closed; XCTAssertTrue(failedClosed)
            do { try await other.send(Data([1])); XCTFail("failed send retried") } catch {}
        }
    }
    func testInvalidDroppedCountAndOriginRejected() async throws {
        try await testDeadline(seconds: 20) { [self] in
            let (client, fake, _) = try await setup(); await fake.configure(dropped: "-1")
            do { _ = try await client.connect(); XCTFail() } catch {}
            let closed = await fake.socket.closed; XCTAssertTrue(closed)
            for value in ["http://relay.invalid", "https://relay.invalid/path", "https://user@relay.invalid", "https://relay.invalid/?q=1", "https://relay.invalid/#fragment"] {
                XCTAssertThrowsError(try RelayClient(origin: URL(string: value)!, route: client.route, signingKey: .init(), http: fake, connector: fake))
            }
        }
    }
    func testFlatResponseRejectsDuplicatesSurrogatesUnsafeIntegersAndOpenFields() throws {
        for text in ["{\"a\":1,\"a\":1}", "{\"a\":1,\"\\u0061\":1}", "{\"a\":1.0}", "{\"a\":1e0}", "{\"a\":9007199254740992}", "{\"a\":1,}", "{\"a\":null}", "{\"a\":{}}", "{\"a\":\"\\ud800\"}", "{\"a\":1,\"extra\":1}", "{\"a\":1}\u{00a0}"] {
            XCTAssertThrowsError(try RelayJSON.flat(Data(text.utf8), fields: ["a"]), text)
        }
    }
}

extension NoiseRelayTests {
    func testClockBehindServerDoesNotRejectMemberChallenge() async throws {
        try await testDeadline(seconds: 20) { [self] in
            let (client, fake, _) = try await setup()
            await fake.setServerTime(3_600_001)
            let transport = try await client.connect()
            await transport.close()
        }
    }
    func testPermanentMemberRefusalStopsBackoff() async throws {
        try await testDeadline(seconds: 20) { [self] in
            let (client, fake, _) = try await setup()
            await fake.refuseMember()
            let sleeper = RecordingSleeper(cancelAfter: 2)
            let (noise, _) = try await noisePair(); let registry = PeerRegistry(store: InMemoryKeyStore())
            let peer = try await enrolled(noise, registry: registry)
            do { _ = try await client.reconnect(registry: registry, peer: peer, sleeper: sleeper); XCTFail("revoked member connected") }
            catch is CancellationError { XCTFail("permanent refusal retried until cancellation") }
            catch {}
            let delays = await sleeper.delays
            XCTAssertTrue(delays.isEmpty, "permanent refusal must surface immediately")
            try await registry.require(peer) // HTTP refusal cannot revoke endpoint trust.
        }
    }
}

extension NoiseRelayTests {
    func testLostJoinResponseRecoversUsingRetainedMemberKey() async throws {
        try await testDeadline(seconds: 20) { [self] in
            let (client, _, _) = try await setup(loseResponse: true)
            let transport = try await client.connect()
            await transport.close()
        }
    }
}

extension NoiseRelayTests {
    func testProxyProofsBindCanonicalQueryAndExactBodyAndRejectOtherRoutes() async throws {
        try await testDeadline(seconds: 20) { [self] in
            let (client, server, _) = try await setup()
            let prefix = "wss://relay.invalid/v1/accounts/synthetic/rooms/" + String(repeating: "a", count: 32)
            let query = "?model_id=scribe_v2_realtime&audio_format=pcm_16000&commit_strategy=manual&keyterms=O%27Brien"
            let canonical = Data(query.utf8)
            XCTAssertEqual(Data(SHA256.hash(data: canonical)).base64EncodedString(), "Pf3oZrkv9GShKRbUCijPMlzWfZn9dv4xDIoM51ydJvc=")
            var speech = URLRequest(url: URL(string: prefix + "/proxy/elevenlabs" + query.replacingOccurrences(of: "%27", with: "'"))!)
            speech.httpMethod = "GET"
            let signed = try await client.authorize(speech, provider: "elevenlabs")
            try await server.verifyProxy(signed, operation: "proxy/elevenlabs", bytes: canonical)
            var body = URLRequest(url: try client.proxyURL(provider: "anthropic")); body.httpMethod = "POST"
            body.httpBody = Data("{ \"synthetic\": \"body / bytes\" }".utf8)
            body.setValue("never-forward", forHTTPHeaderField: "x-api-key")
            let messages = try await client.authorize(body, provider: "anthropic")
            XCTAssertEqual(messages.httpBody, body.httpBody); XCTAssertNil(messages.value(forHTTPHeaderField: "x-api-key"))
            try await server.verifyProxy(messages, operation: "proxy/anthropic", bytes: body.httpBody!)
            for wrong in [prefix + "/proxy/assemblyai" + query, "wss://other.invalid/proxy/elevenlabs" + query] {
                do { _ = try await client.authorize(URLRequest(url: URL(string: wrong)!), provider: "elevenlabs"); XCTFail("wrong route signed") } catch {}
            }
            await server.configure(fault: 1)
            do { _ = try await client.authorize(speech, provider: "elevenlabs"); XCTFail("wrong challenge context signed") } catch {}
        }
    }
    func testCanonicalQueryVectorsAndCompleteCodeParsing() async throws {
        try await testDeadline(seconds: 20) { [self] in
            let pairs = [URLQueryItem(name: "term", value: "C++ ~ é"), URLQueryItem(name: "term", value: "O'Brien")]
            XCTAssertEqual(RelayQuery.encode(pairs), "term=C%2B%2B+%7E+%C3%A9&term=O%27Brien")
            let url = URL(string: "https://example.invalid/?a=hello%20world&&a=O%27Brien&z&bad=%25zz")!
            XCTAssertEqual(String(decoding: try RelayQuery.canonical(url), as: UTF8.self), "?a=hello+world&a=O%27Brien&z=&bad=%25zz")
            let (_, _, invitation) = try await setup()
            let qr = try ProtocolCodec.encode(invitation.payload)
            for code in [String(decoding: qr, as: UTF8.self), qr.base64EncodedString()] {
                XCTAssertEqual(try PairingInvitation(code: code, expectedAccount: "synthetic", clock: TestClock(now: 1)).payload, invitation.payload)
            }
            XCTAssertThrowsError(try PairingInvitation(code: "123456", expectedAccount: "synthetic", clock: TestClock(now: 1)))
        }
    }
}
