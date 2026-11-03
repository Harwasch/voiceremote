import Foundation
import Observation
@preconcurrency import CoreBluetooth
import Copus
import AppModel
import Pairing
import Stt
import Core
import VoiceRemoteProtocol

/// Custom GATT, NOT LE Audio. No BLE data can invoke Policy/PhoneInput approval.
@MainActor @Observable final class RemoteBLELink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let service = CBUUID(string: "f934bb04-9472-4805-8ea8-11f9f5bcabbc")
    private static let infoID = CBUUID(string: "cba8d4dd-2aea-4964-a0b7-ef58095a1171")
    private static let inputID = CBUUID(string: "9f0f839c-fe73-46e4-acc3-53518ed5689c")
    private static let stateID = CBUUID(string: "d9306a59-9e64-48c5-8722-827a0592a412")
    private static let audioID = CBUUID(string: "6df454c4-b29c-4638-b4f5-cc43e81e2427")
    private static let offlineControlID = CBUUID(string: "14af3886-4d49-4ccd-a2dc-3eea7b5b1577")
    private static let offlineResultID = CBUUID(string: "4fbc7f55-c428-466b-b308-771f7eac6c66")
    private static let offlineProgressID = CBUUID(string: "32ac7675-c84c-4a2b-a276-ed45a9434426")
    private var offlineControl: CBCharacteristic?
    private var resultSubscribed = false
    private var progressSubscribed = false
    private var offlineReply = OfflineAssembly()
    private var offlineProgressAssembly = OfflineAssembly()
    private var offlineProgress: OfflineProgress?
    private var progressUTC: UInt64 = 0
    private var syncTransaction: UInt16 = 0
    private var syncPending: (UInt16, CheckedContinuation<Data, Error>)?
    private var syncWrites: [Data] = []
    private var syncWriteInFlight = false
    private var syncTask: Task<Void, Never>?
    private var syncDrain: Task<Void, Never>?
    private var waitingForDrain = false
    private var resumeSyncPending = false
    private var syncInterruption: OfflineSyncInterruption?
    private(set) var offlineIssues: [OfflineSyncIssue] = []
    private var syncEpoch = UUID()
    private var refreshingProgress = false
    private(set) var offlineStatus = ""
    func selectionChanged() {
        controls.reset()
        if let input = tracker.last { _ = controls.accept(input, edge: false) }
        if let model = AppRuntime.shared?.model { synchronize(model: model) }
    }
    var sourceName: String { info?.sourceName ?? "Remote unavailable" }
    var sourceIdentity: String? { enrolledRemoteIdentity }
    var hasCapture: Bool { source != nil }
    func prepareRecorderControls(model: VoiceAppModel) throws {
        guard tracker.synchronized, let input = tracker.last, input.capture == 2 || input.pressed else { throw RemoteContractError.notReady }
        model.remotePositions(capture: input.capture == 2 ? .continuous : .hold, mode: input.mode == 0 ? .dictation : .ai_control)
    }
    private var controls = RemoteControls()
    private(set) var status = "Disconnected"
    private(set) var discovered: [CBPeripheral] = []
    private var central: CBCentralManager!
    private var wantsScan = false
    private var peripheral: CBPeripheral?
    private var info: RemoteInfo?
    private var tracker = RemoteInputTracker()
    private var activeWriteControlRevision: UInt64?
    private var stateCharacteristic: CBCharacteristic?
    private var inputSubscribed = false
    private var audioSubscribed = false
    private var writes: [Data] = []
    private struct DisplayRequest {
        let id: UUID
        let state: RemotePhoneState
        let completion: CheckedContinuation<Void, Error>?
    }
    private var queue: [DisplayRequest] = []
    private var activeWrite: DisplayRequest?
    private var lastPresentation: RemotePhoneState?
    private var transaction: UInt16 = 0
    private var displayReady = false
    private var captureArmed = false
    private var source: RemoteBLECaptureSource?
    private var captureID: UUID?
    private var watchdog: Task<Void, Never>?
    private var lastAudio = ContinuousClock.now
    private var highestSegment: UInt32 = 0
    // CoreBluetooth exposes neither bond keys nor the pairing method. Protected
    // GATT access plus explicit OS/remote Numeric Comparison confirmation pins the
    // peripheral; firmware must reject unauthenticated/Legacy/Just Works access.
    private let enrollments = RemoteEnrollmentStore(store: KeychainStore(service: "VoiceRemote.RemoteEnrollment"))
    private var connectionEpoch = UUID()
    private var protectedInfoRead = false
    private var enrollmentRestore: Task<Void, Never>?
    private(set) var enrollmentReady = false
    private(set) var enrollmentBusy = false
    private var authenticatedEnrollment = false
    private var enrolledRemoteIdentity: String?
    var isEnrolled: Bool { authenticatedEnrollment && enrolledRemoteIdentity != nil }
    override init() { super.init() }
    func scan() {
        wantsScan = true
        if central == nil {
            status = "Waiting for Bluetooth permission"
            central = CBCentralManager(delegate: self, queue: .main)
            return
        }
        guard central.state == .poweredOn else { status = "Bluetooth is unavailable"; return }
        discovered = []; central.scanForPeripherals(withServices: [Self.service]); status = "Choose your remote"
    }
    func connect(_ item: CBPeripheral) {
        disconnect(); peripheral = item; item.delegate = self; central.stopScan(); central.connect(item)
        status = "Connecting — compare the pairing number on both screens"
    }
    func disconnect() {
        wantsScan = false
        connectionEpoch = UUID(); enrollmentRestore?.cancel(); enrollmentRestore = nil
        enrollmentReady = false; enrollmentBusy = false; protectedInfoRead = false
        pauseSync(); resumeSyncPending = false; waitingForDrain = false; offlineIssues = []
        offlineControl = nil; resultSubscribed = false; progressSubscribed = false
        offlineProgress = nil; offlineProgressAssembly.reset(); syncTransaction = 0
        syncWriteInFlight = false
        source?.interrupt(); source = nil; watchdog?.cancel(); watchdog = nil
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil; info = nil; stateCharacteristic = nil; highestSegment = 0; tracker.reset()
        controls.reset()
        failWrites(); lastPresentation = nil; displayReady = false; captureArmed = false
        authenticatedEnrollment = false; enrolledRemoteIdentity = nil; inputSubscribed = false; audioSubscribed = false
        status = "Disconnected"
    }
    func makeCapture(model: VoiceAppModel) async throws -> any CaptureSession {
        guard authenticatedEnrollment, inputSubscribed, audioSubscribed,
              let info, tracker.synchronized, let input = tracker.last, input.capture != 0,
              input.status & 2 == 0, input.capture == 2 || input.pressed else { throw RemoteContractError.notReady }
        pauseSync(forLiveCapture: true)
        let expectedControls = tracker.controlRevision
        let id = UUID(); captureID = id
        let capture = try RemoteBLECaptureSource(maximum: info.maxPacket, afterSegment: highestSegment,
            provisional: input.capture == 1 && input.pressed, stop: { [weak self] in self?.disarm(captureID: id) })
        source = capture
        do {
            let state = try RemotePhoneState.presentation(controls: model.controls, devices: model.devices, phoneID: model.phoneID,
                destination: model.destination, recording: true, acknowledgedSequence: input.sequence, arm: true)
            try await writeAndWait(state)
            guard authenticatedEnrollment, tracker.controlRevision == expectedControls, tracker.last?.capture != 0 else { throw RemoteContractError.notReady }
        } catch { capture.interrupt(); source = nil; throw error }
        lastAudio = .now
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if lastAudio.duration(to: .now) >= .seconds(1) { loss(); return }
            }
        }
        return capture
    }
    func pinnedCapture(model: VoiceAppModel, forBenchmark: Bool) -> CaptureFactory {
        let epoch = connectionEpoch, revision = tracker.controlRevision
        return { [weak self, weak model] in
            guard let self, let model, connectionEpoch == epoch, tracker.controlRevision == revision else { throw RemoteContractError.notReady }
            if forBenchmark { try prepareRecorderControls(model: model) }
            return try await makeCapture(model: model)
        }
    }
    func synchronize(model: VoiceAppModel) {
        if model.isRecording { pauseSync(forLiveCapture: true) }
        else { resumeWhenIdle() }
        guard peripheral != nil else { return }
        guard authenticatedEnrollment else { enqueue(RemotePhoneState.enrollmentState, completion: nil); return }
        do {
            let state = try RemotePhoneState.presentation(controls: model.controls, devices: model.devices, phoneID: model.phoneID,
                destination: model.destination, recording: model.isRecording, acknowledgedSequence: tracker.last?.sequence ?? 0,
                arm: source != nil && authenticatedEnrollment && tracker.last?.capture != 0)
            enqueue(state, completion: nil)
        } catch { status = "Remote destination cannot be displayed" }
    }
    func present(model: VoiceAppModel, destination: DeviceInfo) async throws {
        guard peripheral != nil, authenticatedEnrollment else { return }
        let state = try RemotePhoneState.presentation(controls: model.controls, devices: model.devices, phoneID: model.phoneID,
            destination: destination, recording: model.isRecording, acknowledgedSequence: tracker.last?.sequence ?? 0,
            arm: source != nil && authenticatedEnrollment && tracker.last?.capture != 0)
        try await writeAndWait(state)
    }
    private func writeAndWait(_ state: RemotePhoneState) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { completion in enqueue(state, completion: completion) }
        } onCancel: { Task { @MainActor [weak self] in self?.disconnect() } }
    }
    private func enqueue(_ state: RemotePhoneState, completion: CheckedContinuation<Void, Error>?) {
        guard peripheral != nil else { completion?.resume(throwing: RemoteContractError.notReady); return }
        let state = authenticatedEnrollment ? state : RemotePhoneState.enrollmentState
        if completion == nil, lastPresentation == state { return }
        lastPresentation = state
        if !state.arm { captureArmed = false }
        if completion == nil, queue.last?.completion == nil, !queue.isEmpty { queue.removeLast() }
        guard queue.count < 8 else { completion?.resume(throwing: RemoteContractError.notReady); return }
        let id = UUID()
        queue.append(DisplayRequest(id: id, state: state, completion: completion))
        // ATT writes do not expose application transaction IDs in callbacks. A
        // timeout disconnects before another transaction, preventing stale ACKs.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self else { return }
            if activeWrite?.id == id || queue.contains(where: { $0.id == id }) { loss() }
        }
        pump()
    }
    private func pump() {
        if activeWrite == nil, queue.isEmpty { pumpSync(); return }
        guard !syncWriteInFlight, activeWrite == nil, !queue.isEmpty, info != nil,
              inputSubscribed, audioSubscribed,
              let peripheral, let characteristic = stateCharacteristic else { return }
        let request = queue.removeFirst()
        do {
            if request.state.arm, !tracker.canArm(acknowledging: request.state.acknowledgedSequence) {
                throw RemoteContractError.notReady
            }
            transaction &+= 1
            let budget = RemotePhoneState.writeBudget(osMaximum: peripheral.maximumWriteValueLength(for: .withResponse))
            var nextTracker = tracker
            writes = try nextTracker.stateForWrite(request.state).fragments(transaction: transaction, budget: budget)
            tracker = nextTracker
            activeWrite = request; displayReady = false
            activeWriteControlRevision = tracker.controlRevision
            peripheral.writeValue(writes.removeFirst(), for: characteristic, type: .withResponse)
        } catch { request.completion?.resume(throwing: error); pump() }
    }
    private func failWrites() {
        activeWrite?.completion?.resume(throwing: RemoteContractError.notReady)
        for request in queue { request.completion?.resume(throwing: RemoteContractError.notReady) }
        activeWrite = nil; activeWriteControlRevision = nil; queue = []; writes = []
    }
    private func disarm(captureID expectedID: UUID? = nil) {
        guard expectedID == nil || expectedID == captureID else { return }
        source = nil
        captureID = nil
        captureArmed = false
        watchdog?.cancel(); watchdog = nil
        guard var state = lastPresentation else { return }
        state.recording = 0; state.arm = false; state.requestSnapshot = true
        state.acknowledgedSequence = tracker.last?.sequence ?? 0
        enqueue(state, completion: nil)
        resumeWhenIdle()
    }
    private func loss() {
        disconnect()
        status = "Interrupted — reconnect and use a fresh trigger"
    }
    func cancelOfflineSync() { pauseSync(); offlineStatus = "Sync paused" }
    private func pauseSync(forLiveCapture: Bool = false) {
        if forLiveCapture {
            if syncTask != nil { syncInterruption?.yieldToLiveCapture() }
            resumeSyncPending = true
        }
        syncEpoch = UUID()
        if let syncTask { syncDrain = syncTask }
        syncTask?.cancel(); syncTask = nil
        syncPending?.1.resume(throwing: CancellationError()); syncPending = nil
        syncWrites = []; offlineReply.reset()
    }
    private func pumpSync() {
        guard !syncWriteInFlight, activeWrite == nil, queue.isEmpty, !syncWrites.isEmpty,
              syncPending != nil, let peripheral, let offlineControl else { return }
        syncWriteInFlight = true
        peripheral.writeValue(syncWrites.removeFirst(), for: offlineControl, type: .withResponse)
    }
    private func offlineRequest(_ payload: Data) async throws -> Data {
        guard authenticatedEnrollment, info?.supportsOfflineSync == true,
              resultSubscribed, progressSubscribed, source == nil, tracker.synchronized, let input = tracker.last,
              (payload.first != 3 || input.capture != 0), input.status & 3 == 0, syncPending == nil, let peripheral else { throw RemoteContractError.notReady }
        guard syncTransaction < UInt16.max else { disconnect(); throw RemoteContractError.notReady }
        syncTransaction += 1
        let tx = syncTransaction
        let fragments = try OfflineWire.fragments(payload, transaction: tx,
            budget: RemotePhoneState.writeBudget(osMaximum: peripheral.maximumWriteValueLength(for: .withResponse)))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                syncPending = (tx, continuation); syncWrites = fragments; offlineReply.reset(); pump()
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    guard let self, syncPending?.0 == tx else { return }
                    pauseSync(); offlineStatus = "Sync interrupted — tap Retry sync"
                }
            }
        } onCancel: { Task { @MainActor [weak self] in
            guard let self, syncPending?.0 == tx else { return }; pauseSync()
        } }
    }
    private func restoreOrOfferEnrollment() {
        guard protectedInfoRead, info != nil, inputSubscribed, audioSubscribed, let peripheral,
              !authenticatedEnrollment, enrollmentRestore == nil else { return }
        let epoch = connectionEpoch, id = peripheral.identifier
        enrollmentRestore = Task { [weak self] in
            guard let self else { return }
            defer { if connectionEpoch == epoch { enrollmentRestore = nil } }
            do {
                let identity = try await enrollments.identity(peripheralID: id, protectedAccess: true)
                guard connectionEpoch == epoch, self.peripheral?.identifier == id else { return }
                if let identity { activateEnrollment(identity) }
                else { enrollmentReady = true; status = "Compare the six-digit iPhone system pairing number with the remote, then confirm both below" }
            } catch { status = "Remote enrollment could not be loaded" }
        }
    }
    private func activateEnrollment(_ identity: String) {
        authenticatedEnrollment = true; enrolledRemoteIdentity = identity; enrollmentReady = false
        controls.reset()
        if let input = tracker.last { _ = controls.accept(input, edge: false) }
        status = "Enrolled remote connected"; startOfflineSync()
        if let model = AppRuntime.shared?.model { synchronize(model: model) }
    }
    func confirmEnrollment(systemCode: String, remoteCode: String) async {
        guard enrollmentReady, !enrollmentBusy, protectedInfoRead, let peripheral else { status = "Connect and complete the system pairing prompt first"; return }
        let epoch = connectionEpoch, id = peripheral.identifier
        enrollmentBusy = true
        defer { if epoch == connectionEpoch { enrollmentBusy = false } }
        do {
            let identity = try await enrollments.confirm(peripheralID: id, protectedAccess: true, systemCode: systemCode, remoteCode: remoteCode)
            guard epoch == connectionEpoch, self.peripheral?.identifier == id else { return }
            activateEnrollment(identity)
        } catch { status = "Enrollment rejected. Both fresh six-digit numbers must match; reject no-number, Legacy or Just Works pairing." }
    }
    func forgetEnrollment() async {
        guard let id = peripheral?.identifier else { status = "Connect the remote to remove its saved pin"; return }
        disconnect()
        do { try await enrollments.revoke(peripheralID: id); status = "Remote removed. Forget its Bluetooth bond in iPhone Settings and erase the owner bond on the remote before pairing again." }
        catch { status = "Remote enrollment could not be removed" }
    }
    private func refreshProgress() {
        guard let peripheral, let progress = peripheral.services?.first(where: { $0.uuid == Self.service })?.characteristics?.first(where: { $0.uuid == Self.offlineProgressID }),
              info?.supportsOfflineSync == true else { offlineStatus = "This remote does not support offline sync"; return }
        offlineProgress = nil; offlineProgressAssembly.reset(); progressSubscribed = false
        refreshingProgress = true; peripheral.setNotifyValue(false, for: progress)
    }
    private func resumeWhenIdle() {
        guard resumeSyncPending, syncTask == nil, !waitingForDrain, isEnrolled, source == nil,
              let input = tracker.last, !input.pressed, input.status & 3 == 0,
              AppRuntime.shared?.model.isRecording != true else { return }
        waitingForDrain = true
        let epoch = connectionEpoch, drain = syncDrain
        Task { [weak self] in
            await drain?.value
            guard let self, connectionEpoch == epoch else { return }
            syncDrain = nil; waitingForDrain = false; resumeSyncPending = false
            refreshProgress()
        }
    }
    func retryOfflineSync() {
        guard let remoteIdentity = enrolledRemoteIdentity, let host = AppRuntime.shared else { offlineStatus = "Enroll and confirm the connected remote before syncing"; return }
        pauseSync()
        let drain = syncDrain
        Task { [weak self] in
            await drain?.value
            do { try await host.offlineSync.retryFailedTranscriptions(remote: remoteIdentity) }
            catch { self?.offlineStatus = "Sync is stopping — tap Retry again"; return }
            guard let self, enrolledRemoteIdentity == remoteIdentity else { return }
            syncDrain = nil; refreshProgress()
        }
    }
    func discardOfflineRecording(_ id: String) async {
        guard let remoteIdentity = enrolledRemoteIdentity, let host = AppRuntime.shared else { offlineStatus = "Reconnect the enrolled remote before discarding"; return }
        pauseSync(); await syncDrain?.value; syncDrain = nil
        do {
            try await host.offlineSync.discard(id: id, remote: remoteIdentity)
            offlineIssues = await host.offlineSync.issues(remote: remoteIdentity)
            refreshProgress()
        } catch { offlineStatus = "Recording could not be discarded; it remains retained" }
    }
    func startOfflineSync() {
        guard syncTask == nil, authenticatedEnrollment, let info, info.supportsOfflineSync,
              resultSubscribed, progressSubscribed, source == nil, peripheral != nil,
              let progress = offlineProgress, progress.status & 3 == 0, tracker.synchronized, let input = tracker.last,
              !input.pressed, input.status & 3 == 0, let remoteIdentity = enrolledRemoteIdentity,
              let host = AppRuntime.shared, !host.model.isRecording else { return }
        if syncDrain != nil { resumeSyncPending = true; resumeWhenIdle(); return }
        let utc = progressUTC
        let interruption = OfflineSyncInterruption(); syncInterruption = interruption
        let epoch = UUID(); syncEpoch = epoch
        syncTask = Task { [weak self, weak host] in
            guard let self, let host else { return }
            defer { if syncEpoch == epoch { syncTask = nil } }
            guard syncEpoch == epoch else { return }
            offlineStatus = "Syncing offline recordings"
            do {
                try await host.offlineSync.synchronize(remote: remoteIdentity, info: info, enrolled: authenticatedEnrollment,
                    progress: progress, utcMilliseconds: utc, interruption: interruption, allowAudioFetch: input.capture != 0,
                    request: { [weak self] in
                        guard let self else { throw RemoteContractError.notReady }
                        return try await self.offlineRequest($0)
                    }, transcribe: { [weak host] in
                        guard let host else { throw SttFailure.unavailable }
                        return try await host.transcribeOffline($0)
                    }, saveText: { [weak host] id, text in
                        guard let host else { throw SttFailure.unavailable }
                        let metadata = await host.offlineSync.metadata(for: id)
                        try await host.model.saveOfflineText(id: id, text: text, origin: metadata.map(OfflineTextOrigin.init))
                    })
                if syncEpoch == epoch { offlineStatus = "Offline recordings saved to History" }
            } catch is CancellationError { if syncEpoch == epoch { offlineStatus = "Sync paused" } }
            catch { if syncEpoch == epoch { offlineStatus = "Some recordings need attention; later recordings were still processed" } }
            if enrolledRemoteIdentity == remoteIdentity { offlineIssues = await host.offlineSync.issues(remote: remoteIdentity) }
        }
    }
    // The central is created on .main; its peripheral delegates use that same
    // queue. Handle callbacks synchronously there: never send CB objects in Tasks.
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated { [self] in
            if central.state == .poweredOn { if wantsScan { scan() } }
            else if central.state != .unknown && central.state != .resetting { disconnect(); status = "Bluetooth is unavailable" }
        }
    }
    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated { [self] in
            guard !discovered.contains(where: { $0.identifier == peripheral.identifier }) else { return }
            discovered.append(peripheral)
        }
    }
    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { [self] in
            guard self.peripheral === peripheral else { return }
            peripheral.discoverServices([Self.service])
        }
    }
    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { [self] in
            guard self.peripheral === peripheral else { return }; self.loss()
        }
    }
    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { [self] in
            guard self.peripheral === peripheral else { return }; self.disconnect()
        }
    }
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated { [self] in
            guard self.peripheral === peripheral else { return }
            guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else { self.loss(); return }
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated { [self] in
            guard self.peripheral === peripheral else { return }
            guard error == nil, let characteristics = service.characteristics,
                  [Self.infoID, Self.inputID, Self.stateID, Self.audioID].allSatisfy({ id in characteristics.contains { $0.uuid == id } }) else { self.loss(); return }
            offlineControl = characteristics.first(where: { $0.uuid == Self.offlineControlID })
            for characteristic in characteristics {
                switch characteristic.uuid {
                case Self.infoID: peripheral.readValue(for: characteristic)
                case Self.inputID, Self.audioID: peripheral.setNotifyValue(true, for: characteristic)
                case Self.stateID: stateCharacteristic = characteristic; pump()
                case Self.offlineControlID: offlineControl = characteristic
                default: break
                }
            }
        }
    }
    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { [self] in
            guard self.peripheral === peripheral else { return }
            if characteristic.uuid == Self.offlineProgressID, refreshingProgress, error == nil, !characteristic.isNotifying {
                refreshingProgress = false
                peripheral.setNotifyValue(true, for: characteristic)
                return
            }
            guard error == nil, characteristic.isNotifying else { self.loss(); return }
            if characteristic.uuid == Self.inputID { inputSubscribed = true }
            if characteristic.uuid == Self.audioID { audioSubscribed = true }
            if characteristic.uuid == Self.offlineResultID { resultSubscribed = true }
            if characteristic.uuid == Self.offlineProgressID { progressSubscribed = true }
            restoreOrOfferEnrollment()
            startOfflineSync()
            pump()
        }
    }
    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { [self] in
            guard self.peripheral === peripheral else { return }
            guard error == nil, let value = characteristic.value else { self.loss(); return }
            do {
                switch characteristic.uuid {
                case Self.infoID:
                    let compatible = try RemoteInfo(value)
                    info = compatible; protectedInfoRead = true
                    if compatible.supportsOfflineSync {
                        guard let service = peripheral.services?.first(where: { $0.uuid == Self.service }),
                              let characteristics = service.characteristics,
                              let result = characteristics.first(where: { $0.uuid == Self.offlineResultID }),
                              let progress = characteristics.first(where: { $0.uuid == Self.offlineProgressID }), offlineControl != nil else { throw RemoteContractError.incompatible }
                        peripheral.setNotifyValue(true, for: result); peripheral.setNotifyValue(true, for: progress)
                    }
                    status = "Protected remote connected — enrollment pending"
                    restoreOrOfferEnrollment()
                    if let model = AppRuntime.shared?.model { synchronize(model: model) }
                    pump()
                case Self.inputID:
                    guard let info else { return }
                    let input = try RemoteInput(value, minor: info.minor)
                    let previousSequence = tracker.last?.sequence
                    let edge = try tracker.accept(input)
                    guard previousSequence != tracker.last?.sequence else { return }
                    if input.pressed || input.status & 3 != 0 || (input.event == 4 && input.capture == 2) { pauseSync(forLiveCapture: true) }
                    if input.capture == 0 { pauseSync() }
                    resumeWhenIdle()
                    if input.capture == 0 { source?.interrupt(); source = nil; disarm() }
                    if input.status & 2 != 0 { offlineStatus = "Recording offline" }
                    else if input.status & 4 != 0 { offlineStatus = "Remote storage full" }
                    else if input.status & 8 != 0 { offlineStatus = "Recordings waiting to sync" }
                    startOfflineSync()
                    let host = AppRuntime.shared
                    let actions = controls.accept(input, edge: edge,
                        recording: source != nil && (host?.model.isRecording == true || host?.recorder.recording == true))
                    if authenticatedEnrollment, let host, host.captureChoice != .phone,
                       edge || source != nil || host.captureChoice == .remote {
                        let recordingBenchmark = host.recorder.busy
                        for action in actions {
                            switch action {
                            case .stop: source?.interrupt(); host.model.stop(); host.recorder.cancel()
                            case .boundary:
                                if host.recorder.busy { source?.finish(); host.recorder.finish() }
                                else { host.model.finishUtterance() }
                            case .positions(let capture, let mode): host.model.remotePositions(capture: capture, mode: mode)
                            case .startHold:
                                if !host.recorder.busy {
                                    let factory = try host.pinnedCapture(choice: .remote)
                                    if source == nil, host.model.listening != .idle {
                                        host.model.stop()
                                        host.model.remotePositions(capture: .hold, mode: input.mode == 0 ? .dictation : .ai_control)
                                    }
                                    host.model.beginRemote(capture: factory)
                                }
                            case .startContinuous:
                                guard !recordingBenchmark else { continue }
                                let epoch = connectionEpoch, revision = tracker.controlRevision
                                let generation = host.model.captureGeneration
                                let factory = try host.pinnedCapture(choice: .remote)
                                Task { [weak self, weak host] in
                                    guard let self, let host, connectionEpoch == epoch, tracker.controlRevision == revision else { return }
                                    await host.model.awaitRemoteBoundary()
                                    guard connectionEpoch == epoch, tracker.controlRevision == revision, !host.recorder.busy else { return }
                                    host.model.beginRemote(capture: factory, generation: generation)
                                }
                            case .releaseHold(let accepted):
                                if accepted, let source { source.qualifyHold() }
                                else { source?.interrupt(); host.model.interrupt() }
                            case .cycleTarget: host.model.cycleRemoteTarget()
                            }
                        }
                    }
                    if let model = AppRuntime.shared?.model { synchronize(model: model) }
                case Self.offlineResultID:
                    guard info?.supportsOfflineSync == true, let pending = syncPending else { return }
                    if let (_, reply) = try offlineReply.accept(value, expected: pending.0) {
                        syncPending = nil; syncWrites = []; pending.1.resume(returning: reply)
                    }
                case Self.offlineProgressID:
                    guard let info, info.supportsOfflineSync else { return }
                    if let (_, snapshot) = try offlineProgressAssembly.accept(value, maximum: 46) {
                        let progress = try OfflineProgress(snapshot, minor: info.minor)
                        offlineProgress = progress
                        progressUTC = UInt64(max(0, Date().timeIntervalSince1970 * 1000))
                        if progress.status & 3 != 0 { pauseSync(forLiveCapture: true) }
                        resumeWhenIdle(); startOfflineSync()
                    }
                case Self.audioID:
                    // Audio may follow the last ATT write before its callback.
                    // Buffer through the source; AppModel cannot consume it until
                    // makeCapture's display barrier succeeds. Failed writes discard.
                    let arming = activeWrite?.state.arm == true && activeWriteControlRevision == tracker.controlRevision
                    guard authenticatedEnrollment, captureArmed || arming, tracker.last?.capture != 0 else { return }
                    if let source {
                        defer { highestSegment = max(highestSegment, source.highestSegment) }
                        if try source.receive(value) { lastAudio = .now }
                    }
                default: break
                }
            } catch {
                let message = RemoteFailurePresentation.message(for: error)
                disconnect(); status = message
            }
        }
    }
    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { [self] in
            guard self.peripheral === peripheral else { return }
            guard error == nil else { self.loss(); return }
            if characteristic.uuid == Self.offlineControlID {
                syncWriteInFlight = false; pump(); return
            }
            guard characteristic.uuid == Self.stateID else { return }
            guard let request = activeWrite else { return }
            if writes.isEmpty {
                activeWrite = nil; displayReady = true
                let current = activeWriteControlRevision == tracker.controlRevision
                activeWriteControlRevision = nil
                captureArmed = request.state.arm && authenticatedEnrollment && source != nil && current
                if request.state.arm && !current {
                    request.completion?.resume(throwing: RemoteContractError.notReady); disarm()
                } else { request.completion?.resume() }
                pump()
            } else { peripheral.writeValue(writes.removeFirst(), for: characteristic, type: .withResponse) }
        }
    }
}

