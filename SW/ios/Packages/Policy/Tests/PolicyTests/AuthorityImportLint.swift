import Foundation

/// Conservative lexical boundary lint: even conditional/attributed imports and
/// qualified type references are forbidden. Runs against real repository files
/// and injected fixtures. This is a build guard, not a sandbox for native code.
enum AuthorityImportLint {
    static func violations(packages: URL) throws -> [String] {
        var violations: [String] = []
        for name in ["Brain", "BrainApple", "Stt", "SttApple"] {
            let root = packages.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            guard let files = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else { throw PolicyErrorForLint.unreadable }
            for case let url as URL in files {
                if [".build", ".swiftpm", ".git"].contains(url.lastPathComponent) { files.skipDescendants(); continue }
                // Do not silently skip a linked source subtree.
                if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                    violations.append(url.path); files.skipDescendants(); continue
                }
                guard ["swift", "m", "mm", "h"].contains(url.pathExtension) else { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                if text.range(of: #"\bTrustedInput\b"#, options: .regularExpression) != nil {
                    violations.append(url.path)
                }
            }
        }
        return violations.sorted()
    }
    private enum PolicyErrorForLint: Error { case unreadable }
}
