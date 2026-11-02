import Foundation
import VoiceRemoteProtocol

/// Phone-local monotonic milliseconds, shared by receipt stamping and selection.
public protocol FocusClock: Sendable {
    func nowMilliseconds() -> Int64
}
public struct UptimeFocusClock: FocusClock {
    public init() {}
    public func nowMilliseconds() -> Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1000) }
}

public struct TargetPicker: Sendable {
    public var selection: TargetSelection
    public let accountID: String
    public let phoneID: String
    private let clock: any FocusClock
    private struct ReceivedFocus: Sendable {
        let report: FocusReport
        let receivedAt: Int64
    }
    private var focus: [String: ReceivedFocus] = [:]
    public init(accountID: String, phoneID: String, selection: TargetSelection = .auto,
                clock: any FocusClock = UptimeFocusClock()) {
        self.accountID = accountID
        self.phoneID = phoneID
        self.selection = selection
        self.clock = clock
    }
    /// The local phone is always a destination, independent of peer enrollment.
    public var phone: DeviceInfo {
        DeviceInfo(account_id: accountID, device_id: phoneID, display_name: "iPhone",
                   platform: .ios, role: .text_receiver, capabilities: [.receive_text])
    }
    /// Reports must come from the authenticated device matching device_id.
    /// Peer wall-clock timestamps are validated as wire data, never used to rank
    /// or expire reports. Stamp receipt here using the phone's monotonic clock.
    public mutating func update(_ report: FocusReport) throws {
        guard report.account_id == accountID else { throw CoreError.wrongAccount }
        _ = try ProtocolCodec.encode(report)
        let receipt = clock.nowMilliseconds()
        if let old = focus[report.device_id], old.receivedAt > receipt { return }
        focus[report.device_id] = ReceivedFocus(report: report, receivedAt: receipt)
    }
    public func resolve(devices: [DeviceInfo]) throws -> DeviceInfo {
        try resolve(at: clock.nowMilliseconds(), devices: devices)
    }
    /// `now` is phone-local monotonic milliseconds, never an epoch timestamp.
    public func resolve(at now: Int64, devices: [DeviceInfo]) throws -> DeviceInfo {
        let eligible = devices.filter {
            $0.device_id != phoneID && $0.account_id == accountID
                && ($0.role == .text_receiver || $0.role == .both)
                && $0.capabilities.contains(.receive_text)
        } + [phone]
        switch selection {
        case .device(let id):
            guard let device = eligible.first(where: { $0.device_id == id }) else { throw CoreError.unavailableTarget }
            return device
        case .auto:
            let recent = eligible.compactMap { device -> (DeviceInfo, Int64)? in
                guard let received = focus[device.device_id], received.report.text_field_focused,
                      received.receivedAt <= now, now - received.receivedAt <= 60_000 else { return nil }
                return (device, received.receivedAt)
            }.sorted { $0.1 == $1.1 ? $0.0.device_id < $1.0.device_id : $0.1 > $1.1 }
            return recent.first?.0 ?? phone
        }
    }
}
