import Foundation
import Observation
@preconcurrency import Network
import Crypto
import Pairing
import Core
import AppModel
import VoiceRemoteProtocol

/// Four-byte BE length framing matches desktop LanTransport. No IP entry.
private final class LANTransport: PairingTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let lock = NSLock()
    private var closed = false
    init(endpoint: NWEndpoint) {
        connection = NWConnection(to: endpoint, using: .tcp)
        connection.start(queue: DispatchQueue(label: "VoiceRemote.LAN"))
    }
    func send(_ frame: Data) async throws {
        guard !frame.isEmpty, frame.count <= 65535 else { throw PairingError.messageTooLarge }
        let count = UInt32(frame.count)
        let header = Data((0..<4).reversed().map { UInt8(truncatingIfNeeded: count >> ($0 * 8)) })
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    guard !closed else { continuation.resume(throwing: PairingError.closedTransport); return }
                    connection.send(content: header + frame, completion: .contentProcessed { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    })
                }
            }
        } onCancel: { self.connection.cancel() }
    }
    private func read(_ count: Int) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, data.count == count { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: PairingError.closedTransport) }
                }
            }
        } onCancel: { self.connection.cancel() }
    }
    func receive() async throws -> Data {
        let header = try await read(4)
        let count = header.reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= 65535 else { throw PairingError.messageTooLarge }
        return try await read(count)
    }
    func close() async { lock.withLock { closed = true; connection.cancel() } }
}

