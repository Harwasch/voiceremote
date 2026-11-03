import Foundation

public enum AudioRouteEvent: Sendable { case oldDeviceUnavailable, categoryChanged, configurationChanged, newDeviceAvailable, other }
public enum AudioRouteAction: Sendable { case stop, restart, ignore }
public enum AudioRoutePolicy {
    public static func action(for event: AudioRouteEvent) -> AudioRouteAction {
        switch event {
        case .oldDeviceUnavailable: .stop
        case .configurationChanged, .newDeviceAvailable: .restart
        case .categoryChanged, .other: .ignore
        }
    }
}

/// Intent and scene use the same MainActor factory, including cold starts.
@MainActor public final class RuntimeBootstrap<Value> {
    public private(set) var value: Value?
    public init() {}
    public func resolve(_ make: () throws -> Value) rethrows -> Value {
        if let value { return value }
        let result = try make(); value = result; return result
    }
}
