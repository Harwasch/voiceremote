// Purpose: remote controls using Core trigger semantics, without approval authority.
// Inputs: BLE v1.1 snapshots/ticks; synthetic transitions are portable-tested.
import Foundation
import Core
import Stt
import VoiceRemoteProtocol

public struct RemoteControls: Sendable {
    public enum Action: Equatable, Sendable {
        case positions(CaptureState, Mode), stop, boundary, startHold, releaseHold(Bool), startContinuous, cycleTarget
    }
    private var trigger = CaptureTrigger()
    public var triggerCapture: CaptureState { trigger.capture }
    private var clock: UInt32?
    private var elapsed: Int64 = 0
    private var down: UInt32?
    private var released = false
    private var capture: UInt8 = 0
    private var mode: UInt8 = 0
    public init() {}
    public mutating func reset() { self = Self() }
    /// Call only for a newly accepted tracker sequence, including snapshots.
    public mutating func accept(_ input: RemoteInput, edge: Bool, recording: Bool = false) -> [Action] {
        // Extend the remote's modulo clock. Arrival/batch time never classifies a tap.
        var invalidClock = false
        if let clock {
            let delta = input.tick &- clock
            if delta >= 0x80000000 { invalidClock = true; trigger.stop(); down = nil; released = false }
            else { elapsed += Int64(delta) }
        }
        clock = input.tick
        let changed = capture != input.capture || mode != input.mode
        capture = input.capture; mode = input.mode
        let physical = Action.positions(input.capture == 0 ? .off : input.capture == 1 ? .hold : .continuous,
            input.mode == 0 ? .dictation : .ai_control)
        let positions = input.capture == 1 && trigger.capture == .continuous
            ? Action.positions(.continuous, input.mode == 0 ? .dictation : .ai_control) : physical
        if invalidClock { released = !input.pressed; return [.stop, physical] }
        if !edge {
            if changed || input.status & 2 != 0 {
                trigger.stop(); down = nil; released = !input.pressed
                return [.stop, physical]
            }
            if !input.pressed { released = true }
            return [positions]
        }
        if input.capture == 0 || input.status & 2 != 0 {
            trigger.stop(); down = nil; released = !input.pressed; return [.stop, physical]
        }
        switch input.event {
        case 1 where input.capture == 1 && released:
            trigger.press(at: elapsed)
            down = input.tick; released = false
            return [positions] + (trigger.capture == .continuous ? [] : [.startHold])
        case 2:
            let wasHolding = down != nil
            let accepted = down.map { input.tick &- $0 >= 300 && input.tick &- $0 < 0x80000000 } ?? false
            let wasLocked = trigger.capture == .continuous
            trigger.advance(to: elapsed); trigger.release(at: elapsed)
            down = nil; released = true
            guard input.capture == 1 && wasHolding else { return [positions] }
            if wasLocked { return accepted ? [physical, .boundary] : [positions] }
            return [positions, .releaseHold(accepted)] + (trigger.capture == .continuous ? [.positions(.continuous, input.mode == 0 ? .dictation : .ai_control), .startContinuous] : [])
        case 3:
            trigger.stop(); down = nil; released = !input.pressed; return [.stop, physical, .cycleTarget]
        case 4, 5:
            let holdEnd: [Action] = down.map { [.releaseHold(input.tick &- $0 >= 300 && input.tick &- $0 < 0x80000000)] } ?? []
            trigger.stop(); down = nil; released = !input.pressed
            return holdEnd + [.boundary, physical] + (input.capture == 2 && (input.event == 4 || recording) ? [.startContinuous] : [])
        default: return [positions]
        }
    }
}

/// Hold audio is provisional until release qualifies using the remote clock.
/// The bound is defensive (120 s), not a device performance claim. No short
/// gesture reaches STT; overflow/loss discards the entire pending segment.
public struct RemoteHoldBuffer: Sendable {
    private var pending: [AudioFrame]? = []
    private var pendingSamples = 0
    public init(provisional: Bool) { if !provisional { pending = nil } }
    public mutating func frame(_ frame: AudioFrame) throws -> [CaptureEvent] {
        guard pending != nil else { return [.frame(frame)] }
        guard pending!.count < 6000, frame.samples.count <= 1_920_000 - pendingSamples else {
            pending = []; pendingSamples = 0; throw RemoteContractError.loss
        }
        pendingSamples += frame.samples.count
        pending!.append(frame); return []
    }
    public mutating func qualify() -> [CaptureEvent] {
        let frames = pending ?? []; pending = nil; pendingSamples = 0
        return frames.map(CaptureEvent.frame)
    }
    public var provisional: Bool { pending != nil }
}

extension VoiceAppModel {
    public func cycleRemoteTarget() {
        let ids = [TargetSelection.auto, .device(phoneID)] + RemotePhoneState.visibleTargets(devices: devices,
            phoneID: phoneID, selection: controls.target).map { .device($0.device_id) }
        let current = ids.firstIndex(of: controls.target) ?? 0
        setTarget(ids[(current + 1) % ids.count])
    }
}

/// Keeps competing streams provisional together: rejected taps cannot reach STT
/// even when the selected candidate is the phone. Qualification uses device ticks.
@MainActor public final class QualifiedCaptureSession: CaptureSession {
    private let source: any CaptureSession
    private var hold = RemoteHoldBuffer(provisional: true)
    private var task: Task<Void, Never>?
    private var ended = false
    private var closed = false
    nonisolated private let output = AsyncStream<CaptureEvent>.makeStream(bufferingPolicy: .bufferingNewest(6400))
    public init(source: any CaptureSession) { self.source = source }
    public func start() throws {
        try source.start()
        task = Task { [weak self, source] in
            for await event in source.events() {
                guard !Task.isCancelled, let self, !closed else { return }
                switch event {
                case .interrupted: interrupt(); return
                case .frame(let frame):
                    do { for event in try hold.frame(frame) { emit(event) } }
                    catch { interrupt(); return }
                }
            }
            guard let self, !closed else { return }
            ended = true
            if !hold.provisional { finish() }
        }
    }
    private func emit(_ event: CaptureEvent) {
        if case .dropped = output.continuation.yield(event) { interrupt() }
    }
    public func qualify() {
        guard !closed else { return }
        for event in hold.qualify() { emit(event) }
        if ended { finish() }
    }
    public func finish() {
        guard !closed else { return }
        if hold.provisional { interrupt(); return }
        closed = true; task?.cancel(); task = nil; source.finish(); output.continuation.finish()
    }
    public func interrupt() {
        guard !closed else { return }; closed = true
        task?.cancel(); task = nil; source.interrupt()
        output.continuation.yield(.interrupted); output.continuation.finish()
    }
    nonisolated public func frames() -> AsyncStream<AudioFrame> { AsyncStream { $0.finish() } }
    nonisolated public func events() -> AsyncStream<CaptureEvent> { output.stream }
}
