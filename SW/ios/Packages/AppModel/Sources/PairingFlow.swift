import Foundation
#if canImport(Darwin)
import Observation
#endif
import Pairing
import VoiceRemoteProtocol

/// Apple transport/Keychain adapters own discovery, code lookup and persistence.
@MainActor public protocol ComputerPairing {
    func begin(_ invitationOrCode: String, role: DeviceInfoRole) async throws -> String
    func begin(_ invitationOrCode: String, role: DeviceInfoRole, allowAgentCommands: Bool) async throws -> String
    func confirm(_ phrase: String) async throws -> DeviceInfo
    func cancel() async
}
public extension ComputerPairing {
    func begin(_ invitationOrCode: String, role: DeviceInfoRole, allowAgentCommands: Bool) async throws -> String {
        guard !allowAgentCommands else { throw PairingError.invalidState }
        return try await begin(invitationOrCode, role: role)
    }
}
#if canImport(Darwin)
@Observable
#endif
@MainActor public final class PairingFlow {
    public private(set) var phrase: String?
    public private(set) var busy = false
    public private(set) var error: String?
    public var code = ""
    public var role: DeviceInfoRole = .text_receiver
    public var allowAgentCommands = false
    private let backend: any ComputerPairing
    private var epoch = UUID()
    public init(backend: any ComputerPairing) { self.backend = backend }
    public func begin(_ value: String? = nil) async {
        guard !busy else { return }
        let token = UUID(); epoch = token; busy = true; error = nil; phrase = nil
        do {
            let result = try await backend.begin(value ?? code, role: role, allowAgentCommands: allowAgentCommands)
            guard epoch == token else { return }; phrase = result
        } catch { if epoch == token { self.error = "Unable to pair. Check the code, network and expiry." } }
        if epoch == token { busy = false }
    }
    public func confirm() async -> DeviceInfo? {
        guard let phrase, !busy else { return nil }
        busy = true; let token = epoch
        defer { if epoch == token { busy = false } }
        do {
            let device = try await backend.confirm(phrase)
            guard epoch == token else { return nil }; self.phrase = nil; code = ""; return device
        } catch {
            guard epoch == token else { return nil }
            self.error = "Both screens must confirm the same phrase. Pairing was not completed."; return nil
        }
    }
    public func cancel() async { epoch = UUID(); phrase = nil; error = nil; busy = false; code = ""; await backend.cancel() }
}
