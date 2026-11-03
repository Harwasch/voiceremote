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

/// Relay enrollment and fresh XX resume use the same Pairing application boundary as LAN.
@MainActor @Observable final class ComputerLink: ComputerPairing, DeviceRevocationHandler, DictationAvailability {
    let accountID: String
    let phoneID: String
    weak var runtime: AppRuntime?
    private let peerRegistry = PeerRegistry(store: KeychainStore(service: "VoiceRemote.Pairing"))
    private var pendingRelay: RelayClient?
    private var pendingOrigin: String?
    private var reconnectors: [String: Task<Void, Never>] = [:]
    private var remoteRevocations = Set<String>()
    private(set) var connectedIDs = Set<String>()
    private(set) var suspendedIDs = Set<String>()
    private var confirmation: PairingConfirmation?
    private var pendingTransport: (any PairingTransport)?
    private struct ConnectedPeer {
        let device: DeviceInfo
        let publicKey: Data
        let roomID: String
        let session: ApplicationSession
        let epoch = UUID()
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
        for record in store.active {
            guard let key = try SecureStore.load(keyName(record.device.device_id)) else { continue }
            if try await peerRegistry.lookup(publicKey: key) == nil {
                try await peerRegistry.restoreConfirmed(device: record.device, publicKey: key, roomID: record.roomID)
            }
        }
        suspendedIDs = Set(store.active.filter { $0.suspended == true }.map { $0.device.device_id })
        if !missing.isEmpty { notice = "Stored computer credentials are unavailable. Pair those computers again." }
        if store.records.contains(where: \.notificationPending) {
            notice = "A removed computer could not be notified. Remove this phone on that computer as well."
        }
    }
    private func relayKeyName(room: String) -> String {
        "relay-signing:" + (try! JSONEncoder().encode([accountID, room])).base64EncodedString()
    }
    private func relay(room: String, origin: String, create: Bool = false) throws -> RelayClient {
        guard let url = URL(string: origin) else { throw PairingError.invalidQR }
        let name = relayKeyName(room: room)
        let bytes: Data
        if let retained = try SecureStore.load(name) { bytes = retained }
        else {
            guard create else { throw PairingError.keyMismatch }
            bytes = Curve25519.Signing.PrivateKey().rawRepresentation
            try SecureStore.save(bytes, key: name)
        }
        return try RelayClient(origin: url, route: RelayRoute(account: accountID, room: room, device: phoneID),
            signingKey: Curve25519.Signing.PrivateKey(rawRepresentation: bytes), http: URLSessionRelayHTTP(), connector: URLSessionWebSocketConnector())
    }
    func cloudClient() throws -> RelayClient {
        guard let record = store.active.first(where: { $0.relayOrigin != nil && $0.suspended != true }), let origin = record.relayOrigin else { throw PairingError.invalidState }
        return try relay(room: record.roomID, origin: origin)
    }
    private func scheduleReconnect(_ id: String) {
        guard reconnectors[id] == nil, !suspendedIDs.contains(id) else { return }
        reconnectors[id] = Task { [weak self] in
            var retryOnExit = true
            defer {
                if let self {
                    reconnectors.removeValue(forKey: id)
                    if retryOnExit, !Task.isCancelled, peers[id] == nil,
                       store.active.contains(where: { $0.device.device_id == id }) { scheduleReconnect(id) }
                }
            }
            var delay: Duration = .milliseconds(500)
            while !Task.isCancelled {
                guard let self, store.active.contains(where: { $0.device.device_id == id }), !revoking.contains(id) else { return }
                do { try await ensureConnected(id); return }
                catch is CancellationError { retryOnExit = false; return }
                catch let error as RelayError where error.permanent {
                    retryOnExit = false
                    if error == .httpRefused(403) {
                        try? store.suspend(deviceID: id)
                        suspendedIDs.insert(id)
                        notice = "Relay access suspended. Credentials retained; retry or explicitly remove this computer."
                    } else { notice = "Relay refused the connection. Check its settings." }
                    return
                } catch { notice = "Computer unavailable. Dictation will be held in History." }
                do { try await Task.sleep(for: delay) } catch { return }
                delay = min(delay * 2, .seconds(30))
            }
        }
    }
    func retrySuspended(_ id: String) {
        do { try store.suspend(deviceID: id, false); suspendedIDs.remove(id); scheduleReconnect(id) }
        catch { notice = "Suspension could not be updated." }
    }
    func reconnectAtLaunch() {
        for record in store.active { scheduleReconnect(record.device.device_id) }
        for record in store.records where record.revoked && record.notificationPending && record.relayOrigin != nil {
            Task { [weak self] in try? await self?.dropRoom(deviceID: record.device.device_id) }
        }
    }
    func begin(_ invitationOrCode: String, role: DeviceInfoRole) async throws -> String {
        await cancel(); self.role = role
        let epoch = pairingEpoch
        let invitation = try PairingInvitation(code: invitationOrCode, expectedAccount: accountID, clock: SystemPairingClock())
        guard !store.active.contains(where: { $0.roomID == invitation.payload.relay_room_id }) else { throw PairingError.invalidState }
        let transport: any PairingTransport
        let origin = runtime?.model.settings.relayURL.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !origin.isEmpty {
            let client = try relay(room: invitation.payload.relay_room_id, origin: origin, create: true)
            pendingRelay = client; pendingOrigin = origin
            try await client.redeem(invitation)
            transport = try await client.connect()
        } else { transport = LANTransport(endpoint: try await discover(room: invitation.payload.relay_room_id)) }
        guard epoch == pairingEpoch else { await transport.close(); throw CancellationError() }
        pendingTransport = transport
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
        let session = try await peer.applicationSession(registry: peerRegistry, localDeviceID: phoneID)
        // Both confirmations already succeeded. Persist keys separately from metadata.
        do {
            try SecureStore.save(peer.publicKey, key: keyName(device.device_id))
            try store.enroll(device, roomID: peer.roomID, relayOrigin: pendingOrigin)
            do { try await runtime.registry.register(device) }
            catch CoreError.revokedDevice { try await runtime.registry.rePair(device) }
        } catch {
            try? store.markRevoked(deviceID: device.device_id, notificationPending: true)
            try? SecureStore.delete(keyName(device.device_id)); try? await peerRegistry.revoke(session.peer)
            await session.close(transport: transport)
            throw error
        }
        let connected = ConnectedPeer(device: device, publicKey: peer.publicKey, roomID: peer.roomID, session: session)
        install(connected, transport: transport)
        self.confirmation = nil; pendingTransport = nil; pendingRelay = nil; pendingOrigin = nil
        return device
    }
    func cancel() async {
        pairingEpoch = UUID()
        if let confirmation, let pendingTransport { await confirmation.abort(transport: pendingTransport) }
        else { await pendingTransport?.close() }
        if let client = pendingRelay { try? await client.revoke(device: phoneID) }
        confirmation = nil; pendingTransport = nil; pendingRelay = nil; pendingOrigin = nil
    }
    private func install(_ peer: ConnectedPeer, transport: any PairingTransport) {
        let id = peer.device.device_id
        peers[id] = (peer, transport); connectedIDs.insert(id)
        notice = "Computer connected"
        readers[id] = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await peer.session.receive(transport: transport)
                    guard let self, peers[id]?.0.session === peer.session else { return }
                    switch message {
                    case .focusReport(let focus) where focus.device_id == id:
                        try runtime?.model.updateFocus(focus)
                    case .taskStatus(let status):
                        await runtime?.model.insertionStatus(status, from: id)
                    case .revoke:
                        remoteRevocations.insert(id)
                        await runtime?.model.revoke(id)
                        remoteRevocations.remove(id)
                        notice = "Computer revoked this phone. Pair again to reconnect."
                        return
                    default: break
                    }
                }
            } catch {
                guard let self, peers[id]?.0.session === peer.session else { return }
                peers.removeValue(forKey: id); connectedIDs.remove(id)
                notice = "Computer disconnected. Dictation will be held in History."
                scheduleReconnect(id)
            }
        }
    }
    private func ensureConnected(_ id: String) async throws {
        if peers[id] != nil { return }
        if let task = connecting[id] { return try await task.value }
        guard !revoking.contains(id), !suspendedIDs.contains(id), let record = store.active.first(where: { $0.device.device_id == id && $0.suspended != true }),
              let publicKey = try SecureStore.load(keyName(id)), let localKey = try SecureStore.load("noise-static") else { throw PairingError.keyMismatch }
        let task = Task { [self] in
            let transport: any PairingTransport
            if let origin = record.relayOrigin { transport = try await relay(room: record.roomID, origin: origin).connect() }
            else { transport = LANTransport(endpoint: try await discover(room: record.roomID)) }
            guard let enrollment = try await peerRegistry.lookup(publicKey: publicKey) else { await transport.close(); throw PairingError.keyMismatch }
            let session = try await SessionResume.initiate(staticKey: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: localKey),
                registry: peerRegistry, peer: enrollment, localDeviceID: phoneID, transport: transport)
            guard !Task.isCancelled, !revoking.contains(id), store.active.contains(where: { $0.device.device_id == id }) else {
                await session.close(transport: transport); throw CancellationError()
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
        reconnectors.removeValue(forKey: deviceID)?.cancel(); connectedIDs.remove(deviceID); suspendedIDs.remove(deviceID)
        // Remove delivery eligibility before awaits; keep transport solely for Revoke.
        let live = peers.removeValue(forKey: deviceID)
        let publicKey = try SecureStore.load(keyName(deviceID))
        let enrollment: Enrollment?
        if let publicKey { enrollment = try await peerRegistry.lookup(publicKey: publicKey) }
        else { enrollment = nil }
        do {
            try await PeerRevocation.perform(deviceID: deviceID, accountID: accountID, store: store,
                send: { data in
                    if remoteRevocations.contains(deviceID) { return }
                    guard let (peer, transport) = live else { throw PairingError.closedTransport }
                    try await peer.session.send(ProtocolCodec.decode(InnerMessage.self, from: data), transport: transport)
                }, erase: { try SecureStore.delete(keyName(deviceID)) }, close: {
                    readers.removeValue(forKey: deviceID)?.cancel()
                    if let enrollment { try? await peerRegistry.revoke(enrollment) }
                    if let (peer, transport) = live { await peer.session.close(transport: transport) }
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
    func dropRoom(deviceID: String) async throws {
        guard let record = store.records.first(where: { $0.device.device_id == deviceID }), let origin = record.relayOrigin else { return }
        if remoteRevocations.contains(deviceID) {
            try SecureStore.delete(relayKeyName(room: record.roomID)); return
        }
        do {
            let client = try relay(room: record.roomID, origin: origin)
            try await RelayMembershipCleanup.perform(peer: deviceID, local: phoneID) { try await client.revoke(device: $0) }
        } catch {
            try? store.markRevoked(deviceID: deviceID, notificationPending: true)
            notice = "Removed locally. Relay cleanup is pending; it will retry at launch."
            // Retain this key solely for cleanup. The tombstone already excludes
            // the room from reconnection, dictation and cloud selection.
            throw error
        }
        try SecureStore.delete(relayKeyName(room: record.roomID))
        try store.markRevoked(deviceID: deviceID, notificationPending: false)
    }
    func deliveryEpoch(_ deviceID: String) async -> UUID? { peers[deviceID]?.0.epoch }
    func isReachable(_ deviceID: String) async -> Bool { deviceID == phoneID || peers[deviceID] != nil }
    func showTarget(_ device: DeviceInfo) async throws {
        guard let runtime else { throw CoreError.unavailableTarget }
        runtime.preparedDestination = device.display_name
        if device.device_id != phoneID, peers[device.device_id] == nil {
            scheduleReconnect(device.device_id)
            throw DictationDeliveryError.unreachable
        }
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
    func insert(_ text: DictationText) async throws { try await insert(text, expectedEpoch: nil) }
    func insert(_ text: DictationText, expectedEpoch: UUID?) async throws {
        if text.target_device_id == phoneID {
            guard let runtime else { throw DictationDeliveryError.unreachable }
            try runtime.publish(text); return
        }
        guard let (peer, transport) = peers[text.target_device_id], expectedEpoch == nil || peer.epoch == expectedEpoch else { throw DictationDeliveryError.unreachable }
        try await peer.session.send(.dictationText(text), transport: transport)
        // Relay and current desktop schema have no insertion ACK. Never claim success.
        throw DictationDeliveryError.unconfirmed
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
