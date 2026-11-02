import VoiceRemoteProtocol

public enum TargetSelection: Equatable, Sendable {
    case auto
    case device(String)
}

/// Mode, capture and destination are independent controls (REQ-3/4).
public struct AppState: Equatable, Sendable {
    public private(set) var mode: Mode = .dictation
    public private(set) var capture: CaptureState = .off
    public private(set) var target: TargetSelection = .auto
    public init() {}
    public mutating func setMode(_ mode: Mode) { self.mode = mode }
    public mutating func setCapture(_ capture: CaptureState) { self.capture = capture }
    public mutating func setTarget(_ target: TargetSelection) { self.target = target }
}

/// Feed monotonic milliseconds. Call advance while held, including at 300 ms.
/// Two short (<300 ms) taps separated by <=500 ms lock capture. A single tap
/// never starts capture. Holds start at 300 ms and clear the pending tap.
public struct CaptureTrigger: Sendable {
    public private(set) var capture: CaptureState = .off
    public let doubleTapWindow: Int64
    private var pressedAt: Int64?
    private var previousRelease: Int64?
    private var lastTime: Int64 = 0
    private var beganLocked = false
    public init(doubleTapWindow: Int64 = 500) {
        self.doubleTapWindow = max(0, doubleTapWindow)
    }
    public mutating func press(at time: Int64) {
        guard time >= lastTime, pressedAt == nil else { return }
        lastTime = time
        pressedAt = time
        beganLocked = capture == .continuous
    }
    public mutating func advance(to time: Int64) {
        guard time >= lastTime else { return }
        lastTime = time
        if let start = pressedAt, time - start >= 300 {
            previousRelease = nil
            capture = .hold
        }
    }
    public mutating func release(at time: Int64) {
        guard time >= lastTime, let start = pressedAt else { return }
        lastTime = time
        pressedAt = nil
        if time - start >= 300 {
            capture = .off
            previousRelease = nil
        } else if beganLocked {
            previousRelease = nil
        } else if let previous = previousRelease, start - previous <= doubleTapWindow {
            capture = .continuous
            previousRelease = nil
        } else {
            capture = .off
            previousRelease = time
        }
    }
    public mutating func stop() {
        capture = .off
        pressedAt = nil
        previousRelease = nil
        beganLocked = false
    }
}
