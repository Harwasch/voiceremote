/// Routing is evaluated once for each utterance. The caller supplies live model/power/network state.
public struct EngineRouter: Sendable {
    public struct Conditions: Sendable {
        public var online: Bool
        public var cloudConsent: Bool
        public var hot: Bool
        public var lowBattery: Bool
        public var maxAccuracy: Bool
        public init(online: Bool, hot: Bool = false, lowBattery: Bool = false, maxAccuracy: Bool = false, cloudConsent: Bool = false) {
            self.cloudConsent = cloudConsent
            self.online = online; self.hot = hot; self.lowBattery = lowBattery; self.maxAccuracy = maxAccuracy
        }
    }
    /// Unknown battery level (negative) does not imply low battery. 20% is a routing policy, not a measured target.
    public static func lowBattery(level: Float, lowPowerMode: Bool) -> Bool {
        lowPowerMode || (level.isFinite && level >= 0 && level <= 0.2)
    }
    public enum Selection: Equatable, Sendable {
        case engine(String)
        /// Offline with no installed local model: remain idle, with no user-facing error.
        case silentlyUnavailable
    }
    public init() {}
    public func select(onDevice: [EngineDescriptor], cloud: [EngineDescriptor],
                       conditions: Conditions, preferredID: String? = nil) -> Selection {
        let local = onDevice.filter { $0.location == .onDevice }
        let remote = cloud.filter { $0.location == .cloud && conditions.cloudConsent }
        if !conditions.online {
            return local.first(where: { $0.id == preferredID }).map { .engine($0.id) }
                ?? local.first.map { .engine($0.id) } ?? .silentlyUnavailable
        }
        if local.isEmpty || conditions.hot || conditions.lowBattery || conditions.maxAccuracy,
           let engine = remote.first(where: { $0.id == preferredID }) ?? remote.first { return .engine(engine.id) }
        if let preferred = (local + remote).first(where: { $0.id == preferredID }) {
            return .engine(preferred.id)
        }
        return (local.first ?? remote.first).map { .engine($0.id) } ?? .silentlyUnavailable
    }
}

extension EngineRouter {
    /// The caller includes only ready engines (installed models or configured proxies).
    /// Freeze routing/vocabulary; clean the complete utterance once at EOS, never isolated segments.
    public func transcribe(source: any CaptureSource, engines: [any SttEngine], conditions: Conditions,
                           vocabulary: Vocabulary, preferredID: String? = nil,
                           cleanup: FailSafeCleanup = FailSafeCleanup(), requireComplete: Bool = false) -> AsyncStream<SttEvent> {
        let selection = select(onDevice: engines.map(\.descriptor), cloud: engines.map(\.descriptor),
                               conditions: conditions, preferredID: preferredID)
        guard Set(engines.map { $0.descriptor.id }).count == engines.count,
              case .engine(let id) = selection,
              let engine = engines.first(where: { $0.descriptor.id == id &&
                  ((conditions.online && conditions.cloudConsent) || $0.descriptor.location == .onDevice) }) else {
            return AsyncStream { $0.finish() }
        }
        return AsyncStream { output in
            output.yield(.selected(engine.descriptor))
            let worker = Task {
                var stable: [String] = []
                var terminalFailure: SttFailure?
                let audio = AsyncStream<AudioFrame>.makeStream()
                let messages = AsyncStream<CaptureMessage>.makeStream()
                let feeder = Task {
                    for await event in source.events() {
                        if Task.isCancelled { break }
                        switch event {
                        case .frame(let frame): audio.continuation.yield(frame)
                        case .interrupted:
                            messages.continuation.yield(.interrupted)
                            audio.continuation.finish()
                            return
                        }
                    }
                    audio.continuation.finish()
                    messages.continuation.yield(.captureEnded)
                }
                let reader = Task {
                    for await event in engine.transcribe(audio.stream, vocabulary: vocabulary) {
                        messages.continuation.yield(.event(event))
                    }
                    messages.continuation.yield(.engineEnded)
                }
                defer { feeder.cancel(); reader.cancel(); audio.continuation.finish(); messages.continuation.finish() }
                var captureEnded = false, engineEnded = false
                engineEvents: for await message in messages.stream {
                    if Task.isCancelled { break }
                    switch message {
                    case .interrupted:
                        output.yield(.failure(.interrupted)); output.finish(); return
                    case .captureEnded: captureEnded = true
                    case .engineEnded: engineEnded = true
                    case .event(let event):
                    switch event {
                    case .selected: break // Selection is frozen by this router for the utterance.
                    case .final(let raw):
                        stable.append(raw)
                        // Engine finals are segments, not sentence boundaries. Show them without cleaning
                        // until EOS, so a split "do not" / "send" stays a single prohibition.
                        output.yield(.partial(stable.joined(separator: " ")))
                    case .partial(let text):
                        output.yield(.partial((stable + [text]).joined(separator: " ")))
                    case .failure(.interrupted):
                        output.yield(.failure(.interrupted)); output.finish(); return
                    case .failure(let failure):
                        terminalFailure = failure
                        break engineEvents
                    }
                    }
                    if captureEnded && engineEnded { break engineEvents }
                }
                if requireComplete, !Task.isCancelled, let failure = terminalFailure {
                    output.yield(.failure(failure)); output.finish(); return
                }
                if !Task.isCancelled, !stable.isEmpty {
                    let raw = stable.joined(separator: " ")
                    let text = (try? await cleanup.clean(raw, vocabulary: vocabulary)) ?? raw
                    if !Task.isCancelled { output.yield(.final(text)) }
                }
                if !Task.isCancelled, conditions.online, let failure = terminalFailure { output.yield(.failure(failure)) }
                output.finish()
            }
            output.onTermination = { _ in worker.cancel() }
        }
    }
}

private enum CaptureMessage: Sendable { case event(SttEvent), captureEnded, engineEnded, interrupted }
