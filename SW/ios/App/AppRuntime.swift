import Foundation
import Observation
import UIKit
import Speech
import AVFoundation
@preconcurrency import Network
import AppModel
import Core
import Stt
import SttApple
import Brain
import BrainApple
import Policy
import Router
import KeyboardBridge
import VoiceRemoteProtocol

@MainActor @Observable final class AppRuntime {
    private static let bootstrap = RuntimeBootstrap<AppRuntime>()
    static var shared: AppRuntime? { bootstrap.value }
    static func getOrCreate() throws -> AppRuntime { try bootstrap.resolve { try AppRuntime() } }
    let registry: DeviceRegistry
    let link: ComputerLink
    let pairing: PairingFlow
    let model: VoiceAppModel
    let historyStore: AppHistoryStore
    let offlineSync: RemoteOfflineSync
    let recorder: BenchmarkRecorder
    let remote = RemoteBLELink()
    var preparedDestination = "iPhone"
    var brainCloudInUse = false
    var permissionExplained = UserDefaults.standard.bool(forKey: "permissionExplained")
    var permissionGranted = AVAudioApplication.shared.recordPermission == .granted && SFSpeechRecognizer.authorizationStatus() == .authorized
    var error: String?
    private let apple = AppleSpeechEngine()
    private let whisper = WhisperKitEngine()
    private let keyboard: QueueWriter
    private let activity = ListeningActivity()
    private let network = NetworkStatus()
    private let taskStore: RetainedTaskStore
    let agentControl: AgentControl
    private let root: URL
    private let auditLog: AuditLog
    private var archiveSlots: [String: KeychainArchiveSlot] = [:]
    private var archiveMessage = "Audit copy unverified — pair a relay-backed computer to enable it."
    var archiveStatus: String {
        get { link.archiveRooms.isEmpty ? PhoneArchiveMaintenance.status(roomCount: 0, messages: []) : archiveMessage }
        set { archiveMessage = newValue }
    }
    var archiveBusy = false
    var pushStatus = "Push requires an owner-signed APNs profile."
    private var wakeToken: Data?
    private var wakeEnvironment: RelayWakeRegistrationEnvironment?
    private var wakeReconciliation: Task<Void, Error>?
    var acceptingRemoteControl = true
    private var sourceSelectionEpoch = UUID()
    var activeCaptureSource = "None"
    var activeSourceDisplay: String {
        model.isRecording || model.listening == .preparing || recorder.recording ? activeCaptureSource : "None"
    }
    private var preparingRecorder = false
    var captureChoice: CaptureChoice = .phone {
        didSet {
            guard oldValue != captureChoice else { return }
            sourceSelectionEpoch = UUID()
            model.stop(); recorder.cancel(); remote.selectionChanged()
        }
    }
    private var phoneMetrics = CaptureMetrics()
    private var remoteMetrics = CaptureMetrics()
    private var phoneMetricRoute: String?
    private var remoteMetricIdentity: String?
    private var remoteMetricName = "Remote"
    private var phoneRoute: String? { AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid }
    var sourceMetricsText: String {
        [phoneMetrics.quality(id: "Phone / measured route"), remoteMetrics.quality(id: remoteMetricName)].compactMap { value in
            value.map { "\($0.id): estimated envelope SNR \(Int($0.snrDB)) dB, clipping \(Int($0.clipping * 100))%, interruptions \($0.dropouts)" }
        }.joined(separator: "\n")
    }
    private let router: TaskRouter
    private var maintenance: Task<Void, Never>?
    private var preparation: Task<Void, Error>?
    private let settingsStore: SettingsStore
    private var savedSettings: AppSettings?

