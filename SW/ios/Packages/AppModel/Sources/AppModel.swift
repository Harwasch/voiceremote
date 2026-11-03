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
public typealias CaptureFactory = @MainActor () async throws -> any CaptureSession
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
    public var routing = AgentRoutingSettings()
    public var cloudAPIVersion = "2026-10-21"
    public var relayURL = ""
    public var speechProxyURL = ""
    public var brainProxyURL = ""
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case routing, speechEngine, comparisonEngine, compare, brain, cloudConsent, maxAccuracy, vocabulary
        case relayURL, speechProxyURL, brainProxyURL, cloudModel, cloudAPIVersion
    }
    public init(from decoder: any Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        routing = try c.decodeIfPresent(AgentRoutingSettings.self, forKey: .routing) ?? routing
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
    public var route: Destination? = nil
    public var routingRules: RoutingRules? = nil
    public var routeDescription: String? {
        guard let route else { return nil }
        return (route.available ? "Connected\n" : "Offline — this task will wait\n") + "\(route.session.provider) / \(route.session.host) / \(route.session.workspace) / \(route.session.providerSessionID) / \(route.session.capabilityProfile)\n" + (route.session.executionWorkspace ?? "")
    }
    public var suggestionID: UUID? = nil
    public var suggestionRevision: Int = 0
    public var dependencies: [String] = []
    public var replacingCommandID: String? = nil
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

public struct TaskCompletionCard: Identifiable, Sendable {
    public let id: UUID
    public let task: QueuedTask
    public let connectionEpoch: UUID
    public let operationHash: String
    public var instruction: String {
        switch task.command.immutable_task_payload {
        case .delegateTaskTool(let tool): tool.instruction
        case .openResourceTool(let tool): tool.resource_uri
        default: "Unsupported operation"
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
    public private(set) var completion: TaskCompletionCard? { didSet { onStateChange?() } }
    public private(set) var tasks: [QueuedTask] = [] { didSet { onStateChange?() } }
    public private(set) var muted = false { didSet { onStateChange?() } }
    public var settings = AppSettings() { didSet { agentControl?.configureRouting(settings.routing); settingsDidChange?(settings); onStateChange?() } }
    public var settingsDidChange: (@MainActor (AppSettings) -> Void)?
    /// Portable observation hook, also available without the Apple Observation macro.
    public var onStateChange: (@MainActor () -> Void)?
    public var stateDidChange: (@MainActor (Bool, String) -> Void)?
    /// Called synchronously at the trigger, before target/model setup can suspend.
    public var pinCapture: (@MainActor () throws -> CaptureFactory)?
    public var isRecording: Bool { listening == .listening }
    public var canRetryQueue: Bool { approval.map { pendingPermits[$0.id] != nil } ?? false }
    public let accountID: String
    public let phoneID: String
    public let agentControl: AgentControl?
    public private(set) var grants: [GrantEvidence] = []
    public var wakeArmed = false
    private var armedTargetScope: InputSession?
    private var localPTT = false
    private var pressedCapture: CaptureFactory?
    private var authorizedSuggestions: [UUID: String] = [:]
    private var taskSuggestions: [String: UUID] = [:]
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
    public var captureGeneration: UUID { epoch }
    private var trigger = CaptureTrigger()
    private var suggestionEngine: SuggestionEngine?
    private var pendingPermits: [UUID: ExecutionPermit] = [:]
    private var segmentTexts: [String: String] = [:]
    private var suggestionSegments: [UUID: String] = [:]
    private var suggestionConstraints: [UUID: RoutingRules] = [:]
    private var suggestionTexts: [UUID: String] = [:]
    private var suggestionTargets: [UUID: DeviceInfo] = [:]

    public init(accountID: String, phoneID: String, actorID: String, registry: DeviceRegistry,
                history: AppHistoryStore, target: any DictationTarget, policy: PolicyGate,
                makeCapture: @escaping @MainActor () async throws -> any CaptureSession,
                engines: @escaping @MainActor () async -> [any SttEngine],
                brain: @escaping @MainActor (AppSettings) -> any LlmBrain,
                online: @escaping @MainActor () -> Bool = { true },
                power: @escaping @MainActor () -> (hot: Bool, lowBattery: Bool) = { (false, false) },
                now: @escaping @MainActor () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
                agentControl: AgentControl? = nil,
                deliver: @escaping @MainActor (ExecutionPermit) throws -> [QueuedTask]) {
        self.agentControl = agentControl
        self.accountID = accountID; self.phoneID = phoneID; self.actorID = actorID
        self.registry = registry; historyStore = history; self.policy = policy
        pipeline = HeldDictationPipeline(history: history, target: target, registry: registry, accountID: accountID, phoneID: phoneID)
        picker = TargetPicker(accountID: accountID, phoneID: phoneID)
        input = PhoneInput(now: now); self.now = now; self.makeCapture = makeCapture
        self.engines = engines; self.brain = brain; self.online = online; self.power = power; self.deliver = deliver
    }
    public func refresh() async {
        devices = await registry.all()
        if let agentControl { tasks = agentControl.router.snapshot() }
        guard historyStore.accountID == accountID else { history = []; message = "History account does not match this installation."; return }
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
    /// Remote positions update presentation only. Capture starts exclusively on
    /// a fresh accepted edge; this API never creates phone PTT/approval evidence.
    public func remotePositions(capture: CaptureState, mode: Mode) {
        controls.setCapture(capture); controls.setMode(mode)
    }
    public func awaitRemoteBoundary() async {
        let finishing = worker
        await finishing?.value
    }
    public func press(at milliseconds: Int64) {
        guard controls.capture != .off else { return }
        if worker == nil {
            do { pressedCapture = try pinCapture?() ?? makeCapture }
            catch { message = "Selected microphone is unavailable. Use a fresh trigger."; return }
        }
        localPTT = true
        trigger.press(at: milliseconds)
    }
    public func advanceTrigger(to milliseconds: Int64) {
        trigger.advance(to: milliseconds)
        if trigger.capture == .hold && listening != .listening && listening != .preparing { begin(capture: pressedCapture) }
    }
    public func release(at milliseconds: Int64) {
        guard controls.capture != .off, localPTT else { return }
        defer { pressedCapture = nil; localPTT = false }
        trigger.release(at: milliseconds)
        if trigger.capture == .continuous {
            controls.setCapture(.continuous)
            if listening != .listening && listening != .preparing { begin(capture: pressedCapture) }
        } else if controls.capture != .continuous { finishUtterance() }
    }
    /// Immediate hardware stop, including while permission/target/engine setup awaits.
    /// Cancelled utterances cannot commit late text or late proposals.
    public func stop() {
        localPTT = false; pressedCapture = nil
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
        if controls.capture == .hold && localPTT { cancelGesture() }
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
    public func beginRemote(capture factory: @escaping CaptureFactory, generation: UUID? = nil) {
        guard generation == nil || generation == epoch else { return }
        localPTT = false; pressedCapture = nil; trigger.stop()
        begin(capture: factory)
    }
    public func begin(capture factory: CaptureFactory? = nil) {
        guard controls.capture != .off, worker == nil else { return }
        let pinnedCapture: CaptureFactory
        do {
            if let factory { pinnedCapture = factory }
            else if let pinCapture { pinnedCapture = try pinCapture() }
            else { pinnedCapture = makeCapture }
        } catch { listening = .failed; message = "Selected microphone is unavailable. Use a fresh trigger."; return }
        let token = UUID(); epoch = token
        segmentTexts.removeAll()
        let segmentID = UUID().uuidString, state = controls, snapshot = settings
        let activation: InputActivation = localPTT && trigger.capture == .hold && state.capture == .hold ? .ptt : .inferred
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
                let source = try await pinnedCapture()
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
                var commandText = ""
                var commandRevision = 0
                for await slice in slices {
                    guard epoch == token, !Task.isCancelled else { break }
                    if !firstSlice {
                        available = await engines()
                        conditions = EngineRouter.Conditions(online: online(), hot: power().hot, lowBattery: power().lowBattery,
                            maxAccuracy: snapshot.maxAccuracy, cloudConsent: snapshot.cloudConsent)
                        currentSegment = UUID().uuidString
                        if state.mode == .dictation {
                            selected = try await pipeline.prepare(segmentID: currentSegment, state: state, picker: picker, now: now())
                        } // AI command keeps its original destination for the whole utterance.
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
                            commandText += (commandText.isEmpty ? "" : " ") + text
                            guard commandText.count <= 16_384 else { throw BrainError.invalidResponse }
                            // A time/silence slice is not an utterance boundary. Retain
                            // revisions so a later correction replaces the same input.
                            commandRevision += 1
                            try await propose(commandText, segmentID: segmentID, revision: commandRevision,
                                complete: false, activation: activation, selected: selected, token: token, settings: snapshot)
                        }
                        await refresh()
                        guard epoch == token, !Task.isCancelled else { return }
                        partial = ""
                    } else { await pipeline.cancel(segmentID: currentSegment) }
                    if failed { break }
                }
                await pipeline.cancel(segmentID: currentSegment)
                guard epoch == token, !Task.isCancelled else { return }
                if state.mode == .ai_control, !failed, !commandText.isEmpty {
                    commandRevision += 1
                    try await propose(commandText, segmentID: segmentID, revision: commandRevision,
                        complete: true, activation: activation, selected: selected, token: token, settings: snapshot)
                }
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
    private func propose(_ text: String, segmentID: String, revision: Int, complete: Bool, activation: InputActivation, selected: DeviceInfo, token: UUID, settings: AppSettings) async throws {
        if complete, activation == .ptt, !muted,
           try submitExplicitTarget(text, selected: selected) { return }
        if suggestionEngine == nil {
            let registryContext = (devices + [picker.phone]).map { "\($0.device_id): \($0.display_name) [\($0.role.rawValue)]" }.joined(separator: "; ")
            let sessionContext = agentControl?.destinations.map { "\($0.session.provider) / \($0.id) / project=\($0.session.workspace) / session=\($0.session.providerSessionID)" }.joined(separator: "; ") ?? "none"
            let context = "Selected destination: \(selected.device_id). Registered destinations: " + registryContext + "; Authenticated agent inventory: " + sessionContext
            suggestionEngine = SuggestionEngine(brain: brain(settings), accountID: accountID,
                context: context, configuration: try SuggestionConfiguration())
        }
        guard let engine = suggestionEngine else { return }
        if let prior = segmentTexts[segmentID], prior != text {
            // A corrected hypothesis cancels an unqueued approval, including a
            // retained permit after uncertain enqueue. Dispatch reservations are
            // independent work; never pretend later speech undid their effects.
            if let card = approval, let id = card.suggestionID, suggestionSegments[id] == segmentID {
                let next: ProposalState = pendingPermits.removeValue(forKey: card.id) == nil ? .dismissed : .cancelled
                _ = policy.transition(requestID: card.id, to: next); approval = nil
            }
            for task in agentControl?.router.snapshot() ?? [] where task.state == .queued {
                if let id = taskSuggestions[task.command.command_id], suggestionSegments[id] == segmentID,
                   let request = UUID(uuidString: task.command.candidate_id) { _ = policy.transition(requestID: request, to: .cancelled) }
            }
        }
        segmentTexts[segmentID] = text
        await engine.setMutedDuringMeeting(muted)
        let update = await engine.ingest(TranscriptSegment(id: segmentID, revision: revision, text: text,
            isFinal: true, isComplete: complete, contextID: selected.device_id, commandContext: activation == .ptt || wakeArmed,
            hypothesis: !complete && activation == .inferred), now: Date(timeIntervalSince1970: Double(now()) / 1000))
        guard epoch == token else { return }
        suggestions = update.cards
        for card in suggestions where suggestionTargets[card.id] == nil {
            suggestionTexts[card.id] = text
            suggestionSegments[card.id] = segmentID
            let proposedID: String
            switch card.proposal.tool {
            case .selectTargetTool(let tool): proposedID = tool.device_id
            case .openResourceTool(let tool): proposedID = tool.device_id
            case .delegateTaskTool(let tool): proposedID = tool.device_id
            case .prepareSendTool(let tool): proposedID = tool.device_id
            case .cancelTaskTool(let tool): proposedID = tasks.first(where: { $0.command.command_id == tool.command_id && $0.command.account_id == accountID })?.command.destination_id ?? selected.device_id
            }
            // Untrusted destination hints resolve only through the trusted registry.
            suggestionTargets[card.id] = (devices + [picker.phone]).first { $0.device_id == proposedID && $0.account_id == accountID }
        }
        let textIDs = Set(suggestions.map(\.id) + [approval?.suggestionID].compactMap { $0 })
        suggestionTexts = suggestionTexts.filter { textIDs.contains($0.key) }
        if let notice = update.routingNotice { cloudInUse = notice == .cloud }
        if update.failure != nil { message = "Brain unavailable. No action was started." }
    }
    /// A deliberately narrow low-risk grammar. Scope/identity come only from the
    /// phone permission setting and pinned capture, never from Brain or wake text.
    private func submitExplicitTarget(_ text: String, selected: DeviceInfo) throws -> Bool {
        guard let scope = armedTargetScope, scope.device == selected.device_id,
              scope.project == (agentControl?.selected?.workspace ?? "default"),
              selected.account_id == accountID, selected.capabilities.contains(.receive_text) else { return false }
        let words = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let names = [selected.device_id, selected.display_name] + (selected.device_id == phoneID ? ["phone", "iphone"] : [])
        let allowed = names.flatMap { name in ["switch to " + name.lowercased(), "select " + name.lowercased()] }
        guard allowed.contains(words) || allowed.contains(where: { words == $0 + "." }) else { return false }
        let session = input.session(account: accountID, actor: actorID, session: UUID().uuidString,
            device: scope.device, project: scope.project, destinationKind: .software)
        let tool = ToolCall.selectTargetTool(SelectTargetTool(account_id: accountID, device_id: scope.device))
        let evidence = input.activation(session: session, kind: .ptt, expiresAt: now() + 120_000)
        guard case .queued(let permit) = policy.submit(try ProtocolCodec.encode(tool), input: evidence),
              permit.command.approval_credential_class == .scoped_grant else { return false }
        return applyTargetSelection(permit)
    }
    /// An approved selection affects future text without interrupting an open
    /// ambient capture. That capture retains its original destination/context.
    @discardableResult private func applyTargetSelection(_ permit: ExecutionPermit) -> Bool {
        guard case .selectTargetTool(let target) = permit.command.immutable_task_payload,
              let id = UUID(uuidString: permit.command.candidate_id),
              policy.transition(requestID: id, to: .dispatched) else { return false }
        controls.setTarget(.device(target.device_id)); picker.selection = controls.target
        destination = try? picker.resolve(devices: devices)
        _ = policy.transition(requestID: id, to: .running)
        _ = policy.transition(requestID: id, to: .succeeded)
        message = "Destination changed to " + (destination?.display_name ?? target.device_id)
        return true
    }
    public func muteSuggestions(_ value: Bool) async {
        muted = value; await suggestionEngine?.setMutedDuringMeeting(value)
        suggestions = await suggestionEngine?.cards(now: Date(timeIntervalSince1970: Double(now()) / 1000)) ?? []
    }
    /// Opens an exact Policy preview. A review tap creates no execution authority.
    public func review(_ card: SuggestionCard) async {
        guard !muted, let engine = suggestionEngine, var selected = suggestionTargets[card.id],
              let tapped = await engine.tap(SuggestionTap(cardID: card.id, previewRevision: card.revision),
                now: Date(timeIntervalSince1970: Double(now()) / 1000)) else { return }
        do {
            guard !muted, suggestionTargets[card.id]?.device_id == selected.device_id else { throw RouterError.invalidAuthorization }
            if case .selectTargetTool = tapped.proposal.tool, !selected.capabilities.contains(.receive_text) { throw AppRoutingError.unavailableDestination }
            let tool: ToolCall
            let project: String
            var reviewedRoute: Destination?
            var plannedRules: RoutingRules?
            if case .delegateTaskTool(let proposed) = tapped.proposal.tool, let agentControl {
                guard let chosenProject = agentControl.routing.project ?? agentControl.selected?.workspace else { throw AppRoutingError.unknownProviderSession }
                var rules = try agentControl.routingRules(project: chosenProject, text: suggestionTexts[card.id] ?? "")
                if let originalHost = suggestionConstraints[card.id]?.machineDependency {
                    rules.machineDependency = originalHost; rules.cloudCapable = false
                }
                guard let route = agentControl.reviewDestination(rules),
                      let device = devices.first(where: { $0.device_id == route.id && $0.account_id == accountID }) else { throw AppRoutingError.unavailableDestination }
                if !rules.cloudCapable { rules.machineDependency = route.session.host }
                selected = device; suggestionTargets[card.id] = device
                project = route.session.workspace; reviewedRoute = route; plannedRules = rules
                suggestionConstraints[card.id] = rules
                tool = .delegateTaskTool(DelegateTaskTool(account_id: accountID, device_id: selected.device_id,
                    project_id: project, provider_session_id: route.session.providerSessionID, instruction: proposed.instruction))
            } else {
                tool = tapped.proposal.tool
                if case .delegateTaskTool(let proposed) = tool { project = proposed.project_id }
                else if case .cancelTaskTool(let proposed) = tool,
                        let task = tasks.first(where: { $0.command.command_id == proposed.command_id && $0.command.destination_id == selected.device_id }) { project = task.rules.project }
                else { project = agentControl?.selected?.workspace ?? "default" }
                if let agentControl {
                    switch tool {
                    case .prepareSendTool: throw AppRoutingError.unsupportedAction
                    case .openResourceTool:
                        guard let route = agentControl.selected, route.host == selected.device_id else { throw AppRoutingError.unknownProviderSession }
                        reviewedRoute = try agentControl.resolve(device: selected.device_id, project: route.workspace, providerSession: route.providerSessionID)
                    default: break
                    }
                }
            }
            let dependencies = tapped.dependsOn.compactMap { authorizedSuggestions[$0] }
            guard dependencies.count == tapped.dependsOn.count,
                  dependencies.allSatisfy({ id in tasks.contains { $0.command.command_id == id && $0.state == .succeeded && $0.outcome == .ok } }) else { throw RouterError.invalidAuthorization }
            let session = input.session(account: accountID, actor: actorID, session: UUID().uuidString,
                device: selected.device_id, project: project, destinationKind: .software)
            // The separate deliberate HOLD entry is the only grant-only path.
            let activation = input.activation(session: session, kind: .inferred, expiresAt: now() + 120_000)
            switch policy.submit(try ProtocolCodec.encode(tool), input: activation) {
            case .suggestion(let preview), .authenticationRequired(let preview):
                approval = ApprovalCard(preview: preview, destination: selected, session: session, route: reviewedRoute, routingRules: plannedRules,
                    suggestionID: card.id, suggestionRevision: card.revision, dependencies: dependencies)
                suggestions = await engine.cards(now: Date(timeIntervalSince1970: Double(now()) / 1000))
                return
            default: throw RouterError.invalidAuthorization
            }
        } catch { message = "Action is held. Check the enrolled project, named session, fallback settings and predecessor completion, then review again." }
        _ = await engine.releaseReview(cardID: card.id, revision: card.revision, now: Date(timeIntervalSince1970: Double(now()) / 1000))
        suggestions = await engine.cards(now: Date(timeIntervalSince1970: Double(now()) / 1000))
    }
    public func approve(source: ApprovalSource = .phone) async {
        guard let card = approval else { return }
        // Draft BLE has no authenticated approval mechanism, at any tier.
        guard source == .phone else { message = "Approve on your iPhone."; return }
        if let permit = pendingPermits[card.id] {
            do {
                _ = try policy.verifyExecution(command: permit.command, immutablePreview: permit.immutablePreview, expiresAt: permit.expiresAt)
                try await queue(permit, card: card)
            } catch { message = "Queue confirmation failed. Check task status before retrying or denying." }
            return
        }
        let decision = await policy.approve(requestID: card.id, evidence: input.approval(session: card.session,
            requestID: card.id, payloadHash: card.preview.payloadHash, source: source))
        guard approval?.id == card.id else { return }
        switch decision {
        case .queued(let permit):
            if case .selectTargetTool = permit.command.immutable_task_payload {
                guard await authorizeSuggestion(permit, card: card) else { return }
                guard applyTargetSelection(permit) else { return }
                if let id = card.suggestionID { await suggestionEngine?.completed(cardID: id, succeeded: true, now: Date(timeIntervalSince1970: Double(now()) / 1000)) }
                approval = nil
                return
            }
            pendingPermits[card.id] = permit
            do { try await queue(permit, card: card) }
            catch { message = "Queue confirmation failed. Check task status before retrying or denying." }
        case .denied: message = "Approval denied or expired. Nothing was started."
        default: message = "Action needs review."
        }
    }
    private func authorizeSuggestion(_ permit: ExecutionPermit, card: ApprovalCard) async -> Bool {
        if let suggestionID = card.suggestionID {
            guard await suggestionEngine?.authorized(cardID: suggestionID, revision: card.suggestionRevision, now: Date(timeIntervalSince1970: Double(now()) / 1000)) == true,
                  approval?.id == card.id else {
                pendingPermits.removeValue(forKey: card.id)
                _ = policy.transition(requestID: card.id, to: .cancelled)
                if approval?.id == card.id { approval = nil }
                return false
            }
            authorizedSuggestions[suggestionID] = permit.command.command_id
            taskSuggestions[permit.command.command_id] = suggestionID
        }
        return true
    }
    private func queue(_ permit: ExecutionPermit, card: ApprovalCard) async throws {
        if let agentControl, let rules = card.routingRules, let expected = card.route,
           !agentControl.router.snapshot().contains(where: { $0.command.command_id == permit.command.command_id }) {
            let matches: Bool
            if let live = agentControl.reviewDestination(agentControl.updatedRules(rules)) {
                matches = live.session == expected.session && live.capabilities == expected.capabilities
            } else { matches = false }
            if !matches {
                pendingPermits.removeValue(forKey: card.id)
                _ = policy.transition(requestID: card.id, to: .cancelled)
                approval = nil
                if let id = card.suggestionID, let revised = await suggestionEngine?.releaseReview(cardID: id, revision: card.suggestionRevision,
                    now: Date(timeIntervalSince1970: Double(now()) / 1000)) {
                    await review(revised)
                }
                message = "Destination changed. Review the new destination and approve again; the previous approval was cancelled."
                return
            }
        }
        guard await authorizeSuggestion(permit, card: card) else { return }
        if let agentControl {
            tasks = try agentControl.enqueue(permit, dependencies: card.dependencies, replacingCommandID: card.replacingCommandID, expectedRoute: card.route, routingRules: card.routingRules)
        } else { tasks = try deliver(permit) }

        if let id = card.suggestionID, agentControl == nil || tasks.contains(where: { $0.command.command_id == permit.command.command_id && $0.state != .queued }) {
            await suggestionEngine?.executionCommitted(cardID: id, now: Date(timeIntervalSince1970: Double(now()) / 1000))
        }
        pendingPermits.removeValue(forKey: card.id); approval = nil
    }
    public func dismissApproval() {
        if let approval {
            let next: ProposalState = pendingPermits.removeValue(forKey: approval.id) == nil ? .dismissed : .cancelled
            _ = policy.transition(requestID: approval.id, to: next)
        }
        if let id = approval?.suggestionID {
            Task { await suggestionEngine?.dismiss(cardID: id, now: Date(timeIntervalSince1970: Double(now()) / 1000)) }
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
        try await historyStore.saveText(HistoryEntry(segmentID: id, targetID: phoneID, text: clean, createdAt: now(), accountID: accountID), state: .offline, now: now(), origin: origin)
        await refresh()
    }
    public func deleteHistory(_ id: String) async {
        do { try await historyStore.delete(id: id, now: now()); await refresh() }
        catch { message = "Unable to delete history." }
    }
    public func refreshTasks() async {
        guard let agentControl else { return }
        tasks = agentControl.router.snapshot()
        for task in tasks {
            guard let id = taskSuggestions[task.command.command_id] else { continue }
            if task.state == .dispatched || task.state == .running {
                await suggestionEngine?.executionCommitted(cardID: id, now: Date(timeIntervalSince1970: Double(now()) / 1000))
            }
            if task.state == .succeeded || task.state == .failed || task.state == .cancelled {
                await suggestionEngine?.completed(cardID: id, succeeded: task.state == .succeeded && task.outcome == .ok,
                    now: Date(timeIntervalSince1970: Double(now()) / 1000))
            }
        }
        suggestions = await suggestionEngine?.cards(now: Date(timeIntervalSince1970: Double(now()) / 1000)) ?? suggestions
    }
    public func reviewTaskCompletion(_ task: QueuedTask) {
        guard let epoch = agentControl?.completionEpoch(for: task),
              let hash = try? TaskRouter.completionOperation(task) else { return }
        completion = TaskCompletionCard(id: UUID(), task: task, connectionEpoch: epoch, operationHash: hash)
    }
    public func dismissTaskCompletion() { completion = nil }
    /// UI tap only. Nothing in the model, speech or agent-result paths calls this.
    public func confirmTaskFinished() async {
        guard let card = completion, let agentControl else { return }
        let task = card.task
        let session = input.session(account: accountID, actor: actorID, session: card.connectionEpoch.uuidString,
            device: task.command.destination_id, project: task.rules.project, destinationKind: .software)
        do {
            try agentControl.confirmOwnerCompletion(task, epoch: card.connectionEpoch,
                evidence: input.ownerCompletion(session: session, commandID: task.command.command_id, operationHash: card.operationHash))
            completion = nil; await refreshTasks()
            message = "You confirmed this task finished. Review the next linked step before it runs."
        } catch { completion = nil; message = "Task or session changed. Review completion again; linked steps still wait." }
    }
    public func cancelTask(_ task: QueuedTask) async {
        do { try await agentControl?.cancel(task); await refreshTasks() }
        catch { message = "Cancellation is pending. Reconnect and check the computer." }
    }
    public func reviewRestoredTask(_ task: QueuedTask) {
        guard task.state == .queued, task.hold == .reapprovalRequired,
              let agentControl,
              agentControl.router.snapshot().contains(where: { $0.command == task.command }) else { return }
        do {
            let rules = agentControl.updatedRules(task.rules)
            guard let route = agentControl.reviewDestination(rules),
                  let device = devices.first(where: { $0.device_id == route.id && $0.account_id == accountID }) else { throw RouterError.invalidAuthorization }
            let tool: ToolCall
            switch task.command.immutable_task_payload {
            case .delegateTaskTool(let original):
                tool = .delegateTaskTool(DelegateTaskTool(account_id: accountID, device_id: route.id, project_id: original.project_id,
                    provider_session_id: route.session.providerSessionID, instruction: original.instruction))
            default: tool = task.command.immutable_task_payload
            }
            let session = input.session(account: accountID, actor: actorID, session: UUID().uuidString,
                device: device.device_id, project: task.rules.project, destinationKind: .software)
            let decision = policy.submit(try ProtocolCodec.encode(tool),
                input: input.activation(session: session, kind: .inferred, expiresAt: now() + 120_000))
            if case .suggestion(let preview) = decision {
                approval = ApprovalCard(preview: preview, destination: device, session: session, route: route, routingRules: rules,
                    dependencies: task.rules.dependencies ?? [], replacingCommandID: task.command.command_id)
            }
        } catch { message = "Destination is held. Check the original machine and named constraints, then review a new route." }
    }
    /// Settings event only. A voice request can never install or extend a grant.
    public func grantTargetSelection(device: DeviceInfo, project: String) {
        guard (devices + [picker.phone]).contains(device), device.capabilities.contains(.receive_text) else { return }
        let session = input.session(account: accountID, actor: actorID, session: UUID().uuidString,
            device: device.device_id, project: project, destinationKind: .software)
        let grant = input.grant(session: session, capability: .receive_text, risk: .read_display, expiresAt: now() + 900_000)
        if policy.installGrant(grant) { grants.append(grant); armedTargetScope = session }
        else { message = "Permission could not be saved." }
    }
    public func revokeGrant(_ grant: GrantEvidence) {
        if policy.revokeGrant(grant.id, session: grant.session) { grants.removeAll { $0.id == grant.id } }
    }
    public func revoke(_ id: String) async {
        stop(); dismissApproval()
        agentControl?.revoked(id)
        for grant in grants where grant.session.device == id { revokeGrant(grant) }
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
