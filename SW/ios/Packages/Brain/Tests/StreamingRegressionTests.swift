import XCTest
import Foundation
@testable import Brain

private actor MeetingBrain: LlmBrain {
    var requests: [BrainRequest] = []
    func propose(_ request: BrainRequest) async throws -> BrainResponse {
        requests.append(request)
        // The context sentence alone and an isolated actionable clause are insufficient.
        let full = "We have two fictional motors. It might be interesting to compare those two motors."
        return BrainResponse(proposals: request.transcript == full ? [proposal()] : [])
    }
}

private actor CorrectionBrain: LlmBrain {
    var requests: [BrainRequest] = []
    func propose(_ request: BrainRequest) async throws -> BrainResponse {
        requests.append(request)
        return BrainResponse(proposals: [proposal(device: request.transcript.contains("Actually") ? "desktop" : "laptop")])
    }
}

private actor ConcurrentBrain: LlmBrain {
    var pending: [CheckedContinuation<BrainResponse, Never>] = []
    var started: CheckedContinuation<Void, Never>?
    var requestedCount = 0
    func propose(_ request: BrainRequest) async throws -> BrainResponse {
        requestedCount += 1
        return await withCheckedContinuation { continuation in
            pending.append(continuation)
            if requestedCount >= 4 { started?.resume(); started = nil }
        }
    }
    func waitForFour() async {
        if requestedCount >= 4 { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() { for continuation in pending { continuation.resume(returning: BrainResponse()) }; pending = [] }
}

private extension SuggestionEngine {
    // Actor-isolated inspection of collection size only; no transcript or proposal logging.
    func retainedRevisionsForTest() -> Int {
        let value = Mirror(reflecting: self).children.first { $0.label == "revisions" }!.value
        return Mirror(reflecting: value).children.count
    }
}

final class StreamingRegressionTests: XCTestCase, @unchecked Sendable {
    let now = Date(timeIntervalSince1970: 1000)
    func segment(_ text: String, id: String = "s", revision: Int = 0, final: Bool = true) -> TranscriptSegment {
        .init(id: id, revision: revision, text: text, isFinal: final, isComplete: final, contextID: "meeting")
    }
    func engine(_ brain: any LlmBrain) throws -> SuggestionEngine {
        .init(brain: brain, accountID: "a", context: "Fictional registry", configuration: try .init())
    }

    func testOtherSegmentPartialDoesNotStarveCompletedInference() async throws {
        let brain = SuspendedBrain(), engine = try engine(brain)
        let pending = Task { await engine.ingest(segment("open dashboard", id: "final"), now: now) }
        await brain.waitUntilStarted()
        _ = await engine.ingest(segment("ongoing conversation", id: "other", final: false), now: now)
        await brain.resume()
        let update = await pending.value
        XCTAssertEqual(update.cards.count, 1)
    }

    func testRevisionPruningProtectsUnrelatedInferenceStillInFlight() async throws {
        let brain = SuspendedBrain(), engine = try engine(brain)
        let pending = Task { await engine.ingest(segment("open dashboard", id: "final"), now: now) }
        await brain.waitUntilStarted()
        for index in 0..<1000 {
            _ = await engine.ingest(segment("ongoing", id: "partial-\(index)", final: false), now: now)
        }
        let retained = await engine.retainedRevisionsForTest()
        XCTAssertLessThanOrEqual(retained, 256)
        await brain.resume()
        let update = await pending.value
        XCTAssertEqual(update.cards.count, 1)
    }

    func testJourneyCUsesWholeAmbientSegmentRatherThanDemandingOneToolPerSentence() async throws {
        let brain = MeetingBrain(), engine = try engine(brain)
        let text = "We have two fictional motors. It might be interesting to compare those two motors."
        let update = await engine.ingest(segment(text), now: now)
        XCTAssertEqual(update.cards.count, 1)
        let requests = await brain.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.transcript, text)
        XCTAssertEqual(requests.first?.workload, .ambient)
    }

    func testLaterCorrectionIsVisibleBeforeAnyProposalIsCreated() async throws {
        let brain = CorrectionBrain(), engine = try engine(brain)
        let text = "Open dashboard on laptop. Actually use desktop instead."
        let update = await engine.ingest(segment(text), now: now)
        XCTAssertEqual(update.cards.map(\.proposal), [proposal(device: "desktop")])
        let requests = await brain.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.transcript, text)
    }

    func testUnrelatedSuggestionDoesNotReplacePlanOrdinals() async throws {
        let engine = try engine(EchoBrain())
        let initial = await engine.ingest(segment("open one. Then open two", id: "plan"), now: now)
        XCTAssertEqual(initial.cards.count, 2)
        guard initial.cards.count == 2 else { return }
        let later = await engine.ingest(segment("open unrelated", id: "unrelated"), now: now)
        let unrelated = try XCTUnwrap(later.cards.first { $0.segmentID == "unrelated" })
        _ = await engine.ingest(segment("cancel the first one", id: "cancel"), now: now)
        let history = await engine.history(now: now)
        XCTAssertEqual(history.first { $0.id == initial.cards[0].id }?.state, .dismissed)
        XCTAssertEqual(history.first { $0.id == unrelated.id }?.state, .suggested)
    }

    func testWakePrefixedCancellationTargetsPlanWithoutInference() async throws {
        XCTAssertEqual(CommandSequence.cancellationOrdinal("Assistant, cancel the second one"), 2)
        let brain = EchoBrain(), engine = try engine(brain)
        let initial = await engine.ingest(segment("open one. Open two. Then open three", id: "plan"), now: now)
        XCTAssertEqual(initial.cards.count, 3)
        guard initial.cards.count == 3 else { return }
        _ = await engine.ingest(segment("Assistant, cancel the second one", id: "cancel"), now: now)
        let history = await engine.history(now: now)
        XCTAssertEqual(history.map(\.state), [.suggested, .dismissed, .expired])
        let count = await brain.requestCount
        XCTAssertEqual(count, 1)
    }

    func testInferenceIsRateLimitedEvenWhenNoCardsAreProduced() async throws {
        let brain = TestBrain(BrainResponse()), engine = try engine(brain)
        for index in 0..<40 { _ = await engine.ingest(segment("ordinary conversation", id: "s\(index)"), now: now) }
        let count = await brain.count
        XCTAssertLessThanOrEqual(count, 8)
        XCTAssertGreaterThan(count, 0)
    }

    func testConcurrentInferenceIsCappedAtFour() async throws {
        let brain = ConcurrentBrain(), engine = try engine(brain)
        let firstFour = (0..<4).map { index in Task { await engine.ingest(segment("open \(index)", id: "s\(index)"), now: now) } }
        await brain.waitForFour()
        let fifth = Task { await engine.ingest(segment("open five", id: "fifth"), now: now) }
        for _ in 0..<100 { await Task.yield() }
        let count = await brain.requestedCount
        XCTAssertEqual(count, 4)
        await brain.release()
        for task in firstFour { _ = await task.value }
        _ = await fifth.value
    }

    func testExpiredCardsAndRevisionRecordsArePrunedAndBounded() async throws {
        let brain = EchoBrain()
        let engine = SuggestionEngine(brain: brain, accountID: "a", context: "Fictional registry",
            configuration: try .init(maximumCardsPerWindow: 1000, rateWindow: 1, lifetime: 1))
        for index in 0..<300 {
            _ = await engine.ingest(segment("open \(index)", id: "s\(index)"), now: now.addingTimeInterval(Double(index)))
        }
        let history = await engine.history(now: now.addingTimeInterval(1000))
        let retained = await engine.retainedRevisionsForTest()
        XCTAssertTrue(history.isEmpty)
        XCTAssertEqual(retained, 0)
        for index in 0..<1000 {
            _ = await engine.ingest(segment("partial", id: "partial-\(index)", final: false), now: now.addingTimeInterval(1000))
        }
        let bounded = await engine.retainedRevisionsForTest()
        XCTAssertLessThanOrEqual(bounded, 256)
    }

    func testRetainedCardsAreBoundedBeforeExpiry() async throws {
        let brain = EchoBrain()
        let engine = SuggestionEngine(brain: brain, accountID: "a", context: "Fictional registry",
            configuration: try .init(maximumCardsPerWindow: 1000, maximumRetainedCards: 4))
        var last: SuggestionUpdate?
        for index in 0..<10 { last = await engine.ingest(segment("open \(index)", id: "s\(index)"), now: now) }
        let retained = await engine.history(now: now)
        let count = await brain.requestCount
        XCTAssertEqual(retained.count, 4)
        XCTAssertEqual(last?.deferred, .capacity)
        XCTAssertEqual(count, 4)
    }

    func testConfiguredWakePhraseAndExplicitPlanSelection() async throws {
        XCTAssertEqual(CommandSequence.cancellationOrdinal("Hey Fabric: cancel the second one", wakePhrase: "Hey Fabric"), 2)
        let engine = SuggestionEngine(brain: EchoBrain(), accountID: "a", context: "Fictional registry",
            configuration: try .init(maximumCardsPerWindow: 6, wakePhrase: "Hey Fabric"))
        let first = await engine.ingest(segment("open one. Then open two", id: "plan-one"), now: now)
        let firstPlan = try XCTUnwrap(first.cards.first?.planID)
        let second = await engine.ingest(segment("open three. Then open four", id: "plan-two"), now: now)
        let secondPlan = try XCTUnwrap(second.cards.first { $0.segmentID == "plan-two" }?.planID)
        XCTAssertNotEqual(firstPlan, secondPlan)
        await engine.cancel(planID: firstPlan, ordinal: 2, now: now)
        _ = await engine.ingest(segment("Hey Fabric: cancel the second one", id: "cancel"), now: now)
        let history = await engine.history(now: now)
        XCTAssertEqual(history.filter { $0.state == .dismissed }.count, 2)
    }
}
