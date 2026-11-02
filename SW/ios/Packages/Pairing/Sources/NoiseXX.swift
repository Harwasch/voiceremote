import Foundation
import Crypto

public enum PairingError: Error, Equatable {
    case invalidState, invalidMessage, messageTooLarge, nonceExhausted
    case invalidQR, expiredQR, wrongAccount, keyMismatch, confirmationRequired
    case closedTransport, noMessage
}

private struct CipherState {
    var key: Data?
    var nonce: UInt64 = 0
    mutating func initialize(_ key: Data) { self.key = key; nonce = 0 }
    private func iv() throws -> ChaChaPoly.Nonce {
        guard nonce < UInt64.max else { throw PairingError.nonceExhausted }
        return try ChaChaPoly.Nonce(data: Data(repeating: 0, count: 4) + Data((0..<8).map { UInt8(truncatingIfNeeded: nonce >> ($0 * 8)) }))
    }
    mutating func encrypt(_ plain: Data, ad: Data) throws -> Data {
        guard let key else { return plain }
        let box = try ChaChaPoly.seal(plain, using: SymmetricKey(data: key), nonce: iv(), authenticating: ad)
        nonce += 1
        var output = Data()
        output.append(box.ciphertext); output.append(box.tag)
        return output
    }
    mutating func decrypt(_ encrypted: Data, ad: Data) throws -> Data {
        guard let key else { return encrypted }
        guard encrypted.count >= 16 else { throw PairingError.invalidMessage }
        let box = try ChaChaPoly.SealedBox(nonce: iv(), ciphertext: encrypted.dropLast(16), tag: encrypted.suffix(16))
        let plain = try ChaChaPoly.open(box, using: SymmetricKey(data: key), authenticating: ad)
        nonce += 1 // Failed authentication must not advance the nonce.
        return plain
    }
}

private struct SymmetricState {
    var hash: Data
    var chainingKey: Data
    var cipher = CipherState()
    init(prologue: Data) {
        let name = Data("Noise_XX_25519_ChaChaPoly_BLAKE2s".utf8)
        hash = name.count <= 32 ? name + Data(repeating: 0, count: 32 - name.count) : BLAKE2s.hash(name)
        chainingKey = hash
        mixHash(prologue)
    }
    mutating func mixHash(_ bytes: Data) { hash = BLAKE2s.hash(hash + bytes) }
    mutating func mixKey(_ bytes: Data) {
        let (ck, key) = BLAKE2s.hkdf(chainingKey: chainingKey, input: bytes)
        chainingKey = ck; cipher.initialize(key)
    }
    mutating func encryptAndHash(_ plain: Data) throws -> Data {
        let encrypted = try cipher.encrypt(plain, ad: hash)
        mixHash(encrypted)
        return encrypted
    }
    mutating func decryptAndHash(_ encrypted: Data) throws -> Data {
        let plain = try cipher.decrypt(encrypted, ad: hash)
        mixHash(encrypted)
        return plain
    }
}

/// Ordered Noise transport. Actor isolation prevents copying/reusing a nonce stream.
public actor NoiseSession {
    private var sending: CipherState
    private var receiving: CipherState
    private var closed = false
    fileprivate init(send: Data, receive: Data) {
        sending = CipherState(key: send); receiving = CipherState(key: receive)
    }
    public func encrypt(_ plain: Data) throws -> Data {
        guard !closed else { throw PairingError.invalidState }
        guard plain.count <= 65_519 else { throw PairingError.messageTooLarge }
        return try sending.encrypt(plain, ad: Data())
    }
    public func decrypt(_ encrypted: Data) throws -> Data {
        guard !closed else { throw PairingError.invalidState }
        guard encrypted.count <= 65_535 else { throw PairingError.messageTooLarge }
        return try receiving.decrypt(encrypted, ad: Data())
    }
    public func close() { closed = true; sending = CipherState(); receiving = CipherState() }
}

