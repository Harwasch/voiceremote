import Foundation
import Observation
@preconcurrency import CoreBluetooth
import Copus
import AppModel
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
    var useRemote = false
    private(set) var status = "Disconnected"
    private(set) var discovered: [CBPeripheral] = []
    private var central: CBCentralManager!
    private var wantsScan = false
    private var peripheral: CBPeripheral?
    private var info: RemoteInfo?
    private var tracker = RemoteInputTracker()
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
    private var watchdog: Task<Void, Never>?
    private var lastAudio = ContinuousClock.now
    private var highestSegment: UInt32 = 0
    // CoreBluetooth does not expose the pairing method/MITM level to this app.
    // Remote audio stays disabled until a trusted enrollment adapter attests the
    // authenticated Numeric Comparison bond required by the draft contract.
    private var authenticatedEnrollment = false
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
        source?.interrupt(); source = nil; watchdog?.cancel(); watchdog = nil
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil; info = nil; stateCharacteristic = nil; highestSegment = 0; tracker.reset()
        failWrites(); lastPresentation = nil; displayReady = false; captureArmed = false
        authenticatedEnrollment = false; inputSubscribed = false; audioSubscribed = false
        status = "Disconnected"
    }
    func makeCapture(model: VoiceAppModel) async throws -> any CaptureSession {
        guard authenticatedEnrollment, inputSubscribed, audioSubscribed,
              let info, tracker.synchronized, let input = tracker.last, input.capture != 0 else { throw RemoteContractError.notReady }
        let capture = try RemoteBLECaptureSource(maximum: info.maxPacket, afterSegment: highestSegment, stop: { [weak self] in self?.disarm() })
        source = capture
        do {
            let state = try RemotePhoneState.presentation(controls: model.controls, devices: model.devices, phoneID: model.phoneID,
                destination: model.destination, recording: true, acknowledgedSequence: input.sequence, arm: true)
            try await writeAndWait(state)
            guard authenticatedEnrollment, tracker.last?.sequence == input.sequence, tracker.last?.capture != 0 else { throw RemoteContractError.notReady }
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
    func synchronize(model: VoiceAppModel) {
        guard peripheral != nil else { return }
        do {
            let state = try RemotePhoneState.presentation(controls: model.controls, devices: model.devices, phoneID: model.phoneID,
                destination: model.destination, recording: model.isRecording, acknowledgedSequence: tracker.last?.sequence ?? 0,
                arm: source != nil && authenticatedEnrollment && tracker.last?.capture != 0)
            enqueue(state, completion: nil)
        } catch { status = "Remote destination cannot be displayed" }
    }
    func present(model: VoiceAppModel, destination: DeviceInfo) async throws {
        guard peripheral != nil else { return }
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
        guard activeWrite == nil, !queue.isEmpty, info != nil,
              inputSubscribed, audioSubscribed,
              let peripheral, let characteristic = stateCharacteristic else { return }
        let request = queue.removeFirst()
        do {
            transaction &+= 1
            let budget = RemotePhoneState.writeBudget(osMaximum: peripheral.maximumWriteValueLength(for: .withResponse))
            var nextTracker = tracker
            writes = try nextTracker.stateForWrite(request.state).fragments(transaction: transaction, budget: budget)
            tracker = nextTracker
            activeWrite = request; displayReady = false
            peripheral.writeValue(writes.removeFirst(), for: characteristic, type: .withResponse)
        } catch { request.completion?.resume(throwing: error); pump() }
    }
    private func failWrites() {
        activeWrite?.completion?.resume(throwing: RemoteContractError.notReady)
        for request in queue { request.completion?.resume(throwing: RemoteContractError.notReady) }
        activeWrite = nil; queue = []; writes = []
    }
    private func disarm() {
        captureArmed = false
        watchdog?.cancel(); watchdog = nil
        guard var state = lastPresentation else { return }
        state.recording = 0; state.arm = false; state.requestSnapshot = true
        state.acknowledgedSequence = tracker.last?.sequence ?? 0
        enqueue(state, completion: nil)
    }
    private func loss() {
        disconnect()
        status = "Interrupted — reconnect and use a fresh trigger"
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
            peripheral.discoverCharacteristics([Self.infoID, Self.inputID, Self.stateID, Self.audioID], for: service)
        }
    }
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated { [self] in
            guard self.peripheral === peripheral else { return }
            guard error == nil, let characteristics = service.characteristics, characteristics.count == 4 else { self.loss(); return }
            for characteristic in characteristics {
                switch characteristic.uuid {
                case Self.infoID: peripheral.readValue(for: characteristic)
                case Self.inputID, Self.audioID: peripheral.setNotifyValue(true, for: characteristic)
                case Self.stateID: stateCharacteristic = characteristic; pump()
                default: break
                }
            }
        }
    }
    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { [self] in
            guard self.peripheral === peripheral else { return }
            guard error == nil, characteristic.isNotifying else { self.loss(); return }
            if characteristic.uuid == Self.inputID { inputSubscribed = true }
            if characteristic.uuid == Self.audioID { audioSubscribed = true }
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
                    info = try RemoteInfo(value)
                    status = "Connected — authenticated enrollment unverified; audio disabled"
                    if let model = AppRuntime.shared?.model { synchronize(model: model) }
                    pump()
                case Self.inputID:
                    let input = try RemoteInput(value)
                    let edge = try tracker.accept(input)
                    if input.capture == 0 { source?.interrupt(); source = nil; disarm() }
                    // Snapshots never start capture, cycle targets or mint authority.
                    if edge, authenticatedEnrollment { status = "Remote control received" }
                    if let model = AppRuntime.shared?.model { synchronize(model: model) }
                case Self.audioID:
                    guard authenticatedEnrollment, captureArmed, tracker.last?.capture != 0 else { return }
                    if let source {
                        defer { highestSegment = max(highestSegment, source.highestSegment) }
                        if try source.receive(value) { lastAudio = .now }
                    }
                default: break
                }
            } catch { loss() }
        }
    }
    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { [self] in
            guard self.peripheral === peripheral else { return }
            guard error == nil, characteristic.uuid == Self.stateID else { self.loss(); return }
            guard let request = activeWrite else { return }
            if writes.isEmpty {
                activeWrite = nil; displayReady = true
                captureArmed = request.state.arm && authenticatedEnrollment && source != nil && request.state.acknowledgedSequence == tracker.last?.sequence
                if request.state.arm && request.state.acknowledgedSequence != tracker.last?.sequence {
                    request.completion?.resume(throwing: RemoteContractError.notReady); disarm()
                } else { request.completion?.resume() }
                pump()
            } else { peripheral.writeValue(writes.removeFirst(), for: characteristic, type: .withResponse) }
        }
    }
}

@MainActor final class RemoteBLECaptureSource: CaptureSession {
    private let stream = AsyncStream<CaptureEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
    private var assembler: RemoteAudioAssembler
    private var decoder: OpaquePointer?
    private var samples = 0
    private let stop: @MainActor () -> Void
    var highestSegment: UInt32 { assembler.highestSegment }
    init(maximum: Int, afterSegment: UInt32, stop: @escaping @MainActor () -> Void) throws {
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
            if case .dropped = stream.continuation.yield(.frame(frame)) { interrupt(); throw SttFailure.interrupted }
            return true
        case .end: finish(); return true
        case .ignored: return false
        }
    }
    func finish() { stream.continuation.finish(); clean(); stop() }
    func interrupt() { stream.continuation.yield(.interrupted); stream.continuation.finish(); clean(); stop() }
    private func clean() { if let decoder { opus_decoder_destroy(decoder); self.decoder = nil } }
}
