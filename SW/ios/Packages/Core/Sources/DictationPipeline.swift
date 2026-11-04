import Foundation
import VoiceRemoteProtocol

/// This boundary only accepts literal text, never commands, tools or Send/Enter.
public protocol DictationTarget: Sendable {
    /// Return only after the phone/remote/tray destination presentation is ready.
    func showTarget(_ device: DeviceInfo) async throws
    /// The adapter must serialize actual delivery with credential revocation.
    func insert(_ text: DictationText) async throws
}

public actor DictationPipeline {
    private let history: any HistoryStore
    private let target: any DictationTarget
    private let registry: DeviceRegistry
    private struct PreparedTarget {
        let device: DeviceInfo
        let isPhone: Bool
    }
    private var prepared: [String: PreparedTarget] = [:]
    private var preparing: [String: UUID] = [:]
    public init(history: any HistoryStore, target: any DictationTarget, registry: DeviceRegistry) {
        self.history = history; self.target = target; self.registry = registry
    }
    /// Resolve and expose the destination before starting STT. It is pinned for this segment.
    @discardableResult
    public func prepare(segmentID: String, state: AppState, picker: TargetPicker, now: Int64) async throws -> DeviceInfo {
        guard state.mode == .dictation else { throw CoreError.wrongMode }
        guard prepared[segmentID] == nil, preparing[segmentID] == nil else { throw CoreError.unknownSegment }
        let preparationID = UUID()
        preparing[segmentID] = preparationID
        defer { if preparing[segmentID] == preparationID { preparing.removeValue(forKey: segmentID) } }
        var selectedPicker = picker
        selectedPicker.selection = state.target
        let device = try selectedPicker.resolve(devices: await registry.all())
        guard device.account_id == registry.accountID else { throw CoreError.wrongAccount }
        try await target.showTarget(device)
        guard preparing[segmentID] == preparationID else { throw CoreError.unknownSegment }
        prepared[segmentID] = PreparedTarget(device: device, isPhone: device.device_id == selectedPicker.phoneID)
        return device
    }
    public static func sanitize(_ text: String) -> String {
        var output: [Unicode.Scalar] = []
        var lineBreakPending = false
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if [0x0a, 0x0b, 0x0c, 0x0d, 0x85, 0x2028, 0x2029].contains(value) {
                lineBreakPending = true
                continue
            }
            guard value > 0x1f, !(0x7f...0x9f).contains(value) else { continue }
            if lineBreakPending {
                if scalar.properties.isWhitespace { continue }
                while output.last?.properties.isWhitespace == true { output.removeLast() }
                if !output.isEmpty { output.append(" ") }
                lineBreakPending = false
            }
            output.append(scalar)
        }
        return String(String.UnicodeScalarView(output)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// History is durable before delivery. A failed insertion is visible to the caller;
    /// retries require a new segment, avoiding blind duplicate insertion.
    public func commit(segmentID: String, revision: Int64, text: String, now: Int64) async throws {
        guard let preparedTarget = prepared.removeValue(forKey: segmentID) else { throw CoreError.unknownSegment }
        let cleanText = Self.sanitize(text)
        guard !cleanText.isEmpty else { return }
        let device = preparedTarget.device
        if !preparedTarget.isPhone { _ = try await registry.textReceiver(device.device_id) }
        let message = DictationText(account_id: device.account_id, segment_id: segmentID, revision: revision,
                                    state: .committed, target_device_id: device.device_id, text: cleanText)
        _ = try ProtocolCodec.encode(message)
        try await history.append(HistoryEntry(segmentID: segmentID, targetID: device.device_id, text: message.text, createdAt: now, accountID: device.account_id), now: now)
        if !preparedTarget.isPhone { _ = try await registry.textReceiver(device.device_id) }
        try await target.insert(message)
    }
    public func cancel(segmentID: String) {
        preparing.removeValue(forKey: segmentID)
        prepared.removeValue(forKey: segmentID)
    }
}
