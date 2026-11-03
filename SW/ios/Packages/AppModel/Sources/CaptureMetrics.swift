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
                clipping: Double(clipped) / Double(samples), dropouts: lost, proximity: 0)
        }
    }
    public static func select(choice: CaptureChoice, remoteReady: Bool, phone: SourceQuality?, remote: SourceQuality?) throws -> CaptureChoice {
        if choice == .phone { return .phone }
        if choice == .remote {
            guard remoteReady else { throw RemoteContractError.notReady }
            return .remote
        }
        if remoteReady, let remote, remote.score != nil,
           phone == nil || phone?.score == nil || remote.score! > phone!.score! { return .remote }
        return .phone
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
