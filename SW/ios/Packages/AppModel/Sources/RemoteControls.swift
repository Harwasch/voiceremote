// Purpose: remote controls without approval authority or tap-lock.
// Inputs: BLE v1.1 snapshots/ticks; synthetic transitions are portable-tested.
import Foundation
import Core
import Stt
import VoiceRemoteProtocol

public struct RemoteControls: Sendable {
    public enum Action: Equatable, Sendable {
        case positions(CaptureState, Mode), stop, boundary, startHold, releaseHold(Bool), startContinuous, cycleTarget
    }
    private var down: UInt32?
    private var released = false
    private var capture: UInt8 = 0
    private var mode: UInt8 = 0
    public init() {}
    public mutating func reset() { self = Self() }
    /// Call only for a newly accepted tracker sequence, including snapshots.
    public mutating func accept(_ input: RemoteInput, edge: Bool, recording: Bool = false) -> [Action] {
        let changed = capture != input.capture || mode != input.mode
        capture = input.capture; mode = input.mode
        let positions = Action.positions(input.capture == 0 ? .off : input.capture == 1 ? .hold : .continuous,
            input.mode == 0 ? .dictation : .ai_control)
        if !edge {
            if changed || input.status & 2 != 0 {
                down = nil; released = !input.pressed
                return [.stop, positions]
            }
            if !input.pressed { released = true }
            return [positions]
        }
        if input.capture == 0 || input.status & 2 != 0 {
            down = nil; released = !input.pressed; return [.stop, positions]
        }
        switch input.event {
        case 1 where input.capture == 1 && released:
            down = input.tick; released = false; return [positions, .startHold]
        case 2:
            let wasHolding = down != nil
            let accepted = down.map { input.tick &- $0 >= 300 && input.tick &- $0 < 0x80000000 } ?? false
            down = nil; released = true
            return input.capture == 1 && wasHolding ? [positions, .releaseHold(accepted)] : [positions]
        case 3:
            down = nil; released = !input.pressed; return [.stop, positions, .cycleTarget]
        case 4, 5:
            let holdEnd: [Action] = down.map { [.releaseHold(input.tick &- $0 >= 300 && input.tick &- $0 < 0x80000000)] } ?? []
            down = nil; released = !input.pressed
            return holdEnd + [.boundary, positions] + (input.capture == 2 && (input.event == 4 || recording) ? [.startContinuous] : [])
        default: return [positions]
        }
    }
}

/// Hold audio is provisional until release qualifies using the remote clock.
/// The bound is defensive (120 s), not a device performance claim. No short
/// gesture reaches STT; overflow/loss discards the entire pending segment.
public struct RemoteHoldBuffer: Sendable {
    private var pending: [AudioFrame]? = []
    public init(provisional: Bool) { if !provisional { pending = nil } }
    public mutating func frame(_ frame: AudioFrame) throws -> [CaptureEvent] {
        guard pending != nil else { return [.frame(frame)] }
        guard pending!.count < 6000 else { pending = []; throw RemoteContractError.loss }
        pending!.append(frame); return []
    }
    public mutating func qualify() -> [CaptureEvent] {
        let frames = pending ?? []; pending = nil
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
