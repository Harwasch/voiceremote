import Foundation
import Core
import VoiceRemoteProtocol

public enum RemoteContractError: Error { case incompatible, malformed, loss, off, notReady }
public struct RemoteInfo: Sendable {
    public let maxPacket: Int
    public let hardwareMicCut: Bool
    public init(_ data: Data) throws {
        let b = [UInt8](data)
        guard b.count == 20, b[0] == 1, b[1] == 0, b[7] == 0, b[18] == 0, b[19] == 0,
              b[8] & 0x3f == 0x3f, b[8] & 0x80 == 0, b[9] == 0,
              b[10] > 0, b[11] <= 1,
              (Int(b[12]) | Int(b[13]) << 8) > 0, (Int(b[14]) | Int(b[15]) << 8) > 0 else { throw RemoteContractError.incompatible }
        let board = Int(b[2]) | Int(b[3]) << 8
        guard [1, 2, 65535].contains(board) else { throw RemoteContractError.incompatible }
        maxPacket = Int(b[16]) | Int(b[17]) << 8
        guard (1...4096).contains(maxPacket) else { throw RemoteContractError.incompatible }
        hardwareMicCut = b[8] & 0x40 != 0
    }
}
public struct RemoteInput: Sendable {
    public let sequence: UInt32
    public let tick: UInt32
    public let event: UInt8
    public let capture: UInt8
    public let mode: UInt8
    public let pressed: Bool
    public init(_ data: Data) throws {
        let b = [UInt8](data)
        guard b.count == 14, b[8] <= 5, b[9] <= 2, b[10] <= 1, b[11] <= 1,
              b[12] <= 1, b[13] == 0, b[8] != 1 || b[11] == 1,
              b[8] != 2 || b[11] == 0 else { throw RemoteContractError.malformed }
        sequence = Self.word(b, 0); tick = Self.word(b, 4); event = b[8]
        capture = b[9]; mode = b[10]; pressed = b[11] == 1
    }
    static func word(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i+1]) << 8 | UInt32(b[i+2]) << 16 | UInt32(b[i+3]) << 24
    }
}
/// Reset on reconnect/loss; snapshots never synthesize button edges.
public struct RemoteInputTracker: Sendable {
    public private(set) var last: RemoteInput?
    public private(set) var synchronized = false
    public init() {}
    public mutating func accept(_ input: RemoteInput) throws -> Bool {
        if let last {
            let distance = input.sequence &- last.sequence
            if distance == 0 || distance >= 0x80000000 { return false }
            guard distance == 1 else { synchronized = false; self.last = input; throw RemoteContractError.loss }
        }
        if let last, synchronized, input.event != 0 {
            guard !(input.event == 1 && last.pressed), !(input.event == 2 && !last.pressed),
                  input.event == 4 || input.capture == last.capture,
                  input.event == 5 || input.mode == last.mode else {
                synchronized = false; self.last = input; throw RemoteContractError.loss
            }
        }
        last = input
        if input.event == 0 { synchronized = true; return false }
        guard synchronized else { return false }
        return true
    }
    public mutating func reset() { last = nil; synchronized = false }
}

/// Binary layout from draft remote-ble-draft.md, v1.0. No concealment or splicing.
public struct RemoteAudioAssembler: Sendable {
    public enum Output: Equatable, Sendable { case packet(Data), end, ignored }
    private let maximum: Int
    private var segment: UInt32?
    private var lastSegment: UInt32 = 0
    public private(set) var highestSegment: UInt32 = 0
    private var nextFrame: UInt16 = 0
    private var packet = Data()
    private var packetTotal = 0
    private var fragments: [Int: Data] = [:]
    public init(maximum: Int, afterSegment: UInt32 = 0) {
        self.maximum = min(4096, max(1, maximum)); lastSegment = afterSegment; highestSegment = afterSegment
    }
    public mutating func accept(_ data: Data) throws -> Output {
        let b = [UInt8](data)
        guard b.count >= 12, b[7] == 0, b[6] & 0xf8 == 0 else { throw RemoteContractError.malformed }
        let id = RemoteInput.word(b, 0), seq = UInt16(b[4]) | UInt16(b[5]) << 8
        let flags = b[6], offset = Int(b[8]) | Int(b[9]) << 8, total = Int(b[10]) | Int(b[11]) << 8
        if segment == nil {
            if id <= lastSegment { return .ignored }
            guard id > 0, seq == 0, flags & 1 != 0, offset == 0 else { throw RemoteContractError.loss }
            segment = id; highestSegment = id; nextFrame = 0
        }
        guard segment == id else { throw RemoteContractError.loss }
        if seq < nextFrame { return .ignored }
        guard seq == nextFrame else { throw RemoteContractError.loss }
        if flags & 2 != 0 {
            guard flags == 6, b.count == 12, offset == 0, total == 0,
                  nextFrame > 0, packet.isEmpty else { throw RemoteContractError.loss }
            lastSegment = id; segment = nil; return .end
        }
        guard (seq == 0) == (flags & 1 != 0), total > 0, total <= maximum,
              b.count > 12, offset + b.count - 12 <= total,
              (flags & 4 != 0) == (offset + b.count - 12 == total) else { throw RemoteContractError.malformed }
        let payload = Data(b.dropFirst(12))
        if let previous = fragments[offset] {
            guard previous == payload, packetTotal == total else { throw RemoteContractError.loss }
            return .ignored
        }
        guard offset == packet.count, packet.isEmpty || packetTotal == total else { throw RemoteContractError.loss }
        packetTotal = total; fragments[offset] = payload; packet.append(payload)
        if flags & 4 != 0 {
            guard seq < UInt16.max else { throw RemoteContractError.loss }
            let complete = packet; packet = Data(); fragments = [:]; nextFrame += 1
            return .packet(complete)
        }
        return .ignored
    }
}

