import Foundation
import Crypto

/// Copy/share identity is independent of the wire segment ID (offline IDs are
/// namespaced counters). Hashing never changes or truncates the copied text.
public enum HistoryTextIdentity {
    public static func copyID(_ segmentID: String) -> UUID {
        if let id = UUID(uuidString: segmentID) { return id }
        let bytes = Array(SHA256.hash(data: Data(segmentID.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
