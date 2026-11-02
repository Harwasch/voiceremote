import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum SocketMessage: Sendable, Equatable { case text(String), binary(Data) }
/// Implementations must unblock receive/send on close. One independent socket per utterance.
public protocol SttSocket: Sendable {
    func send(_ message: SocketMessage) async throws
    func receive() async throws -> SocketMessage
    func close() async
}
public protocol SttSocketFactory: Sendable {
    func connect(to url: URL) async throws -> any SttSocket
}

/// Proxy forwards the vendor wire protocol and injects credentials on the server.
/// No vendor hostname, API key, or vendor auth header is accepted here.
public struct ProxySettings: Sendable {
    public let url: URL
    public init(url: URL, allowInsecureLoopback: Bool = false) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.scheme == "wss" || (allowInsecureLoopback && parts.scheme == "ws" &&
                  ["127.0.0.1", "localhost", "::1"].contains(host)),
              !host.lowercased().hasSuffix("elevenlabs.io"),
              !host.lowercased().hasSuffix("assemblyai.com") else { throw SttFailure.transport }
        self.url = url
    }
}

/// Foundation's Linux WebSocket transport is deliberately not used: inject SttSocketFactory there.
public struct URLSessionSocketFactory: SttSocketFactory {
    public init() {}
    public func connect(to url: URL) async throws -> any SttSocket {
        #if os(Linux)
        throw SttFailure.unavailable
        #else
        let socket = URLSession.shared.webSocketTask(with: url)
        socket.resume()
        return FoundationSocket(socket)
        #endif
    }
}
#if !os(Linux)
private struct FoundationSocket: SttSocket {
    let task: URLSessionWebSocketTask
    init(_ task: URLSessionWebSocketTask) { self.task = task }
    func send(_ message: SocketMessage) async throws {
        switch message {
        case .text(let text): try await task.send(.string(text))
        case .binary(let data): try await task.send(.data(data))
        }
    }
    func receive() async throws -> SocketMessage {
        switch try await task.receive() {
        case .string(let text): return .text(text)
        case .data(let data): return .binary(data)
        @unknown default: throw SttFailure.invalidResponse
        }
    }
    func close() async { task.cancel(with: .goingAway, reason: nil) }
}
#endif

