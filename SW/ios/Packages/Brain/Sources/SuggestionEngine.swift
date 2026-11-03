import Foundation

public enum SuggestionState: String, Sendable { case suggested, edited, reviewing, approved, succeeded, failed, dismissed, expired }

public struct TranscriptSegment: Sendable {
    public let id: String
    public let revision: Int
    public let text: String
    public let isFinal: Bool
    public let isComplete: Bool
    /// Change this when conversation, target or speaker scope changes.
    public let contextID: String
    /// Supplied by the capture composition root, never inferred from model output.
    public let commandContext: Bool
    public init(id: String, revision: Int, text: String, isFinal: Bool, isComplete: Bool, contextID: String, commandContext: Bool = false) {
        self.id = id; self.revision = revision; self.text = text; self.isFinal = isFinal
        self.isComplete = isComplete; self.contextID = contextID; self.commandContext = commandContext
    }
}

public struct SuggestionCard: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let segmentID: String
    public let proposal: BrainProposal
    public let planID: UUID?
    public let dependsOn: [UUID]
    public let expiresAt: Date
    public let revision: Int
    public let state: SuggestionState
    var reviewable: Bool { state == .suggested || state == .edited }
}

/// Only a UI event should construct this value. Model JSON is never decoded into an event.
/// This is not an authenticated approval credential; Policy must authenticate/bind its own event.
public struct SuggestionTap: Sendable {
    public let cardID: UUID
    public let previewRevision: Int
    public init(cardID: UUID, previewRevision: Int) { self.cardID = cardID; self.previewRevision = previewRevision }
}

/// Immutable review snapshot for the separate Policy boundary. Still cannot execute anything.
public struct TappedSuggestion: Sendable {
    public let cardID: UUID
    public let previewRevision: Int
    public let proposal: BrainProposal
    public let dependsOn: [UUID]
}

public struct SuggestionConfiguration: Sendable {
    public let maximumCardsPerWindow: Int
    public let rateWindow: TimeInterval
    public let lifetime: TimeInterval
    public let maximumInferenceRequestsPerWindow: Int
    public let maximumConcurrentInferences: Int
    public let maximumRetainedCards: Int
    public let maximumTrackedSegments: Int
    public let wakePhrase: String
    /// Initial defensive defaults, TBC by product/on-device testing.
    public init(maximumCardsPerWindow: Int = 3, rateWindow: TimeInterval = 30, lifetime: TimeInterval = 120,
                maximumInferenceRequestsPerWindow: Int = 8, maximumConcurrentInferences: Int = 4,
                maximumRetainedCards: Int = 256, maximumTrackedSegments: Int = 256,
                wakePhrase: String = "Assistant") throws {
        guard maximumCardsPerWindow > 0, rateWindow.isFinite, rateWindow > 0,
              lifetime.isFinite, lifetime > 0, maximumInferenceRequestsPerWindow > 0,
              (1...4).contains(maximumConcurrentInferences), maximumRetainedCards > 0,
              maximumTrackedSegments > 0 else { throw BrainError.invalidConfiguration }
        self.maximumCardsPerWindow = maximumCardsPerWindow; self.rateWindow = rateWindow; self.lifetime = lifetime
        self.maximumInferenceRequestsPerWindow = maximumInferenceRequestsPerWindow
        self.maximumConcurrentInferences = maximumConcurrentInferences
        self.maximumRetainedCards = maximumRetainedCards; self.maximumTrackedSegments = maximumTrackedSegments
        self.wakePhrase = wakePhrase
    }
}

public struct SuggestionUpdate: Sendable {
    public let cards: [SuggestionCard]
    public let droppedCount: Int
    public let failure: BrainError?
    public let routingNotice: BrainRoutingNotice?
    public let deferred: SuggestionDeferral?
}

public enum SuggestionDeferral: Equatable, Sendable { case rateLimited, busy, capacity }

