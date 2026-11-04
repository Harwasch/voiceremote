import Foundation

public protocol CleanupPass: Sendable {
    func clean(_ raw: String, vocabulary: Vocabulary) async throws -> String
}

/// Deliberately conservative: preserves internal punctuation, word order and negations.
/// Only unambiguous standalone numeric words following "number" become digits.
/// Only explicitly comma-marked leading "um,"/"uh," may be removed; bare mentions stay intact.
public struct RuleCleanupPass: CleanupPass {
    public init() {}
    public func clean(_ raw: String, vocabulary: Vocabulary) async throws -> String {
        Self.apply(raw, vocabulary: vocabulary)
    }
    public static func apply(_ raw: String, vocabulary: Vocabulary) -> String {
        guard !raw.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
        }) else { return raw }
        var words = raw.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        // Repeated "uh uh" can be a negation; remove only one isolated hesitation.
        let hesitations = ["um", "uh", "um,", "uh,"]
        if let first = words.first, ["um,", "uh,"].contains(first.lowercased()), words.count > 1,
           !hesitations.contains(words[1].lowercased()),
           !vocabulary.terms.contains(where: {
               $0.lowercased() == first.trimmingCharacters(in: .punctuationCharacters).lowercased()
           }) {
            words.removeFirst()
        }
        let digits = ["zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
                      "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9"]
        // A single digit prefix of a compound number must never be converted independently.
        let numberContinuations = Set(digits.keys).union([
            "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
            "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
            "hundred", "thousand", "million", "billion", "trillion", "quadrillion", "quintillion",
            "and", "point", "dot", "slash", "over", "half", "quarter", "third", "quarters", "halves"
        ])
        func continuesNumber(_ token: String) -> Bool {
            token.lowercased().split(whereSeparator: { !$0.isLetter }).contains { numberContinuations.contains(String($0)) }
        }
        for i in words.indices {
            // Vocabulary changes case only: no fuzzy replacement or word insertion.
            if let term = vocabulary.terms.first(where: { $0.lowercased() == words[i].lowercased() }) {
                words[i] = term
            }
            if !vocabulary.terms.contains(where: { $0.lowercased() == words[i].lowercased() }),
               i > 0, words[i - 1].lowercased() == "number", let digit = digits[words[i].lowercased()],
               (i + 1 == words.count || !continuesNumber(words[i + 1])) {
                words[i] = digit
            }
        }
        guard !words.isEmpty else { return raw }
        if !vocabulary.terms.contains(where: { $0 == words[0] }), let first = words[0].first {
            words[0] = first.uppercased() + words[0].dropFirst()
        }
        var text = words.joined(separator: " ")
        if let last = text.last, last.isLetter || last.isNumber { text += "." }
        return text
    }
}

/// Zero arbitrary lexical edits allowed. This also rejects a one-word negation drop in long text.
/// Punctuation edits are restricted to RuleCleanupPass's terminal period and spacing.
public struct FailSafeCleanup: CleanupPass {
    public let pass: any CleanupPass
    public let timeout: Duration
    public init(_ pass: any CleanupPass = RuleCleanupPass(), timeout: Duration = .milliseconds(150)) {
        self.pass = pass; self.timeout = timeout
    }
    public func clean(_ raw: String, vocabulary: Vocabulary) async throws -> String {
        guard !Task.isCancelled else { return raw }
        // An unstructured race intentionally avoids waiting for an uncooperative pass on timeout.
        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let worker = Task {
            let candidate = (try? await pass.clean(raw, vocabulary: vocabulary)) ?? raw
            continuation.yield(candidate); continuation.finish()
        }
        let timer = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            continuation.yield(raw); continuation.finish()
        }
        defer { worker.cancel(); timer.cancel(); continuation.finish() }
        var iterator = stream.makeAsyncIterator()
        let candidate = await iterator.next() ?? raw
        guard !Task.isCancelled, Self.isSafe(candidate, raw: raw, vocabulary: vocabulary) else { return raw }
        return candidate
    }
    public static func isSafe(_ candidate: String, raw: String, vocabulary: Vocabulary) -> Bool {
        if candidate == raw { return true }
        guard candidate.count <= raw.count + 1,
              !candidate.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
              }) else { return false }
        let actions = Set(["send", "submit", "enter", "return"])
        func actionWords(_ text: String) -> [String] {
            text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init).filter { actions.contains($0) }
        }
        guard actionWords(candidate) == actionWords(raw) else { return false }
        return candidate == RuleCleanupPass.apply(raw, vocabulary: vocabulary)
    }
}
