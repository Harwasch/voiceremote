import Foundation
import XCTest
import VoiceRemoteProtocol
@testable import Pairing

final class PhoneConnectionTests: XCTestCase, @unchecked Sendable {
    func testProductionConnectionCorrelatesReadyPositiveFailureAndQueryWithoutReplay() async throws {
        let (a, b) = try await noisePair(), (tx, rx) = InMemoryPairingTransport.pair()
        let phone = try await application(a, registry: PeerRegistry(store: InMemoryKeyStore()))
        let desktop = try await application(b, registry: PeerRegistry(store: InMemoryKeyStore()), local: "desktop")
        let connection = PhoneConnection(session: phone, transport: tx)
        let reader = Task { do { while !Task.isCancelled { _ = try await connection.receive() } } catch {} }
        let server = Task {
            guard case .targetPrepare(let prepare) = try await desktop.receive(transport: rx) else { throw PairingError.invalidMessage }
            // An unrelated reply must not release the phone's preparation wait.
            try await desktop.send(.targetReady(TargetReady(account_id: "synthetic", request_id: "unrelated", target_device_id: "desktop", ready: true)), transport: rx)
            try await desktop.send(.targetReady(TargetReady(account_id: "synthetic", request_id: prepare.request_id, target_device_id: "desktop", ready: true)), transport: rx)
            for expected in ["success", "failure"] {
                guard case .dictationText(let text) = try await desktop.receive(transport: rx), text.segment_id == expected,
                      text.preparation_id == prepare.request_id else { throw PairingError.invalidMessage }
                try await desktop.send(.dictationOutcome(DictationOutcome(account_id: "synthetic", segment_id: expected,
                    target_device_id: "desktop", outcome: expected == "success" ? .inserted : .unavailable)), transport: rx)
            }
            guard case .dictationQuery(let query) = try await desktop.receive(transport: rx), query.segment_id == "success" else { throw PairingError.invalidMessage }
            try await desktop.send(.dictationOutcome(DictationOutcome(account_id: "synthetic", segment_id: query.segment_id,
                target_device_id: "desktop", outcome: .inserted)), transport: rx)
        }
        try await connection.prepare()
        func text(_ id: String) -> DictationText {
            DictationText(account_id: "synthetic", segment_id: id, revision: 0, state: .committed, target_device_id: "desktop", text: "Synthetic.")
        }
        let success = try await connection.insert(text("success"))
        let failure = try await connection.insert(text("failure"))
        let query = try await connection.reconcile(segmentID: "success")
        XCTAssertEqual(success.outcome, .inserted); XCTAssertEqual(failure.outcome, .unavailable); XCTAssertEqual(query.outcome, .inserted)
        try await server.value; reader.cancel(); await connection.close()
    }
    func testStateHeartbeatKeepsActualMicStateDistinctAndUsesProductionFraming() async throws {
        let (a, b) = try await noisePair(), (tx, rx) = InMemoryPairingTransport.pair()
        let phone = try await application(a, registry: PeerRegistry(store: InMemoryKeyStore()))
        let desktop = try await application(b, registry: PeerRegistry(store: InMemoryKeyStore()), local: "desktop")
        let connection = PhoneConnection(session: phone, transport: tx)
        try await connection.publishState(phoneID: "phone", mode: .dictation, capture: .continuous, listening: false)
        try await connection.publishState(phoneID: "phone", mode: .dictation, capture: .continuous, listening: false)
        try await connection.publishState(phoneID: "phone", mode: .dictation, capture: .continuous, listening: false, heartbeat: true)
        for _ in 0..<2 {
            guard case .modeState(let mode) = try await desktop.receive(transport: rx), mode.mode == .dictation,
                  case .captureStateReport(let state) = try await desktop.receive(transport: rx) else { return XCTFail("missing phone state") }
            XCTAssertEqual(state.capture_state, .continuous); XCTAssertEqual(state.listening, false)
        }
        // Four frames prove change suppression plus the forced heartbeat. A
        // subsequent true observation remains a separate fifth/sixth frame pair.
        try await connection.publishState(phoneID: "phone", mode: .dictation, capture: .continuous, listening: true)
        _ = try await desktop.receive(transport: rx)
        guard case .captureStateReport(let state) = try await desktop.receive(transport: rx) else { return XCTFail("missing actual listening update") }
        XCTAssertEqual(state.listening, true)
        await connection.close()
    }
    func testLANTriesEveryCandidateAfterImpostorAndDiscoveryFailure() async throws {
        let candidates = AsyncThrowingStream<Int, Error> { output in
            output.yield(1); output.yield(2); output.finish(throwing: PairingError.noMessage)
        }
        let value = try await PreferredConnection.tryLAN(candidates: candidates) { candidate in
            if candidate == 1 { throw PairingError.keyMismatch }
            return candidate
        }
        XCTAssertEqual(value, 2)
    }
    func testDiscoveryCancellationWithoutTaskCancellationStillFallsBack() async throws {
        let value: Int = try await PreferredConnection.connect(lan: { throw CancellationError() }, relay: { 2 })
        XCTAssertEqual(value, 2)
    }
    func testPreferredConnectionTriesLANFirstAndCancellationNeverFallsBack() async throws {
        let preferred = try await PreferredConnection.connect(lan: { 1 }, relay: { XCTFail("relay used while LAN healthy"); return 2 })
        XCTAssertEqual(preferred, 1)
        let fallback = try await PreferredConnection.connect(lan: { throw PairingError.noMessage }, relay: { 2 })
        XCTAssertEqual(fallback, 2)
        do {
            let cancelled = Task<Int, Error> {
                try await PreferredConnection.connect(lan: { try await Task.sleep(for: .seconds(5)); return 1 }, relay: { XCTFail("cancelled probe fell back"); return 2 })
            }
            cancelled.cancel()
            _ = try await cancelled.value
            XCTFail("cancellation accepted")
        } catch is CancellationError {}
    }
}
