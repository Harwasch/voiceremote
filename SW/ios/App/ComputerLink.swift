import Foundation
import Observation
@preconcurrency import Network
import Crypto
import Pairing
import Core
import AppModel
import VoiceRemoteProtocol

/// Relay enrollment and fresh XX resume use the same Pairing application boundary as LAN.
@MainActor @Observable final class ComputerLink: ComputerPairing, DeviceRevocationHandler, DictationAvailability {
    let accountID: String
    let phoneID: String
    weak var runtime: AppRuntime?
    private let peerRegistry = PeerRegistry(store: KeychainStore(service: "VoiceRemote.Pairing"))
    private let wakeSockets = WakeSocketConnector(base: URLSessionWebSocketConnector())
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
        let connection: PhoneConnection
        let epoch = UUID()
    }
    private var preparedEpochs: [String: UUID] = [:]
    private var peers: [String: (ConnectedPeer, any PairingTransport)] = [:]
    private let store: PeerStore
    private var connecting: [String: Task<Void, Error>] = [:]
    private var revoking = Set<String>()
    private var pairingEpoch = UUID()
    private(set) var notice: String?
    var enrolledDevices: [DeviceInfo] { store.active.map(\.device) }
    private var role: DeviceInfoRole = .text_receiver
    private var allowAgentCommands = false
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
        let route = try RelayRoute(account: accountID, room: room, device: phoneID)
        let name = relayKeyName(room: room)
        let bytes: Data
        if let retained = try SecureStore.load(name) { bytes = retained }
        else {
            guard create else { throw PairingError.keyMismatch }
            bytes = Curve25519.Signing.PrivateKey().rawRepresentation
            try SecureStore.save(bytes, key: name)
        }
        return try RelayClient(origin: url, route: route,
            signingKey: Curve25519.Signing.PrivateKey(rawRepresentation: bytes), http: URLSessionRelayHTTP(), connector: wakeSockets)
    }
    func cloudClient() throws -> RelayClient {
        guard let record = store.active.first(where: { $0.relayOrigin != nil && $0.suspended != true }), let origin = record.relayOrigin else { throw PairingError.invalidState }
        return try relay(room: record.roomID, origin: origin)
    }
    func archiveClient(room: String) throws -> PhoneArchiveClient {
        guard let record = store.active.first(where: { $0.roomID == room && $0.relayOrigin != nil && $0.suspended != true }),
              let origin = record.relayOrigin, let url = URL(string: origin) else { throw PairingError.invalidState }
        return try PhoneArchiveClient(member: relay(room: room, origin: origin), origin: url, http: URLSessionArchiveHTTP())
    }
    var archiveRooms: [String] { Array(Set(store.active.filter { $0.relayOrigin != nil && $0.suspended != true }.map(\.roomID))).sorted() }
    func registerWake(token: Data, environment: RelayWakeRegistrationEnvironment) async throws -> Bool {
        var submitted = false
        for room in archiveRooms {
            try Task.checkCancellation()
            guard let record = store.active.first(where: { $0.roomID == room }), let origin = record.relayOrigin,
                  let url = URL(string: origin) else { continue }
            let sent = try await PhoneWake.register(token: token, environment: environment,
                route: RelayRoute(account: accountID, room: room, device: phoneID), origin: url, sockets: wakeSockets)
            submitted = submitted || sent
        }
        return submitted
    }
    /// Invalidate all old readers before any suspension, then establish fresh XX.
    /// No stored ciphertext or wake payload supplies an execution instruction.
    func reconcileWake() async throws {
        try runtime?.agentControl.prepareForWake()
        for task in readers.values { task.cancel() }; readers.removeAll()
        for task in reconnectors.values { task.cancel() }; reconnectors.removeAll()
        for task in connecting.values { task.cancel() }; connecting.removeAll()
        let old = peers; peers.removeAll(); connectedIDs.removeAll(); preparedEpochs.removeAll()
        for (id, (peer, _)) in old {
            runtime?.model.clearFocus(id); runtime?.model.forgetCaptureConnection(peer.epoch)
            await peer.connection.close()
        }
        var incomplete = false
        for record in store.active where record.suspended != true {
            try Task.checkCancellation()
            do {
                let id = record.device.device_id
                try await ensureConnected(id)
                guard let (peer, _) = peers[id] else { throw PairingError.closedTransport }
                try await runtime?.agentControl.connected(peer.device, epoch: peer.epoch) { message in
                    try await peer.connection.send(message)
                }
                try await runtime?.agentControl.reconcileTasks(on: id, epoch: peer.epoch)
            }
            catch { try Task.checkCancellation(); incomplete = true; scheduleReconnect(record.device.device_id) }
        }
        if incomplete { throw PairingError.closedTransport }
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
        try await begin(invitationOrCode, role: role, allowAgentCommands: false)
    }
    func begin(_ invitationOrCode: String, role: DeviceInfoRole, allowAgentCommands: Bool) async throws -> String {
        await cancel(); self.role = role
        self.allowAgentCommands = allowAgentCommands && (role == .agent || role == .both)
        let epoch = pairingEpoch
        do {
            let invitation = try PairingInvitation(code: invitationOrCode, expectedAccount: accountID, clock: SystemPairingClock())
            guard !store.active.contains(where: { $0.roomID == invitation.payload.relay_room_id }) else { throw PairingError.invalidState }
            let origin = runtime?.model.settings.relayURL.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // LAN-only invitations may use a non-relay room ID. A configured
            // relay must not prevent pairing with such a computer over LAN.
            let client = origin.isEmpty ? nil : try? relay(room: invitation.payload.relay_room_id, origin: origin, create: true)
            pendingRelay = client
            let keyData = try SecureStore.loadOrCreateKey("noise-static")
            let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keyData)
            let (transport, confirmation, viaRelay) = try await PreferredConnection.connect(lan: { [self] in
                return try await PreferredConnection.tryLAN(candidates: await discover(room: invitation.payload.relay_room_id)) { endpoint in
                    let transport = try await LANTransport(stream: NetworkLANStream(endpoint: endpoint))
                    let confirmation = try await PairingConnection.initiate(invitation: invitation, staticKey: key,
                        clock: SystemPairingClock(), transport: transport, timeout: .seconds(5))
                    return (transport as any PairingTransport, confirmation, false)
                }
            }, relay: client.map { client in { @Sendable in
                try await client.redeem(invitation)
                let transport = try await client.connect()
                let confirmation = try await PairingConnection.initiate(invitation: invitation, staticKey: key,
                    clock: SystemPairingClock(), transport: transport)
                return (transport, confirmation, true)
            } })
            guard epoch == pairingEpoch else { await confirmation.abort(transport: transport); throw CancellationError() }
            pendingTransport = transport
            if let client {
                if viaRelay { pendingOrigin = origin }
                else {
                    do { try await client.redeem(invitation); pendingOrigin = origin }
                    catch { notice = "LAN pairing is available; relay enrollment failed. Pair again to enable fallback." }
                }
            }
            guard epoch == pairingEpoch else { await confirmation.abort(transport: transport); throw CancellationError() }
            self.confirmation = confirmation
            return await confirmation.phrase
        } catch {
            if epoch == pairingEpoch { await cancel() }
            throw error
        }
    }

    func confirm(_ phrase: String) async throws -> DeviceInfo {
        guard let confirmation, let transport = pendingTransport, let runtime else { throw PairingError.invalidState }
        do {
            let phone = DeviceInfo(account_id: accountID, device_id: phoneID, display_name: "iPhone", platform: .ios,
                role: .capture, capabilities: allowAgentCommands ? [.delegate_task, .cancel_task, .open_resource] : [])
            try await confirmation.confirmLocal(displayedPhrase: phrase, device: phone, transport: transport)
            try await confirmation.receiveConfirmation(transport: transport)
            let peer = try await confirmation.finish()
            // Do not expand peer-declared role/capabilities. Role selection can narrow.
            let capabilities = peer.device.capabilities.filter { capability in
                (capability == .receive_text && (role == .both || role == .text_receiver)) ||
                (allowAgentCommands && capability != .receive_text && (role == .both || role == .agent))
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
            let connected = ConnectedPeer(device: device, publicKey: peer.publicKey, roomID: peer.roomID, session: session, connection: PhoneConnection(session: session, transport: transport))
            install(connected, transport: transport)
            if pendingRelay != nil, pendingOrigin == nil {
                notice = "Computer connected over LAN. Relay enrollment was unavailable; pair again to enable fallback."
            }
            self.confirmation = nil; pendingTransport = nil; pendingRelay = nil; pendingOrigin = nil
            return device
        } catch {
            if self.confirmation === confirmation { await cancel() }
            throw error
        }
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
                    let message = try await peer.connection.receive()
                    guard let self, peers[id]?.0.session === peer.session else { return }
                    switch message {
                    case .focusReport(let focus) where focus.device_id == id:
                        try runtime?.model.updateFocus(focus)
                        synchronizeState(heartbeatFor: id)
                    case .dictationOutcome(let outcome):
                        await runtime?.model.dictationOutcome(outcome, from: id)
                    case .captureControl(let request):
                        let received = ContinuousClock.now
                        guard let runtime, runtime.acceptingRemoteControl else { continue }
                        let result = await runtime.model.captureControl(request, connectionID: peer.epoch, receivedAt: received)
                        guard peers[id]?.0.session === peer.session else { return }
                        try await peer.connection.send(.captureControlResult(result))
                        synchronizeState()
                    case .agentInventory(let inventory):
                        try runtime?.agentControl.receive(inventory, from: id, epoch: peer.epoch)
                    case .taskStatus(let status):
                        try runtime?.agentControl.receive(status, from: id, epoch: peer.epoch)
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
                runtime?.model.clearFocus(id)
                runtime?.model.forgetCaptureConnection(peer.epoch)
                runtime?.agentControl.disconnected(id, epoch: peer.epoch)
                peers.removeValue(forKey: id); connectedIDs.remove(id)
                notice = "Computer disconnected. Dictation will be held in History."
                scheduleReconnect(id)
            }
        }
        synchronizeState()
        Task { [weak self] in
            guard let self, peers[id]?.0.epoch == peer.epoch else { return }
            try? await runtime?.agentControl.connected(peer.device, epoch: peer.epoch) { message in
                try await peer.connection.send(message)
            }
            guard peers[id]?.0.epoch == peer.epoch else { return }
            await runtime?.model.reconcileDictation(on: id) { segment in
                try await peer.connection.reconcile(segmentID: segment)
            }
            await runtime?.refreshWakeRegistration()
            await runtime?.maintainArchive()
        }
    }
    func synchronizeState(heartbeatFor deviceID: String? = nil) {
        guard let runtime else { return }
        let mode = runtime.model.controls.mode, capture = runtime.model.controls.capture, listening = runtime.model.isRecording
        for (id, (peer, _)) in peers where deviceID == nil || deviceID == id {
            Task {
                try? await peer.connection.publishState(phoneID: phoneID, mode: mode, capture: capture,
                    listening: listening, heartbeat: deviceID != nil)
            }
        }
    }
    private func ensureConnected(_ id: String) async throws {
        if peers[id] != nil { return }
        if let task = connecting[id] { return try await task.value }
        guard !revoking.contains(id), !suspendedIDs.contains(id), let record = store.active.first(where: { $0.device.device_id == id && $0.suspended != true }),
              let publicKey = try SecureStore.load(keyName(id)), let localKey = try SecureStore.load("noise-static") else { throw PairingError.keyMismatch }
        let task = Task { [self] in
            guard let enrollment = try await peerRegistry.lookup(publicKey: publicKey) else { throw PairingError.keyMismatch }
            let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: localKey)
            let client = try record.relayOrigin.map { try relay(room: record.roomID, origin: $0) }
            let (transport, session) = try await PreferredConnection.connect(lan: { [self] in
                return try await PreferredConnection.tryLAN(candidates: await discover(room: record.roomID)) { endpoint in
                    let transport = try await LANTransport(stream: NetworkLANStream(endpoint: endpoint))
                    let session = try await SessionResume.initiate(staticKey: key, registry: peerRegistry,
                        peer: enrollment, localDeviceID: phoneID, transport: transport, timeout: .seconds(5))
                    return (transport as any PairingTransport, session)
                }
            }, relay: client.map { client in { @Sendable [self] in
                let transport = try await client.connect()
                let session = try await SessionResume.initiate(staticKey: key, registry: peerRegistry,
                    peer: enrollment, localDeviceID: phoneID, transport: transport)
                return (transport, session)
            } })
            guard !Task.isCancelled, !revoking.contains(id), store.active.contains(where: { $0.device.device_id == id }) else {
                await session.close(transport: transport); throw CancellationError()
            }
            install(ConnectedPeer(device: record.device, publicKey: publicKey, roomID: record.roomID, session: session, connection: PhoneConnection(session: session, transport: transport)), transport: transport)
        }
        connecting[id] = task
        defer { if !task.isCancelled { connecting.removeValue(forKey: id) } }
        try await task.value
    }
    func cancelPendingWake() {
        for task in connecting.values { task.cancel() }
        connecting.removeAll()
    }
    func deleteKey(deviceID: String) async throws {
        revoking.insert(deviceID); defer { revoking.remove(deviceID) }
        runtime?.model.clearFocus(deviceID)
        preparedEpochs.removeValue(forKey: deviceID)
        connecting.removeValue(forKey: deviceID)?.cancel()
        reconnectors.removeValue(forKey: deviceID)?.cancel(); connectedIDs.remove(deviceID); suspendedIDs.remove(deviceID)
        // Remove delivery eligibility before awaits; keep transport solely for Revoke.
        let live = peers.removeValue(forKey: deviceID)
        if let live { runtime?.agentControl.disconnected(deviceID, epoch: live.0.epoch) }
        let publicKey = try SecureStore.load(keyName(deviceID))
        let enrollment: Enrollment?
        if let publicKey { enrollment = try await peerRegistry.lookup(publicKey: publicKey) }
        else { enrollment = nil }
        do {
            try await PeerRevocation.perform(deviceID: deviceID, accountID: accountID, store: store,
                send: { data in
                    if remoteRevocations.contains(deviceID) { return }
                    guard let (peer, _) = live else { throw PairingError.closedTransport }
                    try await peer.connection.send(ProtocolCodec.decode(InnerMessage.self, from: data))
                }, erase: { try SecureStore.delete(keyName(deviceID)) }, close: {
                    readers.removeValue(forKey: deviceID)?.cancel()
                    if let enrollment { try? await peerRegistry.revoke(enrollment) }
                    if let (peer, _) = live {
                        runtime?.model.clearFocus(deviceID)
                        runtime?.model.forgetCaptureConnection(peer.epoch)
                        await peer.connection.close()
                    }
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
        if let url = URL(string: origin), let route = try? RelayRoute(account: accountID, room: record.roomID, device: phoneID) {
            await wakeSockets.forget(origin: url, route: route)
        }
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
    func reconcile(segmentID: String, deviceID: String) async throws -> DictationOutcome {
        if deviceID == phoneID, let runtime {
            return DictationOutcome(account_id: accountID, segment_id: segmentID, target_device_id: deviceID,
                outcome: try runtime.keyboardInsertionConfirmed(segmentID) ? .inserted : .unconfirmed)
        }
        guard let (peer, _) = peers[deviceID] else { throw DictationDeliveryError.unreachable }
        return try await peer.connection.reconcile(segmentID: segmentID)
    }
    func deliveryEpoch(_ deviceID: String) async -> UUID? { preparedEpochs[deviceID] ?? peers[deviceID]?.0.epoch }
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
            guard let (peer, _) = peers[device.device_id] else { throw CoreError.unavailableTarget }
            try await peer.connection.prepare()
            guard peers[device.device_id]?.0.session === peer.session else { throw DictationDeliveryError.unreachable }
            preparedEpochs[device.device_id] = peer.epoch
        }
    }
    func insert(_ text: DictationText) async throws { try await insert(text, expectedEpoch: nil) }
    func insert(_ text: DictationText, expectedEpoch: UUID?) async throws {
        if text.target_device_id == phoneID {
            guard let runtime else { throw DictationDeliveryError.unreachable }
            try runtime.publish(text)
            let deadline = ContinuousClock.now + .seconds(3)
            while ContinuousClock.now < deadline {
                if try runtime.keyboardInsertionConfirmed(text.segment_id) { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw DictationDeliveryError.unconfirmed
        }
        guard let (peer, _) = peers[text.target_device_id], expectedEpoch == nil || peer.epoch == expectedEpoch else { throw DictationDeliveryError.unreachable }
        let outcome = try await peer.connection.insert(text)
        switch outcome.outcome {
        case .inserted: return
        case .unavailable: throw DictationDeliveryError.failed
        case .unconfirmed: throw DictationDeliveryError.unconfirmed
        }
    }
    private func discover(room: String) -> AsyncThrowingStream<NWEndpoint, Error> {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_voiceremote._tcp", domain: nil), using: .tcp)
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(64)) { output in
            let seen = DiscoveryResults()
            browser.browseResultsChangedHandler = { @Sendable results, _ in
                for result in results {
                    if case .bonjour(let record) = result.metadata,
                       record.dictionary["room"] == room, seen.insert(result.endpoint) {
                        if case .dropped = output.yield(result.endpoint) { output.finish(throwing: PairingError.messageTooLarge) }
                    }
                }
            }
            browser.stateUpdateHandler = { @Sendable state in
                if case .failed(let error) = state { output.finish(throwing: error) }
                // Browser cancellation is not task cancellation. Deadline closure
                // and browser callbacks must never manufacture CancellationError.
                if case .cancelled = state { output.finish() }
            }
            let deadline = Task {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                output.finish(); browser.cancel()
            }
            output.onTermination = { @Sendable _ in deadline.cancel(); browser.cancel() }
            browser.start(queue: DispatchQueue(label: "VoiceRemote.Discovery"))
        }
    }
}
private final class DiscoveryResults: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = Set<NWEndpoint>()
    func insert(_ endpoint: NWEndpoint) -> Bool { lock.withLock { seen.insert(endpoint).inserted } }
}
