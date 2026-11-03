import XCTest
@testable import Stt

private struct ReplacementPass: CleanupPass {
    let replacement: String
    func clean(_ raw: String, vocabulary: Vocabulary) async throws -> String { replacement }
}
private struct BrokenPass: CleanupPass {
    func clean(_ raw: String, vocabulary: Vocabulary) async throws -> String { throw SttFailure.unavailable }
}
private struct SlowPass: CleanupPass {
    func clean(_ raw: String, vocabulary: Vocabulary) async throws -> String {
        // Ignores cancellation deliberately; the wrapper must still return before it completes.
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { continuation.resume() }
        }
        return "Send"
    }
}
@MainActor final class CleanupTests: XCTestCase {
    let vocabulary = Vocabulary(userID: "synthetic-user", terms: ["Codex", "hwgeekom"])
    func testDeterministicRulesAndVocabulary() async throws {
        let clean = try await FailSafeCleanup().clean("um, codex has number two", vocabulary: vocabulary)
        XCTAssertEqual(clean, "Codex has number 2.")
        XCTAssertEqual(RuleCleanupPass.apply("keep like and not and never", vocabulary: vocabulary), "Keep like and not and never.")
        XCTAssertEqual(RuleCleanupPass.apply("number two three", vocabulary: vocabulary), "Number two three.")
        let other = Vocabulary(userID: "other", terms: ["CODEX"])
        XCTAssertEqual(RuleCleanupPass.apply("codex", vocabulary: other), "CODEX.")
        XCTAssertEqual(vocabulary.terms, ["Codex", "hwgeekom"])
        XCTAssertEqual(RuleCleanupPass.apply("um is a filler word", vocabulary: vocabulary), "Um is a filler word.")
    }
    func testAddedNewlineControlsSendAndMeaningChangesFallBackToExactRaw() async throws {
        let raw = "do not publish number two"
        for candidate in ["Do not publish number 2.\n", "Do not publish number 2.\r\nSend", "\u{0}do not publish",
                          "Do not publish number 2. Send", "Do publish number 2.", "Do not delete number 2.",
                          "Do not publish number 3.", "Do not publish number 2!", "", raw + " enter", raw + " submit"] {
            let result = try await FailSafeCleanup(ReplacementPass(replacement: candidate)).clean(raw, vocabulary: vocabulary)
            XCTAssertEqual(result, raw)
        }
        let longRaw = Array(repeating: "keep", count: 100).joined(separator: " ") + " not"
        let result = try await FailSafeCleanup(ReplacementPass(replacement: longRaw.replacingOccurrences(of: " not", with: "")))
            .clean(longRaw, vocabulary: vocabulary)
        XCTAssertEqual(result, longRaw)
    }
    func testErrorAndTimeoutReturnRaw() async throws {
        let raw = "synthetic raw text"
        let failed = try await FailSafeCleanup(BrokenPass()).clean(raw, vocabulary: vocabulary)
        XCTAssertEqual(failed, raw)
        let clock = ContinuousClock(); let start = clock.now
        let timed = try await FailSafeCleanup(SlowPass(), timeout: .milliseconds(10)).clean(raw, vocabulary: vocabulary)
        XCTAssertEqual(timed, raw)
        XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(500))
    }
    func testOriginalSendAndNewlineRemainRawAndNeverBecomeActions() async throws {
        for raw in ["Send this", "line\nline", "raw\ttext"] {
            let result = try await FailSafeCleanup(ReplacementPass(replacement: raw)).clean(raw, vocabulary: vocabulary)
            XCTAssertEqual(result, raw)
        }
        let result = try await FailSafeCleanup().clean("send this", vocabulary: vocabulary)
        XCTAssertEqual(result, "Send this.") // text only; Stt has no execution or keystroke interface.
    }
    func testFillersCannotEraseVocabularyOrRepeatedNegativeHesitations() async throws {
        for raw in ["uh uh do it", "uh, uh, do it"] {
            let result = try await FailSafeCleanup(ReplacementPass(replacement: "Do it.")).clean(raw, vocabulary: vocabulary)
            XCTAssertEqual(result, raw)
        }
        let names = Vocabulary(userID: "test", terms: ["Um", "One"])
        let result = try await FailSafeCleanup().clean("Um arrived as number One", vocabulary: names)
        XCTAssertEqual(result, "Um arrived as number One.")
    }
    func testCompoundNumbersStayWordsInsteadOfPartlyConverting() async throws {
        for suffix in ["one hundred", "one thousand", "one million", "one billion", "one point five",
                       "one and a half", "one hundred and two", "one-hundred", "one hundred,", "one trillion"] {
            let raw = "room number " + suffix
            let expected = "Room number " + suffix + (suffix.last == "," ? "" : ".")
            let result = try await FailSafeCleanup().clean(raw, vocabulary: vocabulary)
            XCTAssertEqual(result, expected)
        }
    }
    func testVocabularyIsolationAndSanitization() {
        let words = Vocabulary(userID: "test", terms: [" Codex ", "codex", "", "bad\nterm", "good"])
        XCTAssertEqual(words.terms, ["Codex", "good"])
        XCTAssertNotEqual(words.userID, vocabulary.userID)
    }
}

extension CleanupTests {
    func testControlClustersRejectCleanupOutputPreserveRawAndNeverEnterVocabulary() async throws {
        for cluster in ["\r\n", "a\r\nb", "\n\u{0301}", "a\u{0000}\u{0301}b"] {
            let raw = "synthetic"
            let cleaned = try await FailSafeCleanup(ReplacementPass(replacement: cluster)).clean(raw, vocabulary: vocabulary)
            XCTAssertEqual(cleaned, raw)
            let preserved = try await FailSafeCleanup().clean(cluster, vocabulary: vocabulary)
            XCTAssertEqual(Array(preserved.unicodeScalars), Array(cluster.unicodeScalars))
            XCTAssertEqual(Array(RuleCleanupPass.apply(cluster, vocabulary: vocabulary).unicodeScalars), Array(cluster.unicodeScalars))
            // Controls must be rejected even when trimming would hide them at the term's boundary.
            XCTAssertEqual(Vocabulary(userID: "synthetic", terms: ["safe", "word" + cluster, cluster + "word"]).terms, ["safe"])
        }
    }
}