public actor SuggestionEngine {
    private struct SegmentRevision {
        let revision: Int
        let token: UUID
        let expiresAt: Date
    }
    private let brain: any LlmBrain
    private let configuration: SuggestionConfiguration
    private let accountID: String
    private let context: String
    private var contextID: String?
    // Only global events (mute/context) change the epoch. Transcript revisions are segment-local.
    private var epoch = UUID()
    private var revisions: [String: SegmentRevision] = [:]
    private var revisionOrder: [String] = []
    private var storage: [SuggestionCard] = []
    private var creationTimes: [Date] = []
    private var inferenceTimes: [Date] = []
    private var inFlightTokens: Set<UUID> = []
    private var muted = false
    private var latestTime = Date.distantPast
    private var plans: [UUID: [UUID]] = [:]
    private var latestPlanID: UUID?
    private var routingNotice: BrainRoutingNotice?

    public init(brain: any LlmBrain, accountID: String, context: String, configuration: SuggestionConfiguration) {
        self.brain = brain; self.accountID = accountID; self.context = context; self.configuration = configuration
    }

    public func setMutedDuringMeeting(_ value: Bool) {
        muted = value; epoch = UUID()
    }

    public func cards(now: Date) -> [SuggestionCard] {
        advance(now)
        return muted ? [] : storage.filter { $0.reviewable }
    }

    public func history(now: Date) -> [SuggestionCard] { advance(now); return storage }

    public func ingest(_ segment: TranscriptSegment, now: Date) async -> SuggestionUpdate {
        advance(now)
        guard !segment.id.isEmpty, segment.id.count <= 128, segment.contextID.count <= 128,
              segment.text.count <= 16_384, segment.revision >= 0 else { return update(failure: .invalidResponse) }
        if contextID != segment.contextID {
            expireReviewable(); epoch = UUID(); contextID = segment.contextID
            revisions.removeAll(); revisionOrder.removeAll()
        }
        guard segment.revision > (revisions[segment.id]?.revision ?? -1) else { return update() }
        let token = UUID(), requestEpoch = epoch
        revisions[segment.id] = SegmentRevision(revision: segment.revision, token: token,
            expiresAt: latestTime.addingTimeInterval(configuration.lifetime))
        revisionOrder.removeAll { $0 == segment.id }; revisionOrder.append(segment.id)
        while revisionOrder.count > configuration.maximumTrackedSegments {
            // Bound idle history without evicting another segment's active inference.
            guard let index = revisionOrder.firstIndex(where: { id in
                revisions[id].map { !inFlightTokens.contains($0.token) } ?? true
            }) else { break }
            let removed = revisionOrder.remove(at: index)
            revisions.removeValue(forKey: removed); expireSegment(removed)
        }
        expireSegment(segment.id)
        guard revisions[segment.id]?.token == token else { return update(deferred: .capacity) }
        guard !muted, segment.isFinal, segment.isComplete else { return update() }
        if let ordinal = CommandSequence.cancellationOrdinal(segment.text, wakePhrase: configuration.wakePhrase) {
            if let latestPlanID { cancelInPlan(latestPlanID, ordinal: ordinal) }
            return update()
        }
        guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return update() }
        // Reserve both network budget and an active slot before suspending in the provider.
        guard inferenceTimes.count < configuration.maximumInferenceRequestsPerWindow,
              creationTimes.count < configuration.maximumCardsPerWindow else { return update(deferred: .rateLimited) }
        guard inFlightTokens.count < configuration.maximumConcurrentInferences else { return update(deferred: .busy) }
        guard storage.count < configuration.maximumRetainedCards else { return update(deferred: .capacity) }
        inferenceTimes.append(latestTime); inFlightTokens.insert(token)
        defer { inFlightTokens.remove(token) }
        let linked = isLinkedPlan(segment.text)
        let request = BrainRequest(accountID: accountID, transcript: segment.text, context: context,
                                   workload: linked ? .multiStep : (segment.commandContext ? .automatic : .ambient))
        let response: BrainResponse
        do { response = try await brain.propose(request) }
        catch {
            guard requestEpoch == epoch, revisions[segment.id]?.token == token, !muted else { return update() }
            return update(failure: (error as? BrainError) ?? .unavailable)
        }
        guard requestEpoch == epoch, revisions[segment.id]?.token == token, !muted else { return update() }
        routingNotice = response.outcome == .refused ? .refused : response.routingNotice
        let proposed = response.proposals.filter { $0.accountID == accountID }
        let dropped = response.droppedCount + response.proposals.count - proposed.count
        guard response.outcome != .refused else { return update(dropped: dropped) }
        var seen = Set(storage.filter { $0.state != .expired }.map { $0.proposal.normalizedIntent })
        let fresh = proposed.filter { seen.insert($0.normalizedIntent).inserted }
        guard !fresh.isEmpty else { return update(dropped: dropped) }
        // Keep linked batches atomic; partial deduplication must not create a broken dependency tail.
        guard !linked || fresh.count == proposed.count else { return update(dropped: dropped) }
        guard creationTimes.count + fresh.count <= configuration.maximumCardsPerWindow else {
            return update(dropped: dropped, deferred: .rateLimited)
        }
        guard storage.count + fresh.count <= configuration.maximumRetainedCards else {
            return update(dropped: dropped, deferred: .capacity)
        }
        let planID = linked && fresh.count > 1 ? UUID() : nil
        var order: [UUID] = []
        for proposal in fresh {
            let id = UUID()
            storage.append(SuggestionCard(id: id, segmentID: segment.id, proposal: proposal, planID: planID,
                dependsOn: planID == nil ? [] : order.last.map { [$0] } ?? [],
                expiresAt: latestTime.addingTimeInterval(configuration.lifetime), revision: 0, state: .suggested))
            order.append(id); creationTimes.append(latestTime)
        }
        if let planID { plans[planID] = order; latestPlanID = planID }
        return update(dropped: dropped)
    }

    /// Editing changes the preview revision. Old taps cannot approve the replacement payload.
    public func edit(cardID: UUID, proposal: BrainProposal, now: Date) -> SuggestionCard? {
        advance(now)
        guard let index = storage.firstIndex(where: { $0.id == cardID }), storage[index].reviewable,
              proposal.accountID == accountID else { return nil }
        let old = storage[index]
        expireDependents(of: cardID)
        storage[index] = SuggestionCard(id: old.id, segmentID: old.segmentID, proposal: proposal, planID: old.planID,
            dependsOn: old.dependsOn, expiresAt: old.expiresAt, revision: old.revision + 1, state: .edited)
        return storage[index]
    }

    /// Opening a review is not approval. Only completed authorized predecessors unblock a plan.
    public func tap(_ event: SuggestionTap, now: Date) -> TappedSuggestion? {
        advance(now)
        guard !muted, let index = storage.firstIndex(where: { $0.id == event.cardID }),
              storage[index].reviewable, storage[index].revision == event.previewRevision,
              storage[index].dependsOn.allSatisfy({ dependency in
                  storage.contains { $0.id == dependency && $0.state == .succeeded }
              }) else { return nil }
        replace(index, state: .reviewing)
        let card = storage[index]
        return TappedSuggestion(cardID: card.id, previewRevision: card.revision,
                                proposal: card.proposal, dependsOn: card.dependsOn)
    }

    /// Called by the phone only after Policy issues a permit; still no execution authority here.
    @discardableResult public func authorized(cardID: UUID, revision: Int, now: Date) -> Bool {
        advance(now)
        guard let index = storage.firstIndex(where: { $0.id == cardID }),
              storage[index].revision == revision else { return false }
        if storage[index].state == .approved { return true } // same permit retry after uncertain persistence
        guard storage[index].state == .reviewing else { return false }
        replace(index, state: .approved)
        return true
    }
    /// Authenticated executor outcomes, never proposal/card state, release dependencies.
    public func completed(cardID: UUID, succeeded: Bool, now: Date) {
        advance(now)
        guard let index = storage.firstIndex(where: { $0.id == cardID }), storage[index].state == .approved else { return }
        replace(index, state: succeeded ? .succeeded : .failed)
        if !succeeded { expireDependents(of: cardID) }
    }

    public func dismiss(cardID: UUID, now: Date) {
        advance(now)
        if let index = storage.firstIndex(where: { $0.id == cardID }), (storage[index].reviewable || storage[index].state == .reviewing) {
            replace(index, state: .dismissed); expireDependents(of: cardID)
        }
    }

    /// UI selection can name a specific plan; speech uses the most recent linked plan only.
    public func cancel(planID: UUID, ordinal: Int, now: Date) {
        advance(now); cancelInPlan(planID, ordinal: ordinal)
    }

    private func cancelInPlan(_ planID: UUID, ordinal: Int) {
        guard let order = plans[planID], ordinal > 0, ordinal <= order.count else { return }
        let id = order[ordinal - 1]
        if let index = storage.firstIndex(where: { $0.id == id }), (storage[index].reviewable || storage[index].state == .reviewing) {
            replace(index, state: .dismissed); expireDependents(of: id)
        }
    }

    private func isLinkedPlan(_ text: String) -> Bool {
        let body = WakePhraseDetector.removingAddressPrefix(text, phrase: configuration.wakePhrase)
        let sequence = CommandSequence.parse(body, isFinal: true, isComplete: true)
        guard sequence.instructions.count > 1 else { return false }
        if body.range(of: #"\bthen\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        return sequence.instructions.allSatisfy { instruction in
            let first = instruction.text.lowercased().split(whereSeparator: \.isWhitespace).first.map(String.init)
            return first.map { ["open", "ask", "summarize", "compare", "switch", "select"].contains($0) } ?? false
        }
    }

    private func expireSegment(_ id: String) {
        for index in storage.indices where storage[index].segmentID == id && (storage[index].reviewable || storage[index].state == .reviewing) {
            let cardID = storage[index].id; replace(index, state: .expired); expireDependents(of: cardID)
        }
    }
    private func expireDependents(of id: UUID) {
        var unavailable: Set<UUID> = [id]
        for index in storage.indices where storage[index].reviewable || storage[index].state == .reviewing {
            if storage[index].dependsOn.contains(where: unavailable.contains) {
                unavailable.insert(storage[index].id); replace(index, state: .expired)
            }
        }
    }
    private func advance(_ now: Date) {
        latestTime = max(latestTime, now)
        creationTimes.removeAll { latestTime.timeIntervalSince($0) >= configuration.rateWindow }
        inferenceTimes.removeAll { latestTime.timeIntervalSince($0) >= configuration.rateWindow }
        for index in storage.indices where storage[index].expiresAt <= latestTime {
            expireDependents(of: storage[index].id)
        }
        storage.removeAll { $0.expiresAt <= latestTime }
        revisions = revisions.filter { $0.value.expiresAt > latestTime }
        revisionOrder.removeAll { revisions[$0] == nil }
        let retained = Set(storage.map(\.id))
        plans = plans.filter { $0.value.contains(where: retained.contains) }
        if let latestPlanID, plans[latestPlanID] == nil { self.latestPlanID = nil }
    }
    private func expireReviewable() {
        for index in storage.indices where storage[index].reviewable { replace(index, state: .expired) }
    }
    private func replace(_ index: Int, state: SuggestionState) {
        let old = storage[index]
        storage[index] = SuggestionCard(id: old.id, segmentID: old.segmentID, proposal: old.proposal, planID: old.planID,
            dependsOn: old.dependsOn, expiresAt: old.expiresAt, revision: old.revision, state: state)
    }
    private func update(dropped: Int = 0, failure: BrainError? = nil, deferred: SuggestionDeferral? = nil) -> SuggestionUpdate {
        SuggestionUpdate(cards: muted ? [] : storage.filter { $0.reviewable }, droppedCount: dropped,
                         failure: failure, routingNotice: routingNotice, deferred: deferred)
    }
}