@MainActor final class RemoteBLECaptureSource: CaptureSession {
    private let stream = AsyncStream<CaptureEvent>.makeStream(bufferingPolicy: .bufferingNewest(6400))
    private var hold: RemoteHoldBuffer
    private var ended = false
    private var assembler: RemoteAudioAssembler
    private var decoder: OpaquePointer?
    private var samples = 0
    private let stop: @MainActor () -> Void
    var highestSegment: UInt32 { assembler.highestSegment }
    init(maximum: Int, afterSegment: UInt32, provisional: Bool, stop: @escaping @MainActor () -> Void) throws {
        hold = RemoteHoldBuffer(provisional: provisional)
        assembler = RemoteAudioAssembler(maximum: maximum, afterSegment: afterSegment); self.stop = stop
        var error: Int32 = 0
        decoder = opus_decoder_create(16_000, 1, &error)
        guard error == OPUS_OK, decoder != nil else { throw SttFailure.unavailable }
    }
    func start() throws { guard decoder != nil else { throw SttFailure.unavailable } }
    nonisolated func events() -> AsyncStream<CaptureEvent> { stream.stream }
    nonisolated func frames() -> AsyncStream<AudioFrame> { AsyncStream { $0.finish() } }
    func receive(_ data: Data) throws -> Bool {
        switch try assembler.accept(data) {
        case .packet(let packet):
            guard let decoder else { throw SttFailure.invalidAudio }
            var pcm = [Int16](repeating: 0, count: 320)
            let count = packet.withUnsafeBytes { bytes in
                opus_decode(decoder, bytes.bindMemory(to: UInt8.self).baseAddress, Int32(packet.count), &pcm, 320, 0)
            }
            guard count == 320 else { interrupt(); throw SttFailure.invalidAudio }
            let frame = try AudioFrame(samples: pcm, timestamp: Double(samples) / 16_000); samples += 320
            for event in try hold.frame(frame) {
                if case .dropped = stream.continuation.yield(event) { interrupt(); throw SttFailure.interrupted }
            }
            return true
        case .end:
            ended = true
            if !hold.provisional { finish() }
            return true
        case .ignored: return false
        }
    }
    func qualifyHold() {
        for event in hold.qualify() {
            if case .dropped = stream.continuation.yield(event) { interrupt(); return }
        }
        if ended { finish() }
    }
    func finish() { stream.continuation.finish(); clean(); stop() }
    func interrupt() { stream.continuation.yield(.interrupted); stream.continuation.finish(); clean(); stop() }
    private func clean() { if let decoder { opus_decoder_destroy(decoder); self.decoder = nil } }
}