public struct CloudEngine: SttEngine {
    public enum Vendor: String, Sendable { case elevenLabs, assemblyAI }
    public let vendor: Vendor
    public let settings: ProxySettings
    public let sockets: any SttSocketFactory
    /// Maximum inactivity (including connect); successful sends and receives reset it.
    public let timeout: Duration
    public var descriptor: EngineDescriptor {
        .init(id: vendor == .elevenLabs ? "elevenlabs-scribe" : "assemblyai",
              version: vendor == .elevenLabs ? "scribe_v2_realtime" : "universal-3-5-pro", location: .cloud)
    }
    public init(vendor: Vendor, settings: ProxySettings,
                sockets: any SttSocketFactory = URLSessionSocketFactory(), timeout: Duration = .seconds(60)) {
        self.vendor = vendor; self.settings = settings; self.sockets = sockets; self.timeout = timeout
    }
    // Docs checked 2026-11-02; live service and future relay proxy are UNVERIFIED.
    // https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/realtime/event-reference
    // https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime
    // https://www.assemblyai.com/docs/streaming/api-spec/streaming-websocket
    // AssemblyAI now defaults to 3.6; explicitly retain the requested 3.5 model.
    public func connectionURL(vocabulary: Vocabulary) throws -> URL {
        guard var parts = URLComponents(url: settings.url, resolvingAgainstBaseURL: false) else {
            throw SttFailure.transport
        }
        switch vendor {
        case .elevenLabs:
            parts.queryItems = [.init(name: "model_id", value: "scribe_v2_realtime"),
                                .init(name: "audio_format", value: "pcm_16000"),
                                .init(name: "commit_strategy", value: "manual")]
            // Keyterms are supported by the current realtime API, repeated in the query string.
            parts.queryItems! += vocabulary.terms.prefix(100).map { .init(name: "keyterms", value: $0) }
        case .assemblyAI:
            let terms = try JSONEncoder().encode(Array(vocabulary.terms.prefix(100)))
            parts.queryItems = [.init(name: "speech_model", value: "universal-3-5-pro"),
                                .init(name: "sample_rate", value: "16000"),
                                .init(name: "encoding", value: "pcm_s16le"),
                                .init(name: "include_partial_turns", value: "true"),
                                .init(name: "keyterms_prompt", value: String(decoding: terms, as: UTF8.self))]
        }
        guard let url = parts.url else { throw SttFailure.transport }
        return url
    }
    public func transcribe(_ audio: AsyncStream<AudioFrame>, vocabulary: Vocabulary) -> AsyncStream<SttEvent> {
        AsyncStream { output in
            let lifetime = CloudLifetime()
            let task = Task {
                do {
                    let connected = try await sockets.connect(to: connectionURL(vocabulary: vocabulary))
                    guard await lifetime.install(connected) else { return }
                    let socket = ActivitySocket(base: connected, lifetime: lifetime)
                    let sender = Task {
                        do {
                            if vendor == .elevenLabs {
                                // Commit before the provider's automatic segment limit; serialize acknowledgement
                                // so an intermediate final can never be mistaken for the EOS final.
                                // https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/realtime/transcripts-and-commit-strategies
                                let batchLimit = AudioFrame.sampleRate * 20
                                var batchSamples = 0
                                var committed = false
                                for await frame in audio {
                                    var offset = 0
                                    while offset < frame.samples.count {
                                        try Task.checkCancellation()
                                        // Keep each wire chunk small even if capture supplies a giant frame.
                                        let count = min(frame.samples.count - offset, batchLimit - batchSamples, 1600)
                                        let chunk = try AudioFrame(samples: Array(frame.samples[offset..<(offset + count)]),
                                            timestamp: frame.timestamp + Double(offset) / Double(AudioFrame.sampleRate))
                                        try await socket.send(try json(["message_type": "input_audio_chunk",
                                            "audio_base_64": chunk.pcmData.base64EncodedString(),
                                            "sample_rate": 16000, "commit": false]))
                                        offset += count; batchSamples += count
                                        if batchSamples == batchLimit {
                                            await lifetime.expectCommit()
                                            try await socket.send(try json(["message_type": "input_audio_chunk",
                                                "audio_base_64": "", "sample_rate": 16000, "commit": true]))
                                            try await lifetime.waitForCommit()
                                            batchSamples = 0; committed = true
                                        }
                                    }
                                }
                                try Task.checkCancellation()
                                if batchSamples > 0 || !committed {
                                    await lifetime.expectCommit()
                                    await lifetime.endInput()
                                    try await socket.send(try json(["message_type": "input_audio_chunk",
                                        "audio_base_64": "", "sample_rate": 16000, "commit": true]))
                                } else {
                                    // The exact-boundary final was already acknowledged, with no residual audio.
                                    output.finish(); await socket.close()
                                }
                            } else {
                                // PCM messages must span 50–1000 ms; coalesce tiny capture frames,
                                // split oversized frames, and pad only the final sub-50-ms tail with silence.
                                // https://www.assemblyai.com/docs/streaming/message-sequence
                                let chunkBytes = 1600 // 800 PCM16 samples = 50 ms at 16 kHz.
                                var pending = Data()
                                for await frame in audio {
                                    try Task.checkCancellation()
                                    let data = frame.pcmData
                                    var offset = 0
                                    while offset < data.count {
                                        let count = min(chunkBytes - pending.count, data.count - offset)
                                        pending.append(data[offset..<(offset + count)])
                                        offset += count
                                        if pending.count == chunkBytes {
                                            try await socket.send(.binary(pending))
                                            pending.removeAll(keepingCapacity: true)
                                        }
                                    }
                                }
                                try Task.checkCancellation()
                                if !pending.isEmpty {
                                    pending.append(Data(repeating: 0, count: chunkBytes - pending.count))
                                    try await socket.send(.binary(pending))
                                }
                                try await socket.send(try json(["type": "Terminate"]))
                            }
                        } catch {
                            output.yield(.failure(.transport)); output.finish(); await socket.close()
                        }
                    }
                    await lifetime.track(sender)
                    defer { sender.cancel() }
                    do {
                        var seenTurns = Set<Int>()
                        var unfinishedTurns: [Int: String] = [:]
                        while !Task.isCancelled {
                            let message = try await socket.receive()
                            let data: Data
                            switch message {
                            case .text(let text): data = Data(text.utf8)
                            case .binary(let bytes): data = bytes
                            }
                            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                                throw SttFailure.invalidResponse
                            }
                            if vendor == .elevenLabs {
                                guard let type = object["message_type"] as? String else { throw SttFailure.invalidResponse }
                                switch type {
                                case "session_started", "warning", "committed_transcript_with_timestamps",
                                     "committed_transcript_entities", "redacted_transcript", "edited_transcript":
                                    // Informational/derived output is never a replacement for original text.
                                    break
                                case "partial_transcript":
                                    guard let text = object["text"] as? String else { throw SttFailure.invalidResponse }
                                    output.yield(.partial(text))
                                case "committed_transcript":
                                    guard let text = object["text"] as? String else { throw SttFailure.invalidResponse }
                                    let finished = try await lifetime.acknowledgeCommit(text: text, output: output)
                                    if finished {
                                        output.finish(); await socket.close(); return
                                    }
                                default: throw SttFailure.invalidResponse
                                }
                            } else {
                                guard let type = object["type"] as? String else { throw SttFailure.invalidResponse }
                                switch type {
                                case "Begin", "SpeechStarted", "Heartbeat", "SpeakerRevision", "LLMGatewayResponse": break
                                case "Turn":
                                    guard let text = object["transcript"] as? String,
                                          let final = object["end_of_turn"] as? Bool,
                                          let order = object["turn_order"] as? Int else { throw SttFailure.invalidResponse }
                                    if final {
                                        if seenTurns.insert(order).inserted {
                                            // An empty closing Turn can discard an unfinished transcript.
                                            let stable = text.isEmpty ? (unfinishedTurns[order] ?? "") : text
                                            output.yield(.final(stable))
                                            unfinishedTurns.removeValue(forKey: order)
                                        }
                                    } else if !seenTurns.contains(order) {
                                        if !text.isEmpty { unfinishedTurns[order] = text }
                                        output.yield(.partial(text))
                                    }
                                case "Termination":
                                    // Docs allow in-flight finals but do not guarantee one for every partial.
                                    // Preserve latest nonempty partials only after the graceful Termination ack.
                                    for order in unfinishedTurns.keys.sorted() {
                                        if !seenTurns.contains(order), let text = unfinishedTurns[order] { output.yield(.final(text)) }
                                    }
                                    output.finish(); await socket.close(); return
                                default: throw SttFailure.invalidResponse
                                }
                            }
                        }
                    } catch {
                        if !Task.isCancelled { output.yield(.failure((error as? SttFailure) ?? .transport)) }
                    }
                    await socket.close()
                } catch { output.yield(.failure((error as? SttFailure) ?? .transport)) }
                output.finish()
                await lifetime.stop()
            }
            let timer = Task {
                while let remaining = await lifetime.remainingIdleTime(timeout) {
                    if remaining <= .zero {
                        output.yield(.failure(.timedOut)); output.finish()
                        task.cancel(); await lifetime.stop(); return
                    }
                    do { try await Task.sleep(for: remaining) } catch { return }
                }
            }
            output.onTermination = { _ in
                task.cancel(); timer.cancel()
                Task { await lifetime.stop() }
            }
        }
    }
    private func json(_ object: [String: Any]) throws -> SocketMessage {
        .text(String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))
    }
}

