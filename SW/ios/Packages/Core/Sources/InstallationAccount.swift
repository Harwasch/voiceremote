import Foundation

/// A single-user installation cannot reinterpret existing private storage as a
/// different account. Hosts persist the returned identity in protected storage.
public enum InstallationAccount {
    public static func resolve(requested: String?, pinned: String?) throws -> String {
        let requested = requested ?? "owner-local"
        try RecordAccount.validate(requested)
        if let pinned {
            guard requested == pinned else { throw CoreError.wrongAccount }
            return pinned
        }
        return requested
    }
}
