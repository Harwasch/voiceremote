import Foundation
#if canImport(Darwin)
import Observation
#endif
import Core
import Stt
import Brain
import Policy
import TrustedInput
import Router
import Pairing
import KeyboardBridge
import VoiceRemoteProtocol

/// One new source per utterance. Apple adapters stop hardware synchronously on MainActor.
@MainActor public protocol CaptureSession: CaptureSource {
    func start() throws
    func finish()
    func interrupt()
}
public enum ListeningState: String, Sendable { case idle, preparing, listening, finishing, interrupted, failed }

public struct AppSettings: Codable, Equatable, Sendable {
    public var speechEngine = "automatic"
    public var comparisonEngine = "whisperkit"
    public var compare = false
    public var brain = BrainSetting.hybrid.rawValue
    public var cloudConsent = false
    public var maxAccuracy = false
    public var vocabulary: [String] = []
    public var cloudModel = "claude-opus-5-5"
    public var cloudAPIVersion = "2026-10-21"
    public var relayURL = ""
    public var speechProxyURL = ""
    public var brainProxyURL = ""
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case speechEngine, comparisonEngine, compare, brain, cloudConsent, maxAccuracy, vocabulary
        case relayURL, speechProxyURL, brainProxyURL, cloudModel, cloudAPIVersion
    }
    public init(from decoder: any Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        speechEngine = try c.decodeIfPresent(String.self, forKey: .speechEngine) ?? speechEngine
        comparisonEngine = try c.decodeIfPresent(String.self, forKey: .comparisonEngine) ?? comparisonEngine
        compare = try c.decodeIfPresent(Bool.self, forKey: .compare) ?? compare
        brain = try c.decodeIfPresent(String.self, forKey: .brain) ?? brain
        cloudConsent = try c.decodeIfPresent(Bool.self, forKey: .cloudConsent) ?? cloudConsent
        maxAccuracy = try c.decodeIfPresent(Bool.self, forKey: .maxAccuracy) ?? maxAccuracy
        vocabulary = try c.decodeIfPresent([String].self, forKey: .vocabulary) ?? vocabulary
        relayURL = try c.decodeIfPresent(String.self, forKey: .relayURL) ?? relayURL
        speechProxyURL = try c.decodeIfPresent(String.self, forKey: .speechProxyURL) ?? speechProxyURL
        brainProxyURL = try c.decodeIfPresent(String.self, forKey: .brainProxyURL) ?? brainProxyURL
        cloudModel = try c.decodeIfPresent(String.self, forKey: .cloudModel) ?? cloudModel
        cloudAPIVersion = try c.decodeIfPresent(String.self, forKey: .cloudAPIVersion) ?? cloudAPIVersion
    }
}

public struct ApprovalCard: Identifiable, Sendable {
    public var id: UUID { preview.requestID }
    public let preview: Preview
    public let destination: DeviceInfo
    public let session: InputSession
    public var exactAction: String {
        switch preview.tool {
        case .selectTargetTool(let tool): "Select destination: " + tool.device_id
        case .openResourceTool(let tool): "Open resource: " + tool.resource_uri
        case .delegateTaskTool(let tool): "Agent instruction: " + tool.instruction + "\nProject: " + tool.project_id + "\nSession: " + (tool.provider_session_id ?? "Default")
        case .cancelTaskTool(let tool): "Cancel task: " + tool.command_id
        case .prepareSendTool(let tool): "Prepare for: " + tool.recipient + "\nExact content: " + tool.content
        }
    }
    public var consequences: String {
        switch preview.tool {
        case .prepareSendTool: "Prepares the shown content for the shown recipient. Sending requires a separate supported executor."
        case .delegateTaskTool: "The selected agent will receive the exact instruction and may modify its workspace within its own permissions."
        case .openResourceTool: "Opens the exact resource on this device."
        case .selectTargetTool: "Changes the destination for future text."
        case .cancelTaskTool: "Requests cancellation of the exact task. Completed effects may remain."
        }
    }
}

