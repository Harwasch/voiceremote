// Purpose: bounded PCM quality telemetry and explicit source selection.
// Inputs: captured PCM only; score/SNR heuristic needs named-device validation.
import Foundation
import Stt

public enum CaptureChoice: String, CaseIterable, Sendable { case automatic, phone, remote }
public final class CaptureMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var samples = 0
    private var clipped = 0
    private var low = Double.infinity
    private var high = 0.0
    private var lost = 0
    private var observedAt: TimeInterval?
    public init() {}
    public func observe(_ event: CaptureEvent) {
        lock.withLock {
            observedAt = ProcessInfo.processInfo.systemUptime
            switch event {
            case .interrupted: lost = 1
            case .frame(let frame):
                let values = frame.samples.map { Double($0) }
                guard !values.isEmpty else { return }
                samples += values.count; clipped += values.filter { abs($0) >= 32760 }.count
                let rms = sqrt(values.reduce(0) { $0 + $1 * $1 } / Double(values.count))
                low = min(low, rms); high = max(high, rms)
            }
        }
    }
    public func quality(id: String) -> SourceQuality? {
        lock.withLock {
            guard samples > 0, let observedAt,
                  ProcessInfo.processInfo.systemUptime - observedAt <= 30 else { return nil }
            // Envelope ratio is only an estimated SNR. Proximity is unknown,
            // so it contributes zero; never invent a distance or speaker match.
            return SourceQuality(id: id, snrDB: 20 * log10(max(1, high) / max(1, low)),
                clipping: Double(clipped) / Double(samples), dropouts: lost, proximity: nil)
        }
    }
    public static func select(choice: CaptureChoice, remoteReady: Bool, phone: SourceQuality?, remote: SourceQuality?) throws -> CaptureChoice {
        if choice == .phone { return .phone }
        if choice == .remote {
            guard remoteReady else { throw RemoteContractError.notReady }
            return .remote
        }
        // Past measurements cannot select a new utterance. Auto requires live
        // candidates through UtteranceCaptureSession, including a valid phone.
        throw RemoteContractError.notReady
    }
    public static func current(_ quality: SourceQuality?, recordedIdentity: String?, currentIdentity: String?) -> SourceQuality? {
        guard let currentIdentity, !currentIdentity.isEmpty, recordedIdentity == currentIdentity else { return nil }
        return quality
    }
}

@MainActor public final class MeasuredCaptureSession: CaptureSession {
    private let source: any CaptureSession
    private let metrics: CaptureMetrics
    private let didStart: @MainActor () -> Void
    public init(source: any CaptureSession, metrics: CaptureMetrics, didStart: @escaping @MainActor () -> Void = {}) {
        self.source = source; self.metrics = metrics; self.didStart = didStart
    }
    public func start() throws { try source.start(); didStart() }
    public func finish() { source.finish() }
    public func interrupt() { metrics.observe(.interrupted); source.interrupt() }
    nonisolated public func frames() -> AsyncStream<AudioFrame> { AsyncStream { $0.finish() } }
    nonisolated public func events() -> AsyncStream<CaptureEvent> {
        let source = source, metrics = metrics
        return AsyncStream(bufferingPolicy: .bufferingNewest(6400)) { output in
            let task = Task {
                for await event in source.events() {
                    if Task.isCancelled { break }
                    metrics.observe(event)
                    if case .dropped = output.yield(event) {
                        metrics.observe(.interrupted); output.yield(.interrupted); break
                    }
                }
                output.finish()
            }
            output.onTermination = { _ in task.cancel() }
        }
    }
}

