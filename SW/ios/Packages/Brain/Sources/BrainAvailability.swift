/// No inference engine is connected in the shell.
public struct BrainAvailability: Equatable, Sendable {
    public let isConfigured: Bool

    public init(isConfigured: Bool = false) {
        self.isConfigured = isConfigured
    }
}
