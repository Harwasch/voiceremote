import Foundation
import VoiceRemoteProtocol

public protocol PairingClock: Sendable { func nowMilliseconds() throws -> Int64 }
public struct SystemPairingClock: PairingClock {
    public init() {}
    public func nowMilliseconds() throws -> Int64 {
        let value = Date().timeIntervalSince1970 * 1000
        guard value.isFinite, value >= 0, value <= 9_007_199_254_740_991 else { throw PairingError.expiredQR }
        return Int64(value)
    }
}

/// QR parsing always uses the generated validating codec. No enrollment secret is
/// persisted here; the desktop owns one-use consumption and its monotonic deadline.
public struct PairingInvitation: Sendable {
    public let payload: PairingPayload
    public let desktopKey: Data
    let token: Data
    public init(qr: Data, expectedAccount: String, clock: any PairingClock) throws {
        let payload = try ProtocolCodec.decode(PairingPayload.self, from: qr)
        guard payload.account_id == expectedAccount else { throw PairingError.wrongAccount }
        guard let key = Data(base64Encoded: payload.desktop_public_key), key.count == 32,
              key.base64EncodedString() == payload.desktop_public_key,
              let token = Data(base64Encoded: payload.one_use_token), token.count == 32,
              token.base64EncodedString() == payload.one_use_token else { throw PairingError.invalidQR }
        self.payload = payload; desktopKey = key; self.token = token
        try validate(clock: clock)
    }
    public func validate(clock: any PairingClock) throws {
        let now = try clock.nowMilliseconds()
        guard now >= 0, now < payload.expires_at, payload.expires_at - now <= 120_000 else { throw PairingError.expiredQR }
    }
    /// desktop pairing.rs: domain + u32-BE UTF-8 lengths/strings + key + u64-BE expiry.
    public var prologue: Data {
        var bytes = Data("voiceremote/pair/v1\0".utf8)
        for value in [payload.account_id, payload.relay_room_id] {
            let utf8 = Data(value.utf8); let length = UInt32(utf8.count)
            bytes += Data((0..<4).reversed().map { UInt8(truncatingIfNeeded: length >> ($0 * 8)) })
            bytes += utf8
        }
        bytes += desktopKey
        let expiry = UInt64(payload.expires_at)
        bytes += Data((0..<8).reversed().map { UInt8(truncatingIfNeeded: expiry >> ($0 * 8)) })
        return bytes
    }
}

/// The desktop's 256-word dictionary is the Cartesian product of these lists.
/// Four bytes of the complete Noise handshake hash select four words (32 bits).
public enum VerificationPhrase {
    public static func derive(handshakeHash: Data) throws -> String {
        guard handshakeHash.count == 32 else { throw PairingError.invalidMessage }
        let prefixes = ["amber", "birch", "cedar", "dawn", "elm", "fern", "gold", "hazel", "iris", "jade", "kelp", "lunar", "maple", "north", "oak", "pine"]
        let suffixes = ["ant", "bird", "cat", "deer", "elk", "fox", "goat", "hare", "ibis", "jay", "kite", "lynx", "moth", "newt", "owl", "puma"]
        return handshakeHash.prefix(4).map { prefixes[Int($0 >> 4)] + suffixes[Int($0 & 15)] }.joined(separator: " ")
    }
}