/// Closing is independent of the receive task, including cancellation while connect is suspended.
private actor CloudLifetime {
    private var lastActivity = ContinuousClock.now
    var socket: (any SttSocket)?
    var sender: Task<Void, Never>?
    var stopped = false
    var inputEnded = false
    var pendingCommit = false
    var acknowledgement: CheckedContinuation<Void, any Error>?
    func install(_ socket: any SttSocket) async -> Bool {
        guard !stopped else { await socket.close(); return false }
        self.socket = socket
        activity()
        return true
    }
    func activity() { lastActivity = ContinuousClock.now }
    func remainingIdleTime(_ timeout: Duration) -> Duration? {
        guard !stopped else { return nil }
        return timeout - lastActivity.duration(to: ContinuousClock.now)
    }
    func track(_ task: Task<Void, Never>) {
        if stopped { task.cancel() } else { sender = task }
    }
    func endInput() { inputEnded = true }
    func expectCommit() { pendingCommit = true }
    func waitForCommit() async throws {
        guard !stopped else { throw SttFailure.cancelled }
        if pendingCommit {
            try await withCheckedThrowingContinuation { acknowledgement = $0 }
        }
    }
    func acknowledgeCommit(text: String, output: AsyncStream<SttEvent>.Continuation) throws -> Bool {
        guard pendingCommit else { throw SttFailure.invalidResponse }
        // Publish before waking the sender: EOS at an exact batch boundary may finish the stream.
        output.yield(.final(text))
        pendingCommit = false
        acknowledgement?.resume(); acknowledgement = nil
        return inputEnded
    }
    func stop() async {
        stopped = true; sender?.cancel(); sender = nil
        acknowledgement?.resume(throwing: SttFailure.cancelled); acknowledgement = nil
        let old = socket; socket = nil
        await old?.close()
    }
}

/// Covers both directions; outbound audio counts even while a provider has no new text.
private struct ActivitySocket: SttSocket {
    let base: any SttSocket
    let lifetime: CloudLifetime
    func send(_ message: SocketMessage) async throws {
        try await base.send(message)
        await lifetime.activity()
    }
    func receive() async throws -> SocketMessage {
        let message = try await base.receive()
        await lifetime.activity()
        return message
    }
    func close() async { await base.close() }
}
