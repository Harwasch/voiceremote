import Foundation
import Testing

@Suite @MainActor struct GateAuthorityBoundaryTests {
    @Test func externalModuleCannotConstructOrDecodeAuthority() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("UntrustedCaller.swift")
        try """
        import Foundation
        import TrustedInput
        import Policy
        func decode(_ bytes: Data) throws {
            _ = try JSONDecoder().decode(ActivationEvidence.self, from: bytes)
            _ = try JSONDecoder().decode(ApprovalEvidence.self, from: bytes)
            _ = try JSONDecoder().decode(GrantEvidence.self, from: bytes)
            _ = try JSONDecoder().decode(ExecutionPermit.self, from: bytes)
        }
        @MainActor func missingRegistryClassification() {
            _ = PhoneInput().session(account: "a", actor: "u", session: "s", device: "d", project: "p")
        }
        func forge(_ session: InputSession) {
            _ = ActivationEvidence(session: session, requestID: UUID(), activation: .ptt,
                mode: .command, ambiguousMeetingWake: false, expiresAt: 123)
            _ = ApprovalEvidence(session: session, eventID: UUID(), requestID: UUID(),
                payloadHash: "forged", source: .phone, occurredAt: 123)
            _ = GrantEvidence(session: session, id: UUID(), capability: .receive_text,
                risk: .read_display, expiresAt: 123, issuedAt: 100)
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swiftc", "-typecheck", "-I", package.appendingPathComponent(".build/debug/Modules").path,
                             "-module-cache-path", directory.appendingPathComponent("cache").path, source.path]
        // File output avoids a full diagnostics pipe blocking the child compiler.
        let diagnostics = directory.appendingPathComponent("diagnostics.txt")
        #expect(FileManager.default.createFile(atPath: diagnostics.path, contents: nil))
        let output = try FileHandle(forWritingTo: diagnostics)
        defer { try? output.close() }
        process.standardError = output; process.standardOutput = output
        try process.run(); process.waitUntilExit()
        let text = try String(contentsOf: diagnostics, encoding: .utf8)
        #expect(process.terminationStatus != 0)
        #expect(text.contains("missing argument for parameter 'destinationKind'"))
        for name in ["ActivationEvidence", "ApprovalEvidence", "GrantEvidence", "ExecutionPermit"] {
            #expect(text.contains("'\(name)' conform to 'Decodable'"))
        }
        for name in ["ActivationEvidence", "ApprovalEvidence", "GrantEvidence"] {
            #expect(text.contains("'\(name)' initializer is inaccessible"))
        }
    }
}

@Suite @MainActor struct GateImportLintTests {
    @Test func review6ProtectedPackagesCannotImportOrDependOnTrustedInput() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        #expect(try AuthorityImportLint.violations(packages: root.appendingPathComponent("SW/ios/Packages")).isEmpty)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for package in ["Brain", "BrainApple", "Stt", "SttApple"] {
            let folder = directory.appendingPathComponent(package)
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("Sources/Nested"), withIntermediateDirectories: true)
            try #".product(name: "TrustedInput", package: "Policy")"#.write(to: folder.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
            try "@preconcurrency import /* comment */ TrustedInput\n".write(to: folder.appendingPathComponent("Sources/Nested/Injected.swift"), atomically: true, encoding: .utf8)
        }
        #expect(try AuthorityImportLint.violations(packages: directory).count == 8)
    }
}
