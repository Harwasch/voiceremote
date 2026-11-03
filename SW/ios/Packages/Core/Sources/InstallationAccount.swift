import Foundation

/// A single-user installation cannot reinterpret existing private storage as a
/// different account. Hosts persist the returned identity in protected storage.
public enum InstallationAccount {
    public static func resolve(requested: String?, pinned: String?) throws -> String {
        let requested = requested ?? "owner-local"
        guard !requested.isEmpty else { throw CoreError.wrongAccount }
        if let pinned {
            guard requested == pinned else { throw CoreError.wrongAccount }
            return pinned
        }
        return requested
    }
}