/// The Pairing worker can replace only discovery/code resolution with its extended
/// transport. Noise, phrase confirmation and enrollment stay in the merged package.
@MainActor @Observable final class ComputerLink: ComputerPairing, DeviceRevocationHandler, DictationTarget {
    let accountID: String
    let phoneID: String
    weak var runtime: AppRuntime?
    private var confirmation: PairingConfirmation?
    private var pendingTransport: (any PairingTransport)?
    private struct ConnectedPeer {
        let device: DeviceInfo
        let publicKey: Data
        let roomID: String
        let session: NoiseSession
    }
    private var peers: [String: (ConnectedPeer, any PairingTransport)] = [:]
    private let store: PeerStore
    private var connecting: [String: Task<Void, Error>] = [:]
    private var revoking = Set<String>()
    private var pairingEpoch = UUID()
    private(set) var notice: String?
    var enrolledDevices: [DeviceInfo] { store.active.map(\.device) }
    private var role: DeviceInfoRole = .text_receiver
    private var readers: [String: Task<Void, Never>] = [:]
    init(accountID: String, phoneID: String, store: PeerStore) {
        self.accountID = accountID; self.phoneID = phoneID; self.store = store
    }
    private func keyName(_ deviceID: String) -> String {
        "peer:" + (try! JSONEncoder().encode([accountID, deviceID])).base64EncodedString()
    }
    func restore(registry: DeviceRegistry) async throws {
        let missing = try await store.restore(registry: registry, keyAvailable: { id in
            guard let key = try SecureStore.load(keyName(id)) else { return false }
            return key.count == 32
        })
        if !missing.isEmpty { notice = "Stored computer credentials are unavailable. Pair those computers again." }
        if store.records.contains(where: \.notificationPending) {
            notice = "A removed computer could not be notified. Remove this phone on that computer as well."
        }
    }
    func begin(_ invitationOrCode: String, role: DeviceInfoRole) async throws -> String {
        await cancel(); self.role = role
        let epoch = pairingEpoch
        // Full QR text is an offline code fallback. A short code requires the
        // coordinator's authenticated lookup service; never guess a lookup URL.
        let invitation = try PairingInvitation(qr: Data(invitationOrCode.utf8), expectedAccount: accountID, clock: SystemPairingClock())
        let endpoint = try await discover(room: invitation.payload.relay_room_id)
        guard epoch == pairingEpoch else { throw CancellationError() }
        let transport = LANTransport(endpoint: endpoint); pendingTransport = transport
        let keyData = try SecureStore.loadOrCreateKey("noise-static")
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keyData)
        let confirmation = try await PairingConnection.initiate(invitation: invitation, staticKey: key,
            clock: SystemPairingClock(), transport: transport)
        guard epoch == pairingEpoch else { await confirmation.abort(transport: transport); throw CancellationError() }
        self.confirmation = confirmation
        return await confirmation.phrase
    }
    func confirm(_ phrase: String) async throws -> DeviceInfo {
        guard let confirmation, let transport = pendingTransport, let runtime else { throw PairingError.invalidState }
        let phone = DeviceInfo(account_id: accountID, device_id: phoneID, display_name: "iPhone", platform: .ios,
            role: .capture, capabilities: [])
        try await confirmation.confirmLocal(displayedPhrase: phrase, device: phone, transport: transport)
        try await confirmation.receiveConfirmation(transport: transport)
        let peer = try await confirmation.finish()
        // Do not expand peer-declared role/capabilities. Role selection can narrow.
        let capabilities = peer.device.capabilities.filter { capability in
            role == .both || (role == .text_receiver ? capability == .receive_text : capability != .receive_text)
        }
        let device = DeviceInfo(account_id: accountID, device_id: peer.device.device_id,
            display_name: peer.device.display_name, platform: peer.device.platform, role: role, capabilities: capabilities)
        guard self.confirmation === confirmation, !revoking.contains(device.device_id),
              !store.active.contains(where: { $0.device.device_id == device.device_id }) else { throw PairingError.invalidState }
        // Both confirmations already succeeded. Persist keys separately from metadata.
        try SecureStore.save(peer.publicKey, key: keyName(device.device_id))
        try store.enroll(device, roomID: peer.roomID)
        do {
            do { try await runtime.registry.register(device) }
            catch CoreError.revokedDevice { try await runtime.registry.rePair(device) }
        } catch {
            try? store.markRevoked(deviceID: device.device_id, notificationPending: true)
            try? SecureStore.delete(keyName(device.device_id)); await peer.session.close(); await transport.close()
            throw error
        }
        let connected = ConnectedPeer(device: device, publicKey: peer.publicKey, roomID: peer.roomID, session: peer.session)
        install(connected, transport: transport)
        self.confirmation = nil; pendingTransport = nil
        return device
    }
    func cancel() async {
        pairingEpoch = UUID()
        if let confirmation, let pendingTransport { await confirmation.abort(transport: pendingTransport) }
        else { await pendingTransport?.close() }
        confirmation = nil; pendingTransport = nil
    }
    private func install(_ peer: ConnectedPeer, transport: any PairingTransport) {
        let id = peer.device.device_id
        peers[id] = (peer, transport)
        readers[id] = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let plain = try await peer.session.decrypt(transport.receive())
                    guard let self, peers[id]?.0.session === peer.session else { return }
                    if let focus = try? ProtocolCodec.decode(FocusReport.self, from: plain), focus.device_id == id {
                        try runtime?.model.updateFocus(focus)
                    }
                }
            } catch {
                guard let self, peers[id]?.0.session === peer.session else { return }
                peers.removeValue(forKey: id); notice = "Computer disconnected. It will reconnect on the next use."
            }
        }
    }
    private func ensureConnected(_ id: String) async throws {
        if peers[id] != nil { return }
        if let task = connecting[id] { return try await task.value }
        guard !revoking.contains(id), let record = store.active.first(where: { $0.device.device_id == id }),
              let publicKey = try SecureStore.load(keyName(id)), let localKey = try SecureStore.load("noise-static") else { throw PairingError.keyMismatch }
        let task = Task { [self] in
            let endpoint = try await discover(room: record.roomID)
            let transport = LANTransport(endpoint: endpoint)
            let session = try await PeerResume.initiate(accountID: accountID, roomID: record.roomID,
                localPrivateKey: localKey, expectedRemoteKey: publicKey, transport: transport)
            guard !Task.isCancelled, !revoking.contains(id), store.active.contains(where: { $0.device.device_id == id }) else {
                await session.close(); await transport.close(); throw CancellationError()
            }
            install(ConnectedPeer(device: record.device, publicKey: publicKey, roomID: record.roomID, session: session), transport: transport)
        }
        connecting[id] = task
        defer { connecting.removeValue(forKey: id) }
        try await task.value
    }
    func deleteKey(deviceID: String) async throws {
        revoking.insert(deviceID); defer { revoking.remove(deviceID) }
        connecting.removeValue(forKey: deviceID)?.cancel()
        // Remove delivery eligibility before awaits; keep transport solely for Revoke.
        let live = peers.removeValue(forKey: deviceID)
        do {
            try await PeerRevocation.perform(deviceID: deviceID, accountID: accountID, store: store,
                send: { data in
                    guard let (peer, transport) = live else { throw PairingError.closedTransport }
                    try await transport.send(peer.session.encrypt(data))
                }, erase: { try SecureStore.delete(keyName(deviceID)) }, close: {
                    readers.removeValue(forKey: deviceID)?.cancel()
                    if let (peer, transport) = live { await peer.session.close(); await transport.close() }
                }, now: Int64(Date().timeIntervalSince1970 * 1000))
        } catch PeerRevocationError.notification {
            // Remote notification failure is visible, but local key cleanup did
            // finish. Let Core complete revocation so a fresh re-pair is possible.
            notice = "Removed locally. Desktop notification could not be confirmed; remove this phone on the computer as well."
        } catch {
            notice = "Removed locally, but credential cleanup failed. Check the computer and retry removal."
            throw error
        }
    }
    func dropRoom(deviceID: String) async throws { /* LAN-only sessions have no joined relay room. */ }
    func showTarget(_ device: DeviceInfo) async throws {
        guard let runtime else { throw CoreError.unavailableTarget }
        if device.device_id != phoneID { try await ensureConnected(device.device_id) }
        runtime.preparedDestination = device.display_name
        try await runtime.remote.present(model: runtime.model, destination: device)
        await Task.yield()
        if device.device_id != phoneID {
            guard peers[device.device_id] != nil else { throw CoreError.unavailableTarget }
            // The phone label is set before capture starts. The merged wire contract
            // has no desktop tray display acknowledgement; real-device tray order
            // remains unverified and is tracked in the acceptance checklist.

        }
    }
    func insert(_ text: DictationText) async throws {
        if text.target_device_id == phoneID { try runtime?.publish(text); return }
        guard let (peer, transport) = peers[text.target_device_id] else { throw CoreError.unavailableTarget }
        let frame = try await peer.session.encrypt(ProtocolCodec.encode(text))
        guard peers[text.target_device_id]?.0.session === peer.session else { throw CoreError.revokedDevice }
        try await transport.send(frame)
    }
    private func discover(room: String) async throws -> NWEndpoint {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_voiceremote._tcp", domain: nil), using: .tcp)
        defer { browser.cancel() }
        return try await withThrowingTaskGroup(of: NWEndpoint.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        let once = DiscoveryResult(continuation)
                        browser.browseResultsChangedHandler = { @Sendable results, _ in
                            for result in results {
                                if case .bonjour(let record) = result.metadata,
                                   record.dictionary["room"] == room { once.complete(.success(result.endpoint)); return }
                            }
                        }
                        browser.stateUpdateHandler = { @Sendable state in
                            if case .failed(let error) = state { once.complete(.failure(error)) }
                            if case .cancelled = state { once.complete(.failure(CancellationError())) }
                        }
                        browser.start(queue: DispatchQueue(label: "VoiceRemote.Discovery"))
                    }
                } onCancel: { browser.cancel() }
            }
            group.addTask { try await Task.sleep(for: .seconds(10)); browser.cancel(); throw PairingError.noMessage }
            defer { group.cancelAll() }
            guard let endpoint = try await group.next() else { throw PairingError.noMessage }
            return endpoint
        }
    }
}
private final class DiscoveryResult: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NWEndpoint, Error>?
    init(_ continuation: CheckedContinuation<NWEndpoint, Error>) { self.continuation = continuation }
    func complete(_ result: Result<NWEndpoint, Error>) {
        lock.lock(); let value = continuation; continuation = nil; lock.unlock()
        value?.resume(with: result)
    }
}
