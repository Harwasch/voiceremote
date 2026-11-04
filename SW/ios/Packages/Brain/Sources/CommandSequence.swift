import Foundation

public enum InstructionState: Equatable, Sendable { case pending, cancelled, blocked }
public struct LinkedInstruction: Equatable, Sendable {
    public let ordinal: Int
    public let text: String
    public let dependsOn: [Int]
    public internal(set) var state: InstructionState
}

/// Conservative sequential dependencies preserve order. This is a review plan, never a task queue.
public struct CommandSequence: Equatable, Sendable {
    public private(set) var instructions: [LinkedInstruction]

    public static func parse(_ text: String, isFinal: Bool, isComplete: Bool) -> CommandSequence {
        guard isFinal, isComplete else { return CommandSequence(instructions: []) }
        // Deliberately narrow initial grammar; arbitrary planning remains a model proposal.
        let separator = #"(?i)(?:[.!?;]\s+|\bthen\s+)"#
        let parts = text.replacingOccurrences(of: separator, with: "\u{001F}", options: .regularExpression)
            .split(separator: "\u{001F}").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return CommandSequence(instructions: parts.enumerated().map { index, text in
            LinkedInstruction(ordinal: index + 1, text: text,
                              dependsOn: index == 0 ? [] : [index], state: .pending)
        })
    }

    public mutating func cancel(ordinal: Int) {
        guard let index = instructions.firstIndex(where: { $0.ordinal == ordinal }),
              instructions[index].state == .pending else { return }
        instructions[index].state = .cancelled
        var unavailable: Set<Int> = [ordinal]
        for i in instructions.indices where instructions[i].state == .pending {
            if instructions[i].dependsOn.contains(where: unavailable.contains) {
                instructions[i].state = .blocked; unavailable.insert(instructions[i].ordinal)
            }
        }
    }

    public static func cancellationOrdinal(_ text: String, wakePhrase: String = "Assistant") -> Int? {
        let unaddressed = WakePhraseDetector.removingAddressPrefix(text, phrase: wakePhrase)
        let normalized = unaddressed.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!?")))
        let words = normalized.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        switch words {
        case "cancel the first one", "cancel the first", "cancel 1": return 1
        case "cancel the second one", "cancel the second", "cancel 2": return 2
        case "cancel the third one", "cancel the third", "cancel 3": return 3
        default: return nil
        }
    }
}
