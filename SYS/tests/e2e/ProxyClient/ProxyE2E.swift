import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Crypto
import Pairing
import Stt
import Brain

/// Only invented text/PCM, ephemeral identities and a local real Worker. The
/// provisioning marker and vendor credentials never enter this phone process.
@main struct ProxyE2E {
    static func main() async throws {
        guard CommandLine.arguments.count == 2, let line = readLine(),
              let origin = URL(string: CommandLine.arguments[1]) else { throw PairingError.invalidState }
        let invitation = try PairingInvitation(code: line, expectedAccount: "proxy-e2e", clock: SystemPairingClock())
        let client = try RelayClient(origin: origin,
            route: RelayRoute(account: "proxy-e2e", room: invitation.payload.relay_room_id, device: "phone"),
            signingKey: .init(), http: URLSessionRelayHTTP(), connector: LoopbackWebSocketConnector(), allowLoopback: true)
        try await client.redeem(invitation)
        for (vendor, provider) in [(CloudEngine.Vendor.elevenLabs, "elevenlabs"), (.assemblyAI, "assemblyai")] {
            var parts = URLComponents(url: try client.proxyURL(provider: provider), resolvingAgainstBaseURL: false)!
            parts.scheme = "ws"
            let factory = URLSessionSocketFactory(authorizer: client, provider: provider, open: { request in
                let upgrade = try await LoopbackWebSocketConnector().connect(.init(url: request.url!, method: "GET", headers: request.allHTTPHeaderFields ?? [:]))
                guard let socket = upgrade.socket as? LoopbackWebSocket else { throw SttFailure.transport }
                return ProxySocket(socket: socket)
            })
            let engine = CloudEngine(vendor: vendor, settings: try ProxySettings(url: parts.url!, allowInsecureLoopback: true), sockets: factory, timeout: .seconds(5))
            let source = ScriptedCaptureSource([try AudioFrame(samples: [0, 0], timestamp: 0)])
            var finals: [String] = []
            for await event in engine.transcribe(source.frames(), vocabulary: Vocabulary(userID: "synthetic", terms: ["O'Brien", "C++ ~ é"])) {
                if case .failure = event { throw SttFailure.transport }
                if case .final(let text) = event { finals.append(text) }
            }
            guard finals == ["Synthetic proxy fixture."] else { throw SttFailure.invalidResponse }
        }
        // Claude configuration disallows insecure URLs; rewrite only the test
        // transport's signed URL to local HTTP after the real final body is built.
        let https = URL(string: try client.proxyURL(provider: "anthropic").absoluteString.replacingOccurrences(of: "http://", with: "https://"))!
        let brain = ClaudeBrain(configuration: try ClaudeBrainConfiguration(proxyURL: https, model: "synthetic-model", apiVersion: "2026-10-21"),
            transport: LoopbackBrainTransport(client: client))
        let response = try await brain.propose(BrainRequest(accountID: "proxy-e2e", transcript: "Invented fixture.", context: "Synthetic context"))
        guard response.proposals.isEmpty else { throw BrainError.invalidResponse }
        print("PASS proxy: Swift CloudEngine both vendors + ClaudeBrain; real relay accepts canonical query/body signing bytes")
    }
}
private struct LoopbackBrainTransport: BrainHTTPTransport {
    let client: RelayClient
    func send(_ request: URLRequest) async throws -> BrainHTTPResponse {
        var loopback = request
        var url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        url.scheme = "http"; loopback.url = url.url
        return try await RelayBrainTransport(authorizer: client).send(loopback)
    }
}