public struct SourceQuality: Sendable {
    public let id: String
    public let snrDB: Double
    public let clipping: Double
    public let dropouts: Int
    public let proximity: Double
    public init(id: String, snrDB: Double, clipping: Double, dropouts: Int, proximity: Double) {
        self.id = id; self.snrDB = snrDB; self.clipping = clipping; self.dropouts = dropouts; self.proximity = proximity
    }
    /// Heuristic coefficients, TBC by named-device benchmarks; never authority evidence.
    public var score: Double? {
        guard snrDB.isFinite, clipping.isFinite, proximity.isFinite, (0...1).contains(clipping),
              (0...1).contains(proximity), dropouts == 0 else { return nil }
        return snrDB - clipping * 40 + proximity * 6
    }
    public static func best(_ sources: [Self]) -> String? {
        sources.filter { $0.score != nil }.sorted {
            $0.score == $1.score ? $0.id < $1.id : $0.score! > $1.score!
        }.first?.id
    }
}

public struct RemotePhoneState: Sendable, Equatable {
    public var capture: UInt8 = 0
    public var recording: UInt8 = 0
    public var mode: UInt8 = 0
    public var names: [String] = ["Auto", "iPhone"]
    public var activeIndex: UInt8 = 0
    public var resolved = "iPhone"
    public var link = "BLE"
    public var error = ""
    public var arm = false
    public var requestSnapshot = false
    public var acknowledgedSequence: UInt32 = 0
    public init() {}
    public func fragments(transaction: UInt16, budget: Int) throws -> [Data] {
        guard budget > 6, (1...8).contains(names.count), names.first == "Auto", Int(activeIndex) < names.count,
              capture <= 2, recording <= 3, mode <= 1,
              !arm || (capture != 0 && recording == 1), capture != 0 || recording != 1,
              activeIndex == 0 || resolved == names[Int(activeIndex)] else { throw RemoteContractError.malformed }
        var bytes = Data([UInt8(requestSnapshot ? 1 : 0) | UInt8(arm ? 2 : 0), capture, recording, mode, UInt8(names.count), activeIndex])
        bytes.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: acknowledgedSequence >> ($0 * 8)) })
        func label(_ text: String, maximum: Int, empty: Bool = false) throws -> Data {
            guard text.utf8.count <= maximum, empty || !text.isEmpty,
                  !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw RemoteContractError.malformed }
            return Data([UInt8(text.utf8.count)]) + Data(text.utf8)
        }
        for name in names { bytes += try label(name, maximum: 32) }
        bytes += try label(resolved, maximum: 32); bytes += try label(link, maximum: 48, empty: true)
        bytes += try label(error, maximum: 64, empty: true)
        guard (19...512).contains(bytes.count) else { throw RemoteContractError.malformed }
        func short(_ value: Int) -> Data { Data([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]) }
        return stride(from: 0, to: bytes.count, by: budget - 6).map { offset in
            short(Int(transaction)) + short(bytes.count) + short(offset) + bytes.subdata(in: offset..<min(bytes.count, offset + budget - 6))
        }
    }
}

public extension RemotePhoneState {
    /// CoreBluetooth exposes a long-write limit, not ATT MTU. Until a negotiated
    /// single-value budget is established, 20 bytes is safe at ATT MTU 23.
    static func writeBudget(osMaximum: Int, negotiatedBudget: Int? = nil) -> Int {
        min(osMaximum, negotiatedBudget ?? 20)
    }
    static func presentation(controls: AppState, devices: [DeviceInfo], phoneID: String, destination: DeviceInfo?,
                             recording: Bool, acknowledgedSequence: UInt32, arm: Bool) throws -> RemotePhoneState {
        func label(_ value: String) -> String {
            var result = ""
            for scalar in value.unicodeScalars where !CharacterSet.controlCharacters.contains(scalar) {
                guard result.utf8.count + scalar.utf8.count <= 32 else { break }
                result.unicodeScalars.append(scalar)
            }
            return result.isEmpty ? "Device" : result
        }
        let eligible = devices.filter { $0.device_id != phoneID && $0.capabilities.contains(.receive_text) }.sorted { $0.device_id < $1.device_id }
        var shown = Array(eligible.prefix(6))
        if case .device(let id) = controls.target, id != phoneID, !shown.contains(where: { $0.device_id == id }),
           let selected = eligible.first(where: { $0.device_id == id }) {
            if shown.count == 6 { shown.removeLast() }; shown.append(selected)
        }
        var value = RemotePhoneState()
        value.names = ["Auto", "iPhone"] + shown.map { label($0.display_name) }
        switch controls.target {
        case .auto: value.activeIndex = 0
        case .device(let id):
            if id == phoneID { value.activeIndex = 1 }
            else {
                guard let index = shown.firstIndex(where: { $0.device_id == id }) else { throw RemoteContractError.notReady }
                value.activeIndex = UInt8(index + 2)
            }
        }
        value.resolved = destination.map { label($0.display_name) } ?? "iPhone"
        value.capture = controls.capture == .off ? 0 : (controls.capture == .hold ? 1 : 2)
        value.mode = controls.mode == .dictation ? 0 : 1
        value.recording = recording && controls.capture != .off ? 1 : 0
        value.arm = arm && recording && controls.capture != .off
        value.acknowledgedSequence = acknowledgedSequence
        return value
    }
}
