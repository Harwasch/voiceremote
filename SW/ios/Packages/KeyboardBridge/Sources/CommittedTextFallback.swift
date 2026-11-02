#if canImport(UIKit)
import UIKit

/// Main-app fallback for secure fields or apps that reject custom keyboards.
/// Only call in response to an explicit user action on a selected history segment.
@MainActor public enum CommittedTextFallback {
    public static func copy(_ segment: CommittedSegment, now: Date = Date()) throws {
        try validate(segment, now: now)
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: segment.text]], options: [
            .localOnly: true,
            .expirationDate: segment.createdAt.addingTimeInterval(BridgePolicy.retention)
        ])
    }

    public static func shareSheet(_ segment: CommittedSegment, now: Date = Date()) throws -> UIActivityViewController {
        try validate(segment, now: now)
        return UIActivityViewController(activityItems: [segment.text], applicationActivities: nil)
    }

    private static func validate(_ segment: CommittedSegment, now: Date) throws {
        try BridgePolicy.validate(segment.text)
        guard BridgePolicy.live(segment.createdAt, now: now) else { throw BridgeError.expired }
    }
}
#endif
