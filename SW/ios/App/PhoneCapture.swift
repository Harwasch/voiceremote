import Foundation
@preconcurrency import AVFoundation
import Speech
import AppModel
import Stt

/// No audio file writes. Conversion and timestamps belong to this capture only.
@MainActor final class PhoneCapture: CaptureSession {
    private let engine = AVAudioEngine()
    private let stream = AsyncStream<CaptureEvent>.makeStream(bufferingPolicy: .bufferingNewest(128))
    private var observers: [NSObjectProtocol] = []
    private var started = false
    private var sessionActive = false
    private var tapInstalled = false
    private var reconfiguring = false
    private var tapRate: Double = 0
    private var tapChannels: AVAudioChannelCount = 0
    private let clock = PCMClock()
    private let interrupted: @MainActor () -> Void
    init(interrupted: @escaping @MainActor () -> Void) { self.interrupted = interrupted }
    nonisolated func events() -> AsyncStream<CaptureEvent> { stream.stream }
    nonisolated func frames() -> AsyncStream<AudioFrame> {
        // Consumers use events(); this compatibility method cannot conceal a loss.
        AsyncStream { output in
            let task = Task {
                for await event in events() {
                    if case .frame(let frame) = event { output.yield(frame) } else { break }
                }
                output.finish()
            }
            output.onTermination = { _ in task.cancel() }
        }
    }
    static func requestPermissions() async -> Bool {
        let microphone = await AVAudioApplication.requestRecordPermission()
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in continuation.resume(returning: status == .authorized) }
        }
        return microphone && speech
    }
    func start() throws {
        let session = AVAudioSession.sharedInstance()
        // Apple checked 2026-11-02: HFP enables input; A2DP is output-only.
        // https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/allowbluetoothhfp
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .allowBluetoothA2DP])
        try session.setActive(true)
        sessionActive = true
        if let bluetooth = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
            try session.setPreferredInput(bluetooth)
        }
        try installTap()
        engine.prepare(); try engine.start(); started = true
        // Startup's category/preferred-HFP changes precede observer installation.
        observe(session: session)
    }
    private func installTap() throws {
        let input = engine.inputNode, format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: outputFormat) else { throw SttFailure.invalidAudio }
        converter.primeMethod = .none
        let sink = PCMConverter(converter: converter, format: outputFormat, output: stream.continuation, clock: clock)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: PCMConverter.tap(for: sink))
        tapInstalled = true; tapRate = format.sampleRate; tapChannels = format.channelCount
    }
    private func observe(session: AVAudioSession) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { @Sendable [weak self] notification in
            let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            let event: AudioRouteEvent
            switch reason {
            case .oldDeviceUnavailable: event = .oldDeviceUnavailable
            case .categoryChange: event = .categoryChanged
            case .newDeviceAvailable: event = .newDeviceAvailable
            case .routeConfigurationChange, .wakeFromSleep, .override: event = .configurationChanged
            default: event = .other
            }
            Task { @MainActor [weak self] in self?.handle(AudioRoutePolicy.action(for: event)) }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in self?.handle(.restart) }
        })
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(center.addObserver(forName: name, object: session, queue: .main) { @Sendable [weak self] notification in
                if notification.name == AVAudioSession.interruptionNotification,
                   let kind = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                   kind == AVAudioSession.InterruptionType.ended.rawValue { return }
                Task { @MainActor [weak self] in self?.handle(.stop) }
            })
        }
    }
    private func handle(_ action: AudioRouteAction) {
        guard started, !reconfiguring else { return }
        switch action {
        case .ignore: return
        case .stop: interrupt(); interrupted()
        case .restart:
            let format = engine.inputNode.outputFormat(forBus: 0)
            guard !engine.isRunning || format.sampleRate != tapRate || format.channelCount != tapChannels else { return }
            reconfiguring = true; defer { reconfiguring = false }
            engine.stop()
            if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
            do { try installTap(); engine.prepare(); try engine.start() }
            catch { interrupt(); interrupted() }
        }
    }
    func finish() { end(interrupted: false) }
    func interrupt() { end(interrupted: true) }
    private func end(interrupted: Bool) {
        if interrupted { stream.continuation.yield(.interrupted) }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine.stop(); started = false
        for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers = []
        stream.continuation.finish()
        if sessionActive {
            sessionActive = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

/// AVAudioEngine calls the tap serially. This object and its converter are confined to that tap.
private final class PCMConverter: @unchecked Sendable {
    let converter: AVAudioConverter
    let format: AVAudioFormat
    let output: AsyncStream<CaptureEvent>.Continuation
    private let clock: PCMClock
    init(converter: AVAudioConverter, format: AVAudioFormat, output: AsyncStream<CaptureEvent>.Continuation, clock: PCMClock) {
        self.converter = converter; self.format = format; self.output = output; self.clock = clock
    }
    // Created outside MainActor isolation; AVAudioEngine invokes this on its audio thread.
    nonisolated static func tap(for sink: PCMConverter) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { @Sendable [sink] buffer, _ in sink.consume(buffer) }
    }
    func consume(_ input: AVAudioPCMBuffer) {
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16_000 / input.format.sampleRate) + 32)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { output.yield(.interrupted); return }
        var supplied = false, error: NSError?
        let status = converter.convert(to: buffer, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        guard error == nil, status != .error, let samples = buffer.int16ChannelData?[0] else { output.yield(.interrupted); return }
        let length = Int(buffer.frameLength)
        if let frame = try? AudioFrame(samples: Array(UnsafeBufferPointer(start: samples, count: length)), timestamp: clock.advance(by: length)) {
            if case .dropped = output.yield(.frame(frame)) { output.yield(.interrupted); output.finish() }
        }
    }
}

/// Shared timeline survives a format-driven tap replacement; no timestamp rewind.
private final class PCMClock: @unchecked Sendable {
    private let lock = NSLock()
    private var samples = 0
    func advance(by count: Int) -> TimeInterval {
        lock.withLock { let time = Double(samples) / 16_000; samples += count; return time }
    }
}