/// Composition root for portable behavior. Model bytes never enter PhoneInput APIs.
#if canImport(Darwin)
@Observable
#endif
@MainActor public final class VoiceAppModel {
    public private(set) var controls = AppState() { didSet { onStateChange?() } }
    public private(set) var listening: ListeningState = .idle { didSet { onStateChange?() } }
    public private(set) var destination: DeviceInfo? { didSet { onStateChange?() } }
    public private(set) var partial = "" { didSet { onStateChange?() } }
    public private(set) var cloudInUse = false { didSet { onStateChange?() } }
    public private(set) var message: String? { didSet { onStateChange?() } }
    public private(set) var devices: [DeviceInfo] = [] { didSet { onStateChange?() } }
    public private(set) var offlineOrigins: [String: OfflineTextOrigin] = [:]
    public private(set) var deliveryStates: [String: TextDeliveryState] = [:]
    public private(set) var history: [HistoryEntry] = [] { didSet { onStateChange?() } }
    public private(set) var suggestions: [SuggestionCard] = [] { didSet { onStateChange?() } }
    public private(set) var approval: ApprovalCard? { didSet { onStateChange?() } }
    public private(set) var tasks: [QueuedTask] = [] { didSet { onStateChange?() } }
    public private(set) var muted = false { didSet { onStateChange?() } }
    public var settings = AppSettings() { didSet { settingsDidChange?(settings); onStateChange?() } }
    public var settingsDidChange: (@MainActor (AppSettings) -> Void)?
    /// Portable observation hook, also available without the Apple Observation macro.
    public var onStateChange: (@MainActor () -> Void)?
    public var stateDidChange: (@MainActor (Bool, String) -> Void)?
    public var isRecording: Bool { listening == .listening }
    public var canRetryQueue: Bool { approval.map { pendingPermits[$0.id] != nil } ?? false }
    public let accountID: String
    public let phoneID: String
    private let registry: DeviceRegistry
    private let historyStore: AppHistoryStore
    private let pipeline: HeldDictationPipeline
    private var picker: TargetPicker
    private let policy: PolicyGate
    private let input: PhoneInput
    private let actorID: String
    private let makeCapture: @MainActor () async throws -> any CaptureSession
    private let engines: @MainActor () async -> [any SttEngine]
    private let brain: @MainActor (AppSettings) -> any LlmBrain
    private let deliver: @MainActor (ExecutionPermit) throws -> [QueuedTask]
    private let now: @MainActor () -> Int64
    private let online: @MainActor () -> Bool
    private let power: @MainActor () -> (hot: Bool, lowBattery: Bool)
    private var capture: (any CaptureSession)?
    private var worker: Task<Void, Never>?
    private var epoch = UUID()
    private var trigger = CaptureTrigger()
    private var suggestionEngine: SuggestionEngine?
    private var pendingPermits: [UUID: ExecutionPermit] = [:]
    private var suggestionTargets: [UUID: DeviceInfo] = [:]