/// One utterance, fresh meters, at most two competing live adapters. A bounded
/// 200 ms PCM prefix is withheld from STT until selection; no words are spliced.
/// The 500 ms acquisition deadline and envelope score need device calibration.
@MainActor public final class UtteranceCaptureSession: CaptureSession {
    public struct Candidate {
        let id: String
        let source: any CaptureSession
        let valid: @MainActor () -> Bool
        let name: @MainActor () -> String
        public init(id: String, source: any CaptureSession, valid: @escaping @MainActor () -> Bool = { true }, name: (@MainActor () -> String)? = nil) {
            self.id = id; self.source = source; self.valid = valid; self.name = name ?? { id }
        }
    }
    private let candidates: [Candidate]
    private let meters: [CaptureMetrics]
    private var sourceNames: [String]
    private var prefixes: [[AudioFrame]]
    private var counts: [Int]
    private var invalid: Set<Int> = []
    private var ended: Set<Int> = []
    private var tasks: [Task<Void, Never>] = []
    private var deadline: Task<Void, Never>?
    private var lastFrameAt: [TimeInterval]
    private var nextTimestamp: [TimeInterval]
    private var selected: Int?
    private var closed = false
    private var started = false
    private let didSelect: @MainActor (String) -> Void
    nonisolated private let output = AsyncStream<CaptureEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
    public var selectedID: String? { selected.map { sourceNames[$0] } }
    public struct Diagnostic: Sendable {
        public let id: String
        public let samples: Int
        public let ageMilliseconds: Double?
        public let identityCurrent: Bool
        public let rejected: Bool
        public let selected: Bool
        public let quality: SourceQuality?
        public var proximity: Double? { quality?.proximity }
    }
    /// In-memory, named-source evidence for the owner's comparison; never audio.
    public var diagnostics: [Diagnostic] {
        let now = ProcessInfo.processInfo.systemUptime
        return candidates.indices.map { i in Diagnostic(id: sourceNames[i], samples: counts[i],
            ageMilliseconds: counts[i] > 0 ? max(0, now - lastFrameAt[i]) * 1000 : nil,
            identityCurrent: candidates[i].valid(), rejected: invalid.contains(i), selected: selected == i,
            quality: meters[i].quality(id: sourceNames[i])) }
    }
    public init(candidates: [Candidate], didSelect: @escaping @MainActor (String) -> Void = { _ in }) {
        self.candidates = Array(candidates.prefix(2)); self.didSelect = didSelect
        meters = self.candidates.map { _ in CaptureMetrics() }
        sourceNames = self.candidates.map(\.id)
        prefixes = self.candidates.map { _ in [] }; counts = self.candidates.map { _ in 0 }
        lastFrameAt = self.candidates.map { _ in ProcessInfo.processInfo.systemUptime }
        nextTimestamp = self.candidates.map { _ in 0 }
    }
    public static func factory(phone: @escaping CaptureFactory, remote: CaptureFactory?, remoteName: String,
                               phoneName: @escaping @MainActor () -> String = { "Phone / connected headset" },
                               phoneIdentity: @escaping @MainActor () -> String? = { nil },
                               valid: @escaping @MainActor () -> Bool,
                               remoteValid: @escaping @MainActor () -> Bool,
                               didSelect: @escaping @MainActor (String) -> Void) -> CaptureFactory {
        return {
            guard valid() else { throw RemoteContractError.notReady }
            // PhoneCapture chooses the actual phone/HFP route in start(). Pin
            // that identity afterwards; a later route rebuild cannot mix devices.
            var routeStarted = false
            var pinnedRoute: String?
            var candidates = [Candidate(id: "phone", source: try await phone(),
                valid: { valid() && (!routeStarted || phoneIdentity() == pinnedRoute) },
                name: { routeStarted = true; pinnedRoute = phoneIdentity(); return phoneName() })]
            if let remote, let source = try? await remote() {
                candidates.append(Candidate(id: remoteName, source: source, valid: { valid() && remoteValid() }))
            }
            return UtteranceCaptureSession(candidates: candidates, didSelect: didSelect)
        }
    }
    public func start() throws {
        guard !started, !closed, !candidates.isEmpty else { throw RemoteContractError.notReady }
        started = true
        for i in candidates.indices {
            do { guard candidates[i].valid() else { throw RemoteContractError.notReady }; try candidates[i].source.start() }
            catch { invalid.insert(i); candidates[i].source.interrupt(); continue }
            sourceNames[i] = candidates[i].name()
            let source = candidates[i].source
            tasks.append(Task { [weak self] in
                for await event in source.events() {
                    guard !Task.isCancelled, let self, !closed else { return }
                    receive(event, from: i)
                }
                self?.end(i)
            })
        }
        deadline = Task { [weak self] in
            let start = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self, !closed else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if let selected {
                    if !candidates[selected].valid() || now - lastFrameAt[selected] >= 0.5 { interrupt(); return }
                } else if now - start >= 0.5 { decide(expired: true) }
            }
        }
        decide()
    }
    private func receive(_ event: CaptureEvent, from i: Int) {
        guard !closed, !invalid.contains(i), selected == nil || selected == i else { return }
        guard candidates[i].valid() else { fail(i); return }
        switch event {
        case .interrupted: fail(i)
        case .frame(let frame):
            guard !frame.samples.isEmpty, frame.samples.count <= 16_000,
                  frame.timestamp.isFinite,
                  counts[i] == 0 || abs(frame.timestamp - nextTimestamp[i]) <= 1.0 / 16_000 else { fail(i); return }
            meters[i].observe(event)
            nextTimestamp[i] = frame.timestamp + Double(frame.samples.count) / 16_000
            lastFrameAt[i] = ProcessInfo.processInfo.systemUptime
            if selected == i { counts[i] = min(16_000, counts[i] + frame.samples.count); emit(event); return }
            // Bounded samples AND frames: tiny/empty frames cannot grow memory.
            guard !frame.samples.isEmpty, counts[i] + frame.samples.count <= 16_000, prefixes[i].count < 64 else { fail(i); return }
            counts[i] += frame.samples.count; prefixes[i].append(frame)
            decide()
        }
    }
    private func fail(_ i: Int) {
        invalid.insert(i); prefixes[i] = []; meters[i].observe(.interrupted)
        if selected == i { interrupt() } else { candidates[i].source.interrupt(); decide() }
    }
    private func end(_ i: Int) {
        guard !closed else { return }
        ended.insert(i)
        if selected == i { close(interrupted: false) } else { decide() }
    }
    private func decide(expired: Bool = false) {
        guard !closed, selected == nil else { return }
        for i in candidates.indices where !candidates[i].valid() { invalid.insert(i); prefixes[i] = [] }
        guard expired || candidates.indices.allSatisfy({ invalid.contains($0) || ended.contains($0) || counts[$0] >= 3200 }) else { return }
        // A stalled/short candidate cannot win on a stale or unrepresentative prefix.
        let now = ProcessInfo.processInfo.systemUptime
        let valid = candidates.indices.filter { !invalid.contains($0) && counts[$0] >= 3200 && now - lastFrameAt[$0] < 0.5 }
        guard let id = SourceQuality.best(valid.compactMap { meters[$0].quality(id: String($0)) }),
              let winner = Int(id) else { interrupt(); return }
        selected = winner; didSelect(sourceNames[winner])
        for i in candidates.indices where i != winner { candidates[i].source.finish(); prefixes[i] = [] }
        let prefix = prefixes[winner]; prefixes[winner] = []
        for frame in prefix { emit(.frame(frame)) }
        if ended.contains(winner) { close(interrupted: false) }
    }
    private func emit(_ event: CaptureEvent) {
        if case .dropped = output.continuation.yield(event) { interrupt() }
    }
    private func close(interrupted: Bool) {
        guard !closed else { return }; closed = true
        deadline?.cancel(); tasks.forEach { $0.cancel() }; tasks = []
        if interrupted { output.continuation.yield(.interrupted) }
        output.continuation.finish()
        for candidate in candidates { if interrupted { candidate.source.interrupt() } else { candidate.source.finish() } }
        prefixes = candidates.map { _ in [] }
    }
    public func finish() {
        guard !closed else { return }
        if selected == nil { decide(expired: true) }
        close(interrupted: false)
    }
    public func interrupt() {
        if let selected { invalid.insert(selected); meters[selected].observe(.interrupted) }
        close(interrupted: true)
    }
    nonisolated public func frames() -> AsyncStream<AudioFrame> { AsyncStream { $0.finish() } }
    nonisolated public func events() -> AsyncStream<CaptureEvent> { output.stream }
}
