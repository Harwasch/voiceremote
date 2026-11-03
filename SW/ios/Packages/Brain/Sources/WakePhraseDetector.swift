import Foundation

public enum WakePhraseMatch: Equatable, Sendable { case none, addressed, ambiguousSuggestion }

/// Text matching is evidence only. It never sets wire activation or authenticated identity.
public struct WakePhraseDetector: Sendable {
    public let phrase: String
    public init(phrase: String = "Assistant") { self.phrase = phrase }

    public func detect(_ text: String, meetingMode: Bool = false,
                       speakerAmbiguous: Bool = true, externalOrPlayback: Bool = false) -> WakePhraseMatch {
        let raw = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let wake = phrase.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !wake.isEmpty, wake.allSatisfy({ $0.allSatisfy(\.isLetter) }), raw.count >= wake.count else { return .none }
        // Strip terminal address punctuation only. Apostrophes/hyphens remain word characters.
        let quotes = CharacterSet(charactersIn: "\"'“”‘’«»")
        let tokens = raw.map { Self.removingTrailingPunctuation($0.trimmingCharacters(in: quotes)) }
        let matches = (0...(tokens.count - wake.count)).filter { start in
            Array(tokens[start..<(start + wake.count)]) == wake
        }
        if matches.isEmpty {
            let last = wake.last!
            let mention = tokens.enumerated().contains { index, token in
                guard index >= wake.count - 1,
                      Array(tokens[(index - wake.count + 1)..<index]) == Array(wake.dropLast()) else { return false }
                return ["'", "’", "-", "–", "—"].contains { token.hasPrefix(last + $0) }
            }
            return mention ? .ambiguousSuggestion : .none
        }
        let exactPrefix = raw.prefix(wake.count).enumerated().allSatisfy { index, token in
            index == wake.count - 1 ? Self.removingTrailingPunctuation(token) == wake[index] : token == wake[index]
        }
        let quoted = text.contains(where: { "\"“”‘«»".contains($0) })
            || raw.contains { $0.hasPrefix("'") || $0.hasSuffix("'") || $0.hasSuffix("’") }
        guard matches == [0], exactPrefix, !quoted, !meetingMode, !speakerAmbiguous, !externalOrPlayback,
              raw.count > wake.count, raw[wake.count].first?.isLetter == true else { return .ambiguousSuggestion }
        return .addressed
    }

    /// Local review-list prefix handling creates no activation evidence.
    static func removingAddressPrefix(_ text: String, phrase: String) -> String {
        guard WakePhraseDetector(phrase: phrase).detect(text, speakerAmbiguous: false) == .addressed else { return text }
        return text.split(whereSeparator: \.isWhitespace).dropFirst(phrase.split(whereSeparator: \.isWhitespace).count)
            .joined(separator: " ")
    }

    private static func removingTrailingPunctuation(_ token: String) -> String {
        var result = token
        while let last = result.last, ",:;.!?".contains(last) { result.removeLast() }
        return result
    }
}