/// Noise revision 34, XX: -> e; <- e, ee, s, es; -> s, se.
/// This primitive does not enroll a peer. Pin the QR static key and confirm both
/// screens before using split keys (see PairingConfirmation).
public actor NoiseXX {
    public enum Role: Sendable { case initiator, responder }
    private let role: Role
    private var localStatic: Curve25519.KeyAgreement.PrivateKey?
    private var ephemeral: Curve25519.KeyAgreement.PrivateKey?
    private var remoteEphemeral: Data?
    private var remoteStatic: Data?
    private var symmetric: SymmetricState
    private var step = 0
    private var failed = false
    private var splitTaken = false

    public init(role: Role, staticKey: Curve25519.KeyAgreement.PrivateKey, prologue: Data = Data()) {
        self.role = role; localStatic = staticKey
        ephemeral = Curve25519.KeyAgreement.PrivateKey()
        symmetric = SymmetricState(prologue: prologue)
    }
    // Deterministic ephemeral injection is internal, for published test vectors only.
    init(role: Role, staticKey: Curve25519.KeyAgreement.PrivateKey, ephemeralKey: Curve25519.KeyAgreement.PrivateKey, prologue: Data) {
        self.role = role; localStatic = staticKey; ephemeral = ephemeralKey
        symmetric = SymmetricState(prologue: prologue)
    }
    private func dh(_ own: Curve25519.KeyAgreement.PrivateKey?, _ remote: Data?) throws -> Data {
        guard let own, let remote else { throw PairingError.invalidState }
        let shared = try own.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: remote))
        let bytes = shared.withUnsafeBytes { Data($0) }
        // swift-crypto's X25519 backend can return all-zero shared secrets for
        // low-order input. Noise §12.1 permits rejecting these; never mix one.
        guard bytes.reduce(UInt8(0), { $0 | $1 }) != 0 else { throw PairingError.invalidMessage }
        return bytes
    }
    private func fail() { failed = true; ephemeral = nil; localStatic = nil; symmetric.cipher = CipherState(); symmetric.chainingKey = Data() }
    public func writeMessage(payload: Data = Data()) throws -> Data {
        guard !failed, step < 3, (role == .initiator ? step != 1 : step == 1) else { throw PairingError.invalidState }
        let overhead = step == 0 ? 32 : (step == 1 ? 96 : 64)
        guard payload.count <= 65_535 - overhead else { throw PairingError.messageTooLarge }
        do {
            var message = Data()
            if step < 2 {
                guard let ephemeral else { throw PairingError.invalidState }
                message = ephemeral.publicKey.rawRepresentation
                symmetric.mixHash(message)
            }
            if step == 1 {
                symmetric.mixKey(try dh(ephemeral, remoteEphemeral)) // ee
                guard let localStatic else { throw PairingError.invalidState }
                message += try symmetric.encryptAndHash(localStatic.publicKey.rawRepresentation)
                symmetric.mixKey(try dh(localStatic, remoteEphemeral)) // es
            } else if step == 2 {
                guard let localStatic else { throw PairingError.invalidState }
                message += try symmetric.encryptAndHash(localStatic.publicKey.rawRepresentation)
                symmetric.mixKey(try dh(localStatic, remoteEphemeral)) // se
            }
            message += try symmetric.encryptAndHash(payload)
            step += 1
            return message
        } catch { fail(); throw error }
    }
    public func readMessage(_ message: Data) throws -> Data {
        guard !failed, step < 3, (role == .initiator ? step == 1 : step != 1) else { throw PairingError.invalidState }
        guard message.count <= 65_535 else { fail(); throw PairingError.messageTooLarge }
        do {
            var remaining = Data(message)
            func take(_ count: Int) throws -> Data {
                guard remaining.count >= count else { throw PairingError.invalidMessage }
                let part = Data(remaining.prefix(count)); remaining = Data(remaining.dropFirst(count)); return part
            }
            if step < 2 {
                remoteEphemeral = try take(32)
                symmetric.mixHash(remoteEphemeral!)
            }
            if step == 1 {
                symmetric.mixKey(try dh(ephemeral, remoteEphemeral)) // ee
                remoteStatic = try symmetric.decryptAndHash(take(48))
                symmetric.mixKey(try dh(ephemeral, remoteStatic)) // es
            } else if step == 2 {
                remoteStatic = try symmetric.decryptAndHash(take(48))
                symmetric.mixKey(try dh(ephemeral, remoteStatic)) // se
            }
            let payload = try symmetric.decryptAndHash(remaining)
            step += 1
            return payload
        } catch { fail(); throw error }
    }
    public func handshakeHash() throws -> Data {
        guard step == 3, !failed else { throw PairingError.invalidState }
        return symmetric.hash
    }
    public func remoteStaticKey() throws -> Data {
        guard step >= 2, !failed, let remoteStatic else { throw PairingError.invalidState }
        return remoteStatic
    }
    public func split() throws -> NoiseSession {
        guard step == 3, !failed, !splitTaken else { throw PairingError.invalidState }
        let (first, second) = BLAKE2s.hkdf(chainingKey: symmetric.chainingKey, input: Data())
        splitTaken = true; ephemeral = nil; localStatic = nil
        symmetric.chainingKey = Data(); symmetric.cipher = CipherState()
        return role == .initiator ? NoiseSession(send: first, receive: second) : NoiseSession(send: second, receive: first)
    }
}
