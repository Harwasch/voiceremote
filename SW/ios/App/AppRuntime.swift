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
    private let router: TaskRouter
    private var maintenance: Task<Void, Never>?
    private var preparation: Task<Void, Error>?
    private let settingsStore: SettingsStore
    private var savedSettings: AppSettings?

    init() throws {
        let defaults = UserDefaults.standard
        let phoneID = defaults.string(forKey: "phoneID") ?? UUID().uuidString
        defaults.set(phoneID, forKey: "phoneID")
        // Local account until authenticated account enrollment is supplied by Pairing.
        let account = defaults.string(forKey: "accountID") ?? "owner-local"
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("VoiceRemote", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var protected = root
        var resource = URLResourceValues(); resource.isExcludedFromBackup = true
        try protected.setResourceValues(resource)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group." + (Bundle.main.bundleIdentifier ?? "com.harwasch.voiceremote")) else { throw BridgeError.io }
        keyboard = QueueWriter(sharedDirectory: group)
        try keyboard.maintain(listening: false)
        settingsStore = SettingsStore(url: root.appendingPathComponent("settings.json"))
        offlineSync = try RemoteOfflineSync(url: root.appendingPathComponent("remote-offline.json"))
        let peers = try PeerStore(url: root.appendingPathComponent("peers-" + PayloadDigest.sha256(Data(account.utf8)) + ".json"), accountID: account)
        link = ComputerLink(accountID: account, phoneID: phoneID, store: peers)
        registry = DeviceRegistry(accountID: account, revocation: link)
        pairing = PairingFlow(backend: link)
        let history = try AppHistoryStore(url: root.appendingPathComponent("history.json"), now: Int64(Date().timeIntervalSince1970 * 1000))
        let audit = try AuditLog(journal: FileAuditJournal(url: root.appendingPathComponent("audit.jsonl")),
            checkpoints: KeychainCheckpoint(), retention: AuditRetention())
        let policy = try PolicyGate(audit: audit, biometric: LocalAuthenticationBiometric())
        router = try TaskRouter(store: FileTaskQueueStore(url: root.appendingPathComponent("tasks.json")), policy: policy)
        guard let phrases = Bundle.main.url(forResource: "phrases", withExtension: "json") else { throw SttFailure.invalidResponse }
        recorder = try BenchmarkRecorder(prompts: RecorderPrompt.load(Data(contentsOf: phrases)), directory: root.appendingPathComponent("Recorder"))
        // Resolve self only after every stored property is initialized.
        model = VoiceAppModel(accountID: account, phoneID: phoneID, actorID: phoneID, registry: registry,
            history: history, target: link, policy: policy,
            makeCapture: { @MainActor in
                guard let host = AppRuntime.shared, host.permissionGranted else { throw SttFailure.unavailable }
                if host.remote.useRemote { return try await host.remote.makeCapture(model: host.model) }
                return PhoneCapture { [weak host] in host?.model.interrupt() }
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
                return (process.thermalState == .serious || process.thermalState == .critical, process.isLowPowerModeEnabled)
            }, deliver: { permit in
                guard let host = AppRuntime.shared else { throw RouterError.invalidAuthorization }
                try RegisteredRouting.enqueue(permit, devices: host.model.devices, router: host.router)
                return host.router.snapshot()
            })
        if let settings = try settingsStore.load() { model.settings = settings }
        else if let data = defaults.data(forKey: "settings"), let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            model.settings = settings; try settingsStore.save(settings)
        }
        savedSettings = model.settings; link.runtime = self
        model.settingsDidChange = { [weak self] settings in self?.saveSettings(settings) }
        model.onStateChange = { [weak self] in
            guard let self else { return }
            remote.synchronize(model: model)
        }
        model.stateDidChange = { [weak self] listening, destination in
            guard let self else { return }
            do { try keyboard.maintain(listening: listening) } catch { self.error = "Keyboard status could not be updated." }
            activity.setListening(listening, destination: destination)
            remote.synchronize(model: model)
        }
    }
    func prepare() async throws {
        if let preparation { return try await preparation.value }
        let task = Task { [self] in
            try await link.restore(registry: registry)
            await model.refresh()
            link.reconnectAtLaunch()
        }
        preparation = task
        try await task.value
        maintenance = Task { [weak self] in
            while !Task.isCancelled {
                await self?.model.refresh()
                if let self { try? keyboard.maintain(listening: model.isRecording) }
                try? await Task.sleep(for: .seconds(60))
            }
        }
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
        let conditions = EngineRouter.Conditions(online: network.online, hot: false, lowBattery: ProcessInfo.processInfo.isLowPowerModeEnabled,
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
    func publish(_ text: DictationText) throws {
        guard let id = UUID(uuidString: text.segment_id) else { throw BridgeError.invalidText }
        try keyboard.enqueue(CommittedSegment(id: id, createdAt: Date(), text: text.text), listening: model.isRecording)
    }
    func startRecorder() async {
        model.stop()
        guard permissionGranted else { error = "Continue with microphone permission first."; return }
        let engines = await availableEngines()
        guard let first = engines.first(where: { $0.descriptor.id == model.settings.speechEngine }) ?? engines.first,
              let second = engines.first(where: { $0.descriptor.id == model.settings.comparisonEngine && $0.descriptor.id != first.descriptor.id }) else {
            error = "Prepare and select two different speech engines first."; return
        }
        let source = PhoneCapture { [weak self] in self?.recorder.cancel() }
        let airpods = AVAudioSession.sharedInstance().currentRoute.inputs.contains { $0.portType == .bluetoothHFP }
        recorder.start(source: source, first: first, second: second,
            vocabulary: Vocabulary(userID: model.accountID, terms: model.settings.vocabulary),
            device: UIDevice.current.model + " / iOS " + UIDevice.current.systemVersion,
            captureKind: airpods ? .airpods : .iphone_mic, cloudConsent: model.settings.cloudConsent,
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
