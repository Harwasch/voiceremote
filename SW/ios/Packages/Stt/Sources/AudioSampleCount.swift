/// A small platform-independent value; capture and recognizers are future adapters.
public struct AudioSampleCount: Equatable, Sendable {
    public let value: Int

    public init?(_ value: Int) {
        guard value >= 0 else { return nil }
        self.value = value
    }
}
