import Foundation

public enum BrainSetting: String, Codable, Sendable { case onDeviceOnly, hybrid, cloudOnly }
public enum BrainRoute: String, Sendable { case onDevice, cloud }
public enum BrainRoutingNotice: String, Sendable {
    case onDevice, cloud, offlineUsingOnDevice, cloudUnavailableUsingOnDevice, refused
    public var message: String {
        switch self {
        case .onDevice: "Proposals generated on device."
        case .cloud: "Proposals generated in the cloud."
        case .offlineUsingOnDevice: "Offline: using the on-device brain; complex requests may be unavailable."
        case .cloudUnavailableUsingOnDevice: "Cloud unavailable: using the on-device brain; complex requests may be unavailable."
        case .refused: "Request refused; no proposals generated."
        }
    }
}

public struct RoutedProposals: Sendable {
    public let response: BrainResponse
    public let route: BrainRoute
    public let notice: BrainRoutingNotice
    public var message: String { notice.message }
}

public struct BrainRouter: LlmBrain {
    public let setting: BrainSetting
    private let onDevice: any LlmBrain
    private let cloud: any LlmBrain
    private let isOnline: @Sendable () async -> Bool

    public init(setting: BrainSetting = .hybrid, onDevice: any LlmBrain, cloud: any LlmBrain,
                isOnline: @escaping @Sendable () async -> Bool) {
        self.setting = setting; self.onDevice = onDevice; self.cloud = cloud; self.isOnline = isOnline
    }

    public func propose(_ request: BrainRequest) async throws -> BrainResponse {
        let routed = try await route(request)
        return BrainResponse(proposals: routed.response.proposals, droppedCount: routed.response.droppedCount,
                             routingNotice: routed.notice, outcome: routed.response.outcome)
    }

    public func route(_ request: BrainRequest) async throws -> RoutedProposals {
        if setting == .onDeviceOnly {
            return try await local(request, notice: .onDevice)
        }
        let online = await isOnline()
        if setting == .cloudOnly {
            guard online else { throw BrainError.offline }
            return try await cloudResult(request)
        }
        if !online { return try await local(request, notice: .offlineUsingOnDevice) }
        if Self.isSimple(request) { return try await local(request, notice: .onDevice) }
        do {
            return try await cloudResult(request)
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            return try await local(request, notice: .cloudUnavailableUsingOnDevice)
        }
    }

    private func local(_ request: BrainRequest, notice: BrainRoutingNotice) async throws -> RoutedProposals {
        let response = try await onDevice.propose(request)
        return RoutedProposals(response: response, route: .onDevice, notice: response.outcome == .refused ? .refused : notice)
    }

    private func cloudResult(_ request: BrainRequest) async throws -> RoutedProposals {
        let response = try await cloud.propose(request)
        return RoutedProposals(response: response, route: .cloud, notice: response.outcome == .refused ? .refused : .cloud)
    }

    private static func isSimple(_ request: BrainRequest) -> Bool {
        if request.workload == .ambient || request.workload == .multiStep { return false }
        let words = request.transcript.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        // Even a caller's simple hint cannot send a linked utterance through the fast path.
        guard !words.contains(where: { ["and", "then", "after", "ask", "summarize", "compare"].contains($0) }),
              !request.transcript.contains(where: { ".;!?".contains($0) }) else { return false }
        return words.first.map { ["open", "switch", "select"].contains($0) } ?? false
    }
}