/// No live segment/trigger state and no concealment. Decode one validated export.
struct OfflineOpusSource: CaptureSource {
    let packets: [Data]
    func frames() -> AsyncStream<AudioFrame> { AsyncStream { $0.finish() } }
    func events() -> AsyncStream<CaptureEvent> {
        AsyncStream { output in
            let task = Task.detached {
                var error: Int32 = 0
                guard let decoder = opus_decoder_create(16_000, 1, &error), error == OPUS_OK else {
                    output.yield(.interrupted); output.finish(); return
                }
                defer { opus_decoder_destroy(decoder); output.finish() }
                var samples = 0
                for packet in packets {
                    guard !Task.isCancelled else { return }
                    var pcm = [Int16](repeating: 0, count: 320)
                    let count = packet.withUnsafeBytes { bytes in
                        opus_decode(decoder, bytes.bindMemory(to: UInt8.self).baseAddress, Int32(packet.count), &pcm, 320, 0)
                    }
                    guard count == 320, let frame = try? AudioFrame(samples: pcm, timestamp: Double(samples) / 16_000) else {
                        output.yield(.interrupted); return
                    }
                    output.yield(.frame(frame)); samples += 320
                    do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                }
            }
            output.onTermination = { _ in task.cancel() }
        }
    }
}
