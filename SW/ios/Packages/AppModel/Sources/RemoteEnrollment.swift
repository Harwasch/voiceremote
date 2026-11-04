import Foundation
import Pairing

/// A phone-local pin after explicit OS/remote Numeric Comparison confirmation.
/// CoreBluetooth cannot attest the method: firmware must enforce SC + MITM on
/// every protected attribute. Names/capabilities alone never establish this pin.
public actor RemoteEnrollmentStore {
    private struct Pin: Codable { let peripheralID: UUID; let identity: String }
    private let store: any KeyStore
    public init(store: any KeyStore) { self.store = store }
    private func name(_ id: UUID) -> String { "remote-pin-" + id.uuidString }
    public func identity(peripheralID: UUID, protectedAccess: Bool) throws -> String? {
        guard protectedAccess, let data = try store.get(name(peripheralID)) else { return nil }
        let pin = try JSONDecoder().decode(Pin.self, from: data)
        guard pin.peripheralID == peripheralID else { throw RemoteContractError.notReady }
        return pin.identity
    }
    public func confirm(peripheralID: UUID, protectedAccess: Bool, systemCode: String, remoteCode: String) throws -> String {
        guard protectedAccess, systemCode.utf8.count == 6,
              systemCode.utf8.allSatisfy({ (48...57).contains($0) }), systemCode == remoteCode else { throw RemoteContractError.notReady }
        if let existing = try identity(peripheralID: peripheralID, protectedAccess: true) { return existing }
        let pin = Pin(peripheralID: peripheralID, identity: UUID().uuidString)
        try store.put(name(peripheralID), value: JSONEncoder().encode(pin))
        return pin.identity
    }
    public func revoke(peripheralID: UUID) throws { try store.delete(name(peripheralID)) }
}