    init() throws {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let defaults = UserDefaults.standard
        let phoneID = defaults.string(forKey: "phoneID") ?? UUID().uuidString
        defaults.set(phoneID, forKey: "phoneID")
        // Local account until authenticated account enrollment is supplied by Pairing.
        let account = try SecureStore.fixedAccount(defaults: defaults)
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("VoiceRemote", isDirectory: true)
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var protected = root
        var resource = URLResourceValues(); resource.isExcludedFromBackup = true
        try protected.setResourceValues(resource)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group." + (Bundle.main.bundleIdentifier ?? "com.harwasch.voiceremote")) else { throw BridgeError.io }
        keyboard = QueueWriter(sharedDirectory: group)
        try keyboard.maintain(listening: false)
        settingsStore = SettingsStore(url: root.appendingPathComponent("settings.json"))
        offlineSync = try RemoteOfflineSync(url: root.appendingPathComponent("remote-offline.json"), accountID: account)
        let peers = try PeerStore(url: root.appendingPathComponent("peers-" + PayloadDigest.sha256(Data(account.utf8)) + ".json"), accountID: account)
        link = ComputerLink(accountID: account, phoneID: phoneID, store: peers)
        registry = DeviceRegistry(accountID: account, revocation: link)
        pairing = PairingFlow(backend: link)
        let history = try AppHistoryStore(url: root.appendingPathComponent("history.json"), now: Int64(Date().timeIntervalSince1970 * 1000), accountID: account)
        historyStore = history
        let auditSlot = try AuditRecoveryController.activeSlot()
        let auditCheckpoints = try AuditRecoveryController.checkpoints(root: root, slot: auditSlot)
        let audit = try AuditLog(journal: FileAuditJournal(url: AuditRecoveryController.journalURL(root: root, slot: auditSlot)),
            checkpoints: auditCheckpoints, retention: AuditRetention(), accountID: account)
        auditLog = audit
        let policy = try PolicyGate(audit: audit, biometric: LocalAuthenticationBiometric())
        taskStore = try RetainedTaskStore(url: root.appendingPathComponent("tasks.json"), accountID: account)
        router = try TaskRouter(store: taskStore, policy: policy)
        agentControl = AgentControl(router: router, policy: policy, account: account, actor: phoneID)
        guard let phrases = Bundle.main.url(forResource: "phrases", withExtension: "json") else { throw SttFailure.invalidResponse }
        recorder = try BenchmarkRecorder(prompts: RecorderPrompt.load(Data(contentsOf: phrases)), directory: root.appendingPathComponent("Recorder"))
        // Resolve self only after every stored property is initialized.
        model = VoiceAppModel(accountID: account, phoneID: phoneID, actorID: phoneID, registry: registry,
            history: history, target: link, policy: policy,
            makeCapture: { @MainActor in
                guard let host = AppRuntime.shared, host.permissionGranted else { throw SttFailure.unavailable }
                return try await host.makeRuntimeCapture()
            }, engines: { @MainActor in await AppRuntime.shared?.availableEngines() ?? [] },
            brain: { settings in
                let local = FoundationModelsBrain()
                let cloud: any LlmBrain
                if settings.cloudConsent, let client = try? AppRuntime.shared?.link.cloudClient(),
                   let url = try? client.proxyURL(provider: "anthropic"),
                   let configuration = try? ClaudeBrainConfiguration(proxyURL: url, model: settings.cloudModel, apiVersion: settings.cloudAPIVersion) {
                    cloud = IndicatingCloudBrain(backend: ClaudeBrain(configuration: configuration, transport: RelayBrainTransport(authorizer: client)))
                } else { cloud = UnavailableBrain() }
                return BrainRouter(setting: BrainSetting(rawValue: settings.brain) ?? .hybrid,
                    onDevice: local, cloud: cloud, isOnline: { await MainActor.run { AppRuntime.shared?.network.online ?? false } })
            }, online: { AppRuntime.shared?.network.online ?? false }, power: {
                let process = ProcessInfo.processInfo
                return (process.thermalState == .serious || process.thermalState == .critical, EngineRouter.lowBattery(level: UIDevice.current.batteryLevel, lowPowerMode: process.isLowPowerModeEnabled))
            }, agentControl: agentControl, deliver: { permit in
                guard let host = AppRuntime.shared else { throw RouterError.invalidAuthorization }
                try RegisteredRouting.enqueue(permit, devices: host.model.devices, router: host.router)
                return host.router.snapshot()
            })
        if let settings = try settingsStore.load() { model.settings = settings }
        else if let data = defaults.data(forKey: "settings"), let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            model.settings = settings; try settingsStore.save(settings)
        }
        savedSettings = model.settings; link.runtime = self
        model.pinCapture = { [weak self] in
            guard let self else { throw SttFailure.unavailable }
            return try pinnedCapture()
        }
        agentControl.routingDidChange = { [weak self] value in self?.model.settings.routing = value }
        agentControl.onChange = { [weak self] in Task { await self?.model.refreshTasks() } }
        model.settingsDidChange = { [weak self] settings in self?.saveSettings(settings) }
        model.onStateChange = { [weak self] in
            guard let self else { return }
            remote.synchronize(model: model)
            link.synchronizeState()
        }
        model.stateDidChange = { [weak self] listening, destination in
            guard let self else { return }
            do { try keyboard.maintain(listening: listening) } catch { self.error = "Keyboard status could not be updated." }
            activity.setListening(listening, destination: destination)
            remote.synchronize(model: model)
            link.synchronizeState()
        }
    }
    func prepare() async throws {
        if let preparation { return try await preparation.value }
        let task = Task { [self] in
            try await link.restore(registry: registry)
            await model.refresh()
            await model.refreshTasks()
            await reconcileKeyboard()
            link.reconnectAtLaunch()
        }
        preparation = task
        try await task.value
        maintenance = Task { [weak self] in
            while !Task.isCancelled {
                await self?.model.refresh()
                await self?.reconcileKeyboard()
                if let self {
                    do { try await offlineSync.maintain(); try taskStore.maintain(); try recorder.maintain(); try keyboard.maintain(listening: model.isRecording) } catch { self.error = "Private storage maintenance failed." }
                    await maintainArchive()
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
    func makeRuntimeCapture(forBenchmark: Bool = false) async throws -> any CaptureSession {
        let factory = try pinnedCapture(forBenchmark: forBenchmark)
        return try await factory()
    }
    func pinnedCapture(choice: CaptureChoice? = nil, forBenchmark: Bool = false) throws -> CaptureFactory {
        if (choice ?? captureChoice) == .automatic {
            let phone = try pinnedCapture(choice: .phone, forBenchmark: forBenchmark)
            let peer = remote.sourceIdentity, epoch = sourceSelectionEpoch, name = remote.sourceName
            let remoteFactory = remote.isEnrolled ? try pinnedCapture(choice: .remote, forBenchmark: forBenchmark) : nil
            return UtteranceCaptureSession.factory(phone: phone, remote: remoteFactory, remoteName: name,
                phoneName: { AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "iPhone microphone" },
                phoneIdentity: { AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid },
                valid: { [weak self] in self?.sourceSelectionEpoch == epoch },
                remoteValid: { [weak self] in self?.remote.sourceIdentity == peer },
                didSelect: { [weak self] in self?.activeCaptureSource = $0 })
        }
        let selected = try CaptureMetrics.select(choice: choice ?? captureChoice, remoteReady: remote.isEnrolled, phone: nil, remote: nil)
        let epoch = sourceSelectionEpoch, identity = remote.sourceIdentity, name = remote.sourceName
        let remoteFactory = selected == .remote ? remote.pinnedCapture(model: model, forBenchmark: forBenchmark) : nil
        activeCaptureSource = selected == .remote ? name : "Phone / connected headset"
        return { [weak self] in
            guard let self, permissionGranted, sourceSelectionEpoch == epoch else { throw SttFailure.unavailable }
            let meter = CaptureMetrics()
            if let remoteFactory {
                let source = try await remoteFactory()
                remoteMetricIdentity = identity; remoteMetricName = name; remoteMetrics = meter
                activeCaptureSource = name
                return MeasuredCaptureSession(source: source, metrics: meter)
            }
            phoneMetrics = meter; activeCaptureSource = "Phone / connected headset"
            return MeasuredCaptureSession(source: PhoneCapture { [weak self] in
                if forBenchmark { self?.recorder.cancel() } else { self?.model.interrupt() }
            }, metrics: meter, didStart: { [weak self] in
                guard let self else { return }; phoneMetricRoute = phoneRoute
                activeCaptureSource = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portType == .bluetoothHFP ? "AirPods / Bluetooth headset" : "iPhone microphone"
            })
        }
    }
    func maintainArchive(force: Bool = false) async {
        guard !archiveBusy else { return }; archiveBusy = true; defer { archiveBusy = false }
        let rooms = link.archiveRooms
        guard !rooms.isEmpty else { archiveStatus = PhoneArchiveMaintenance.status(roomCount: 0, messages: []); return }
        var labels: [String] = []
        for room in rooms {
            do {
                try Task.checkCancellation()
                let slot: KeychainArchiveSlot
                if let existing = archiveSlots[room] { slot = existing }
                else { slot = try KeychainArchiveSlot(root: root, account: model.accountID, room: room, create: true); archiveSlots[room] = slot }
                let client = try link.archiveClient(room: room)
                // Bounded catch-up; each exact sealed intent is durable before HTTP.
                for _ in 0..<128 {
                    let anchor = try await PhoneArchiveMaintenance.replicate(log: auditLog, client: client, cipher: slot.cipher, store: slot)
                    if anchor.journal == (try auditLog.exportCheckpoint()) { break }
                    try Task.checkCancellation()
                }
                if force { try await AuditArchive.verifyScheduled(client: client, cipher: slot.cipher, store: slot,
                    now: Int64(Date().timeIntervalSince1970 * 1000), force: true) }
                let state = try slot.loadArchive()
                let current = state.anchor.journal == (try auditLog.exportCheckpoint()) && state.pending == nil
                labels.append(state.health == .verified && current ? "Audit copy verified by read-back." : "Audit copy unverified or catching up.")
            } catch {
                let health = try? archiveSlots[room]?.loadArchive().health
                labels.append(health == .lostCopy ? "Audit read-back failed: the copy may be missing, damaged or unreachable. Local history is preserved; recovery cannot claim missing history." :
                    health == .writerMismatch ? "Audit writer refused. Fresh pairing or old-writer-signed handoff is required." :
                    "Audit copy unavailable or keys/anchors missing — retention unverified.")
            }
        }
        archiveStatus = PhoneArchiveMaintenance.status(roomCount: link.archiveRooms.count,
            messages: rooms == link.archiveRooms ? labels : ["Audit membership changed; copy unverified."])
    }
    func registeredForWake(token: Data, environment: RelayWakeRegistrationEnvironment) async {
        wakeToken = token; wakeEnvironment = environment
        await refreshWakeRegistration()
    }
    func refreshWakeRegistration() async {
        guard let wakeToken, let wakeEnvironment else { return }
        do {
            let submitted = try await link.registerWake(token: wakeToken, environment: wakeEnvironment)
            pushStatus = submitted ? "Push registration submitted on live relay connection; APNs delivery unverified." :
                "Push token received; registration waits for a live relay connection."
        }
        catch { pushStatus = "Push registration unavailable. Foreground reconciliation remains available." }
    }
    func reconcileWake() async throws {
        if let wakeReconciliation { return try await wakeReconciliation.value }
        let task = Task { [self] in
            model.stop()
            try await link.reconcileWake(); try Task.checkCancellation()
            await model.refreshTasks(); await reconcileKeyboard(); await maintainArchive()
        }
        wakeReconciliation = task
        defer { wakeReconciliation = nil }
        try await task.value
    }
    func cancelWakeReconciliation() {
        wakeReconciliation?.cancel(); link.cancelPendingWake()
    }
    func continuePermissions() async {
        permissionExplained = true; UserDefaults.standard.set(true, forKey: "permissionExplained")
        permissionGranted = await PhoneCapture.requestPermissions()
        if !permissionGranted { error = "Microphone or speech access is off. You can change it in iPhone Settings." }
    }
    func availableEngines() async -> [any SttEngine] {
        var result: [any SttEngine] = []
        if await apple.modelAvailable() { result.append(apple) }
        if await whisper.modelAvailable { result.append(whisper) }
        if let argmax = ArgmaxBuild.engine { result.append(argmax) }
        if model.settings.cloudConsent, let client = try? link.cloudClient() {
            for (vendor, provider) in [(CloudEngine.Vendor.elevenLabs, "elevenlabs"), (.assemblyAI, "assemblyai")] {
                guard let url = try? client.proxyURL(provider: provider),
                      var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { continue }
                parts.scheme = "wss"
                guard let socketURL = parts.url, let settings = try? ProxySettings(url: socketURL) else { continue }
                result.append(CloudEngine(vendor: vendor, settings: settings,
                    sockets: URLSessionSocketFactory(authorizer: client, provider: provider)))
            }
        }
        return result
    }
    func transcribeOffline(_ packets: [Data]) async throws -> String {
        let snapshot = model.settings
        let engines = await availableEngines()
        let conditions = EngineRouter.Conditions(online: network.online, hot: ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical,
            lowBattery: EngineRouter.lowBattery(level: UIDevice.current.batteryLevel, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled),
            maxAccuracy: snapshot.maxAccuracy, cloudConsent: snapshot.cloudConsent)
        var finals: [String] = []
        defer { model.endOfflineCloudIndication() }
        for await event in EngineRouter().transcribe(source: OfflineOpusSource(packets: packets), engines: engines,
            conditions: conditions, vocabulary: Vocabulary(userID: model.accountID, terms: snapshot.vocabulary), preferredID: snapshot.speechEngine, requireComplete: true) {
            try Task.checkCancellation()
            switch event {
            case .selected(let engine): model.offlineEngineSelected(isCloud: engine.isCloud)
            case .final(let text): finals.append(text)
            case .failure(let failure): throw failure
            case .partial: break
            }
        }
        let text = finals.joined(separator: " ")
        return text // Empty successful output is a per-record silent disposition in sync.
    }
    func prepareModels() async {
        do { try await apple.prepare(allowDownload: true); try await whisper.prepare(allowDownload: true) }
        catch { self.error = "Unable to prepare speech models. Check network and available storage." }
    }
    func saveSettings(_ current: AppSettings? = nil) {
        let settings = current ?? model.settings
        guard savedSettings != settings else { return }
        model.stop(); remote.cancelOfflineSync(); model.settingsChanged()
        do { try settingsStore.save(settings); savedSettings = settings }
        catch { self.error = "Settings could not be saved. Cloud processing has stopped; check storage before restarting." }
    }
    func keyboardInsertionConfirmed(_ segmentID: String) throws -> Bool {
        guard let id = UUID(uuidString: segmentID) else { return false }
        return try keyboard.insertionConfirmed(id: id)
    }
    private func reconcileKeyboard() async {
        await model.reconcileDictation(on: model.phoneID) { [self] segment in
            DictationOutcome(account_id: model.accountID, segment_id: segment, target_device_id: model.phoneID,
                outcome: try keyboardInsertionConfirmed(segment) ? .inserted : .unconfirmed)
        }
    }
    func publish(_ text: DictationText) throws {
        guard let id = UUID(uuidString: text.segment_id) else { throw BridgeError.invalidText }
        try keyboard.enqueue(CommittedSegment(id: id, createdAt: Date(), text: text.text), listening: model.isRecording)
    }
    func startRecorder() async {
        guard !recorder.busy, !preparingRecorder, recorder.prompt != nil else { return }
        preparingRecorder = true; defer { preparingRecorder = false }
        model.stop()
        guard permissionGranted else { error = "Continue with microphone permission first."; return }
        let factory: CaptureFactory
        do { factory = try pinnedCapture(forBenchmark: true) }
        catch { self.error = "Selected microphone is unavailable."; return }
        let engines = await availableEngines()
        guard let first = engines.first(where: { $0.descriptor.id == model.settings.speechEngine }) ?? engines.first,
              let second = engines.first(where: { $0.descriptor.id == model.settings.comparisonEngine && $0.descriptor.id != first.descriptor.id }) else {
            error = "Prepare and select two different speech engines first."; return
        }
        let source: any CaptureSession
        do { source = try await factory() }
        catch { self.error = "Selected capture source unavailable. Reconnect and use a fresh remote trigger."; return }
        let airpods = AVAudioSession.sharedInstance().currentRoute.inputs.contains { $0.portType == .bluetoothHFP }
        recorder.start(source: source, first: first, second: second,
            vocabulary: Vocabulary(userID: model.accountID, terms: model.settings.vocabulary),
            device: UIDevice.current.model + " / iOS " + UIDevice.current.systemVersion,
            captureKind: airpods ? .airpods : .iphone_mic, cloudConsent: model.settings.cloudConsent,
            namedSource: remote.hasCapture ? remote.sourceName : nil,
            captureMetrics: remote.hasCapture ? remoteMetrics : phoneMetrics,
            actualCaptureKind: {
                AVAudioSession.sharedInstance().currentRoute.inputs.contains { $0.portType == .bluetoothHFP } ? .airpods : .iphone_mic
            })
    }
}
private struct UnavailableBrain: LlmBrain {
    func propose(_ request: BrainRequest) async throws -> BrainResponse { throw BrainError.unavailable }
}

@MainActor private final class NetworkStatus {
    private(set) var online = false
    private let monitor = NWPathMonitor()
    init() {
        monitor.pathUpdateHandler = { @Sendable [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in self?.online = online }
        }
        monitor.start(queue: DispatchQueue(label: "VoiceRemote.Connectivity"))
    }
}

private struct IndicatingCloudBrain: LlmBrain {
    let backend: any LlmBrain
    func propose(_ request: BrainRequest) async throws -> BrainResponse {
        await MainActor.run { AppRuntime.shared?.brainCloudInUse = true }
        do {
            let result = try await backend.propose(request)
            await MainActor.run { AppRuntime.shared?.brainCloudInUse = false }
            return result
        } catch {
            await MainActor.run { AppRuntime.shared?.brainCloudInUse = false }
            throw error
        }
    }
}
