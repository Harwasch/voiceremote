import Foundation
import Crypto

/// Relay queues outlive a Noise session. A responder's per-socket random nonce
/// challenges the initiator before XX, binding *both* socket generations. Old
/// hello/ack/XX/application records can never select a fresh generation.
/// This is opaque RelayCiphertext content; it changes no relay schema or Noise bytes.
struct RelayRecords: Sendable {
    static let magic = Data("VRR1".utf8)
    let local: Data
    var epoch: Data?
    var step = 0
    var retained = false
    init() {
        local = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }
    init(established epoch: Data) { local = Data(epoch.suffix(32)); self.epoch = epoch; step = 3 }
    static func encode(_ kind: UInt8, epoch: Data, payload: Data = Data()) -> Data {
        magic + Data([kind]) + epoch + payload
    }
    static func decode(_ data: Data) -> (UInt8, Data)? {
        guard data.count >= 5, data.prefix(4) == magic else { return nil }
        return (data[4], Data(data.dropFirst(5)))
    }
}