    public init(accountID: String, phoneID: String, actorID: String, registry: DeviceRegistry,
                history: AppHistoryStore, target: any DictationTarget, policy: PolicyGate,
                makeCapture: @escaping @MainActor () async throws -> any CaptureSession,
                engines: @escaping @MainActor () async -> [any SttEngine],
                brain: @escaping @MainActor (AppSettings) -> any LlmBrain,
                online: @escaping @MainActor () -> Bool = { true },
                power: @escaping @MainActor () -> (hot: Bool, lowBattery: Bool) = { (false, false) },
                now: @escaping @MainActor () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
                deliver: @escaping @MainActor (ExecutionPermit) throws -> [QueuedTask]) {
        self.accountID = accountID; self.phoneID = phoneID; self.actorID = actorID
        self.registry = registry; historyStore = history; self.policy = policy
        pipeline = HeldDictationPipeline(history: history, target: target, registry: registry, accountID: accountID, phoneID: phoneID)
        picker = TargetPicker(accountID: accountID, phoneID: phoneID)
        input = PhoneInput(now: now); self.now = now; self.makeCapture = makeCapture
        self.engines = engines; self.brain = brain; self.online = online; self.power = power; self.deliver = deliver
    }
    public func refresh() async {
        devices = await registry.all()
        do { history = try await historyStore.entries(now: now()); deliveryStates = await historyStore.deliveryStates(); offlineOrigins = await historyStore.offlineOrigins() }
        catch { message = "History is unavailable." }
    }
    public func clearFocus(_ deviceID: String) { picker.clear(deviceID) }
    public func updateFocus(_ report: FocusReport) throws { try picker.update(report) }
    public func setTarget(_ selection: TargetSelection) {
        stop(); controls.setTarget(selection); picker.selection = selection
        destination = try? picker.resolve(devices: devices)
        suggestionEngine = nil; suggestions = []; suggestionTargets = [:]
    }
    public func setMode(_ mode: Mode) {
        let previousCapture = controls.capture
        stop(); controls.setMode(mode); controls.setCapture(previousCapture)
        if previousCapture == .continuous { begin() }
    }
    public func setCapture(_ value: CaptureState) {
        stop(); controls.setCapture(value)
        if value == .continuous { begin() }
    }
    public func press(at milliseconds: Int64) {
        guard controls.capture != .off else { return }
        trigger.press(at: milliseconds)
    }
    public func advanceTrigger(to milliseconds: Int64) {
        trigger.advance(to: milliseconds)
        if trigger.capture == .hold && listening != .listening && listening != .preparing { begin() }
    }
    public func release(at milliseconds: Int64) {
        guard controls.capture != .off else { return }
        trigger.release(at: milliseconds)
        if trigger.capture == .continuous {
            controls.setCapture(.continuous)
            if listening != .listening && listening != .preparing { begin() }
        } else if controls.capture != .continuous { finishUtterance() }
    }
    /// Immediate hardware stop, including while permission/target/engine setup awaits.
    /// Cancelled utterances cannot commit late text or late proposals.
    public func stop() {
        epoch = UUID(); trigger.stop(); controls.setCapture(.off)
        capture?.interrupt(); capture = nil; worker?.cancel(); worker = nil
        partial = ""; cloudInUse = false; listening = .idle
        stateDidChange?(false, destination?.display_name ?? "iPhone")
    }
    /// Called when SwiftUI resets a cancelled gesture or HOLD leaves foreground.
    public func cancelGesture() {
        let selection = controls.capture
        stop()
        if selection == .hold { controls.setCapture(.hold) }
    }
    public func leaveForeground() {
        if controls.capture == .hold { cancelGesture() }
    }
    public func interrupt() {
        stop(); listening = .interrupted; message = "Recording interrupted. Start again when ready."
    }
    /// Deliberate EOS (PTT release/recorder stop), distinct from emergency Stop.
    public func finishUtterance() {
        guard listening == .listening else {
            if listening == .preparing { stop() }
            return
        }
        listening = .finishing; capture?.finish()
        stateDidChange?(false, destination?.display_name ?? "iPhone")
    }
    public func begin() {
        guard controls.capture != .off, worker == nil else { return }
        let token = UUID(); epoch = token
        let segmentID = UUID().uuidString, state = controls, snapshot = settings
        listening = .preparing; partial = ""; message = nil
        worker = Task {
            do {
                var selected: DeviceInfo
                if state.mode == .dictation {
                    selected = try await pipeline.prepare(segmentID: segmentID, state: state, picker: picker, now: now())
                } else { selected = try picker.resolve(devices: await registry.all()) }
                guard epoch == token, !Task.isCancelled else { await pipeline.cancel(segmentID: segmentID); return }
                destination = selected // Before source construction or first text.
                stateDidChange?(false, selected.display_name)
                await Task.yield() // Allow destination observers to present before capture starts.
                var available = await engines()
                guard epoch == token, !Task.isCancelled else { await pipeline.cancel(segmentID: segmentID); return }
                let source = try await makeCapture()
                guard epoch == token, !Task.isCancelled else { source.interrupt(); await pipeline.cancel(segmentID: segmentID); return }
                capture = source
                var conditions = EngineRouter.Conditions(online: online(), hot: power().hot, lowBattery: power().lowBattery,
                    maxAccuracy: snapshot.maxAccuracy, cloudConsent: snapshot.cloudConsent)
                guard case .engine = EngineRouter().select(onDevice: available.map(\.descriptor), cloud: available.map(\.descriptor),
                    conditions: conditions, preferredID: snapshot.speechEngine) else {
                    source.interrupt(); await pipeline.cancel(segmentID: segmentID)
                    capture = nil; trigger.stop(); listening = .idle; worker = nil; return
                }
                try source.start(); listening = .listening
                stateDidChange?(true, selected.display_name)
                var failed = false
                var currentSegment = segmentID
                let slices = CaptureSegmenter().slices(from: source)
                var firstSlice = true
                for await slice in slices {
                    guard epoch == token, !Task.isCancelled else { break }
                    if !firstSlice {
                        available = await engines()
                        conditions = EngineRouter.Conditions(online: online(), hot: power().hot, lowBattery: power().lowBattery,
                            maxAccuracy: snapshot.maxAccuracy, cloudConsent: snapshot.cloudConsent)
                        currentSegment = UUID().uuidString
                        if state.mode == .dictation {
                            selected = try await pipeline.prepare(segmentID: currentSegment, state: state, picker: picker, now: now())
                        } else { selected = try picker.resolve(devices: await registry.all()) }
                        guard epoch == token, !Task.isCancelled else { await pipeline.cancel(segmentID: currentSegment); return }
                        if destination?.device_id != selected.device_id {
                            suggestionEngine = nil; suggestions = []; suggestionTargets = [:]
                        }
                        destination = selected
                        stateDidChange?(isRecording, selected.display_name)
                    }
                    firstSlice = false
                    var finals: [String] = []
                    for await event in EngineRouter().transcribe(source: slice, engines: available, conditions: conditions,
                        vocabulary: Vocabulary(userID: accountID, terms: snapshot.vocabulary), preferredID: snapshot.speechEngine) {
                        guard epoch == token, !Task.isCancelled else { break }
                        switch event {
                        case .selected(let engine): cloudInUse = engine.isCloud
                        case .partial(let text): partial = text
                        case .final(let text): finals.append(text)
                        case .failure(let error): failed = true; message = error == .interrupted ? "Recording interrupted. Start again." : "Speech recognition unavailable."
                        }
                    }
                    guard epoch == token, !Task.isCancelled else { await pipeline.cancel(segmentID: currentSegment); return }
                    if !failed, !finals.isEmpty {
                        let text = finals.joined(separator: " ")
                        if state.mode == .dictation {
                            try await pipeline.commit(segmentID: currentSegment, revision: 0, text: text, now: now())
                        } else {
                            // Brain work is independent of the capture producer; it cannot
                            // authorize or stop capture. Bounded slice buffering fails closed.
                            try await propose(text, segmentID: UUID().uuidString, selected: selected, token: token, settings: snapshot)
                        }
                        await refresh()
                        guard epoch == token, !Task.isCancelled else { return }
                        partial = ""
                    } else { await pipeline.cancel(segmentID: currentSegment) }
                    if failed { break }
                }
                await pipeline.cancel(segmentID: currentSegment)
                guard epoch == token, !Task.isCancelled else { return }
                source.finish(); capture = nil
                await refresh()
                guard epoch == token, !Task.isCancelled else { return }
                partial = ""; cloudInUse = false
                trigger.stop()
                listening = failed ? .interrupted : .idle; worker = nil
                stateDidChange?(false, selected.display_name)
            } catch {
                await pipeline.cancel(segmentID: segmentID)
                guard epoch == token else { return }
                capture?.interrupt(); capture = nil; worker = nil; trigger.stop()
                listening = .failed; partial = ""; cloudInUse = false
                message = "Unable to record or deliver text. Check permissions, speech model and destination."
                stateDidChange?(false, destination?.display_name ?? "iPhone")
            }
        }
    }
    private func propose(_ text: String, segmentID: String, selected: DeviceInfo, token: UUID, settings: AppSettings) async throws {
        if suggestionEngine == nil {
            suggestionEngine = SuggestionEngine(brain: brain(settings), accountID: accountID,
                context: "Selected destination: \(selected.device_id). Registered destinations: " +
                    (devices + [picker.phone]).map { "\($0.device_id): \($0.display_name) [\($0.role.rawValue)]" }.joined(separator: "; "), configuration: try SuggestionConfiguration())
        }
        guard let engine = suggestionEngine else { return }
        await engine.setMutedDuringMeeting(muted)
        let update = await engine.ingest(TranscriptSegment(id: segmentID, revision: 0, text: text,
            isFinal: true, isComplete: true, contextID: selected.device_id), now: Date(timeIntervalSince1970: Double(now()) / 1000))
        guard epoch == token else { return }
        suggestions = update.cards
        for card in suggestions where suggestionTargets[card.id] == nil {
            let proposedID: String
            switch card.proposal.tool {
            case .selectTargetTool(let tool): proposedID = tool.device_id
            case .openResourceTool(let tool): proposedID = tool.device_id
            case .delegateTaskTool(let tool): proposedID = tool.device_id
            case .prepareSendTool(let tool): proposedID = tool.device_id
            case .cancelTaskTool: proposedID = selected.device_id
            }
            // Untrusted destination hints resolve only through the trusted registry.
            suggestionTargets[card.id] = (devices + [picker.phone]).first { $0.device_id == proposedID && $0.account_id == accountID }
        }
        if let notice = update.routingNotice { cloudInUse = notice == .cloud }
        if update.failure != nil { message = "Brain unavailable. No action was started." }
    }
    public func muteSuggestions(_ value: Bool) async {
        muted = value; await suggestionEngine?.setMutedDuringMeeting(value)
        suggestions = await suggestionEngine?.cards(now: Date(timeIntervalSince1970: Double(now()) / 1000)) ?? []
    }
    /// Start opens a Policy review; it cannot directly invoke an executor.
    public func review(_ card: SuggestionCard) async {
        guard !muted, let engine = suggestionEngine, let selected = suggestionTargets[card.id],
              let tapped = await engine.tap(SuggestionTap(cardID: card.id, previewRevision: card.revision),
                now: Date(timeIntervalSince1970: Double(now()) / 1000)) else { return }
        guard !muted, suggestionTargets[card.id]?.device_id == selected.device_id else { return }
        if case .selectTargetTool = tapped.proposal.tool, !selected.capabilities.contains(.receive_text) {
            message = "This destination cannot receive text."; return
        }
        let session = input.session(account: accountID, actor: actorID, session: UUID().uuidString,
            device: selected.device_id, project: "default", destinationKind: .software)
        let activation = input.activation(session: session, kind: .inferred, expiresAt: now() + 120_000)
        do {
            let decision = policy.submit(try ProtocolCodec.encode(tapped.proposal.tool), input: activation)
            switch decision {
            case .suggestion(let preview), .authenticationRequired(let preview):
                approval = ApprovalCard(preview: preview, destination: selected, session: session)
            default: message = "Action is unavailable for this destination."
            }
        } catch { message = "Invalid action. Nothing was started." }
        suggestions = await engine.cards(now: Date(timeIntervalSince1970: Double(now()) / 1000))
    }
    public func approve(source: ApprovalSource = .phone) async {
        guard let card = approval else { return }
        // Draft BLE has no authenticated approval mechanism, at any tier.
        guard source == .phone else { message = "Approve on your iPhone."; return }
        if let permit = pendingPermits[card.id] {
            do {
                _ = try policy.verifyExecution(command: permit.command, immutablePreview: permit.immutablePreview, expiresAt: permit.expiresAt)
                try queue(permit, card: card)
            } catch { message = "Queue confirmation failed. Check task status before retrying or denying." }
            return
        }
        let decision = await policy.approve(requestID: card.id, evidence: input.approval(session: card.session,
            requestID: card.id, payloadHash: card.preview.payloadHash, source: source))
        guard approval?.id == card.id else { return }
        switch decision {
        case .queued(let permit):
            if case .selectTargetTool(let tool) = permit.command.immutable_task_payload {
                guard policy.transition(requestID: card.id, to: .dispatched) else { return }
                setTarget(.device(tool.device_id))
                _ = policy.transition(requestID: card.id, to: .running)
                _ = policy.transition(requestID: card.id, to: .succeeded)
                approval = nil; message = "Destination changed to " + (destination?.display_name ?? tool.device_id)
                return
            }
            pendingPermits[card.id] = permit
            do { try queue(permit, card: card) }
            catch { message = "Queue confirmation failed. Check task status before retrying or denying." }
        case .denied: message = "Approval denied or expired. Nothing was started."
        default: message = "Action needs review."
        }
    }
    private func queue(_ permit: ExecutionPermit, card: ApprovalCard) throws {
        tasks = try deliver(permit)
        pendingPermits.removeValue(forKey: card.id); approval = nil
    }
    public func dismissApproval() {
        if let approval {
            let next: ProposalState = pendingPermits.removeValue(forKey: approval.id) == nil ? .dismissed : .cancelled
            _ = policy.transition(requestID: approval.id, to: next)
        }
        approval = nil
    }
    public func editTarget(_ card: SuggestionCard, device: DeviceInfo) async {
        guard devices.contains(where: { $0.device_id == device.device_id }), let engine = suggestionEngine else { return }
        do {
            let data = try ProtocolCodec.encode(card.proposal.tool)
            guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            object["device_id"] = device.device_id
            let result = ProposalDecoder.decode(try JSONSerialization.data(withJSONObject: [object]), accountID: accountID)
            guard let proposal = result.proposals.first else { return }
            if await engine.edit(cardID: card.id, proposal: proposal, now: Date(timeIntervalSince1970: Double(now()) / 1000)) != nil {
                suggestionTargets[card.id] = device
                suggestions = await engine.cards(now: Date(timeIntervalSince1970: Double(now()) / 1000))
            }
        } catch { message = "Unable to edit destination." }
    }
    public func dismiss(_ card: SuggestionCard) async {
        await suggestionEngine?.dismiss(cardID: card.id, now: Date(timeIntervalSince1970: Double(now()) / 1000))
        suggestions.removeAll { $0.id == card.id }
    }
    private var captureRequests: [UUID: Set<String>] = [:]
    private var captureSequences: [UUID: Int64] = [:]
    /// Authenticated remote control is stop-only. Sequence and absolute expiry
    /// reject stale frames; a monotonic receipt deadline also bounds processing.
    /// Clock disagreement fails closed rather than extending the sender deadline.
    public func captureControl(_ request: CaptureControl, connectionID: UUID,
        receivedAt: ContinuousClock.Instant = .now) async -> CaptureControlResult {
        func result(_ outcome: CaptureControlResultOutcome) -> CaptureControlResult {
            CaptureControlResult(account_id: accountID, request_id: request.request_id,
                device_id: phoneID, capture_state: controls.capture, outcome: outcome)
        }
        guard request.account_id == accountID, request.target_device_id == phoneID,
              (try? ProtocolCodec.encode(request)) != nil else { return result(.unavailable) }
        guard request.request_sequence > captureSequences[connectionID, default: -1] else { return result(.cancelled) }
        guard captureRequests[connectionID, default: []].count < 256, captureRequests.count < 5 else { return result(.unavailable) }
        captureSequences[connectionID] = request.request_sequence
        guard captureRequests[connectionID, default: []].insert(request.request_id).inserted else { return result(.cancelled) }
        let remaining = request.expires_at - now()
        guard remaining > 0, remaining <= request.ttl_ms,
              ContinuousClock.now < receivedAt + .milliseconds(request.ttl_ms) else { return result(.expired) }
        // Paired computers have no authority to activate the phone microphone.
        // Refuse starts in every lifecycle/lock/mode state. A user can start
        // capture using the phone's own controls; remote requests only stop.
        guard request.capture_state == .off else { return result(.unavailable) }
        stop()
        return result(.applied)
    }
    public func forgetCaptureConnection(_ id: UUID) {
        captureRequests.removeValue(forKey: id); captureSequences.removeValue(forKey: id)
    }
    public func dictationOutcome(_ outcome: DictationOutcome, from deviceID: String) async {
        do { try await historyStore.dictationOutcome(outcome, from: deviceID, accountID: accountID); await refresh() }
        catch { message = "Delivery outcome could not be saved. Check the computer before resending." }
    }
    public func reconcileDictation(on deviceID: String, query: (String) async throws -> DictationOutcome) async {
        guard let entries = try? await historyStore.entries(now: now()) else { return }
        let states = await historyStore.deliveryStates()
        for entry in entries where entry.targetID == deviceID && states[entry.segmentID] == .unconfirmed {
            do { await dictationOutcome(try await query(entry.segmentID), from: deviceID) }
            catch { return } // Reconnection only queries; held text still requires a tap.
        }
    }
    public func insertionStatus(_ status: TaskStatus, from deviceID: String) async {
        do { try await historyStore.insertionStatus(status, from: deviceID, accountID: accountID); await refresh() }
        catch { message = "Insertion status could not be saved. Check the computer before resending." }
    }
    public func sendHeld(_ id: String) async {
        do { try await pipeline.sendHeld(id: id, now: now()) }
        catch { message = "Text remains held. Check the destination before trying again." }
        await refresh()
    }
    /// Deferred remote text is history only, independent of mode/brain/target selection.
    public func saveOfflineText(id: String, text: String, origin: OfflineTextOrigin? = nil) async throws {
        let clean = DictationPipeline.sanitize(text)
        guard !clean.isEmpty else { throw SttFailure.invalidResponse }
        try await historyStore.saveText(HistoryEntry(segmentID: id, targetID: phoneID, text: clean, createdAt: now()), state: .offline, now: now(), origin: origin)
        await refresh()
    }
    public func deleteHistory(_ id: String) async {
        do { try await historyStore.delete(id: id, now: now()); await refresh() }
        catch { message = "Unable to delete history." }
    }
    public func revoke(_ id: String) async {
        stop(); dismissApproval()
        let removed = Set(suggestionTargets.filter { $0.value.device_id == id }.map(\.key))
        suggestions.removeAll { removed.contains($0.id) }
        for cardID in removed { suggestionTargets.removeValue(forKey: cardID) }
        do { try await registry.revoke(id) } catch { message = "Device removed locally. Desktop notification or credential cleanup failed; check the computer." }
        await refresh()
    }
    public func offlineEngineSelected(isCloud: Bool) { cloudInUse = isCloud }
    public func endOfflineCloudIndication() { cloudInUse = false }
    public func settingsChanged() { suggestionEngine = nil; suggestions = []; suggestionTargets = [:] }
}
