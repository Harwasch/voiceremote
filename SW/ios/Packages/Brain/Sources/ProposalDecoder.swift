import Foundation
import VoiceRemoteProtocol

public enum ProposalDecoder {
    /// Each element is passed as original bytes to ProtocolCodec, without a lossy JSON round trip.
    /// Malformed documents count once; schema-invalid elements count individually.
    public static func decode(_ data: Data, accountID: String) -> BrainResponse {
        do {
            let root = try RawJSON.parse(data)
            guard let items = root.elements else { return BrainResponse(droppedCount: 1) }
            return decodeItems(items, accountID: accountID)
        } catch { return BrainResponse(droppedCount: 1) }
    }

    static func decodeItems(_ items: [RawJSON], accountID: String) -> BrainResponse {
        var accepted: [BrainProposal] = []
        var dropped = 0
        for item in items {
            guard accepted.count < 64,
                  let tool = try? ProtocolCodec.decode(ToolCall.self, from: item.raw) else {
                dropped += 1; continue
            }
            let proposal = BrainProposal(validated: tool)
            guard proposal.accountID == accountID else { dropped += 1; continue }
            accepted.append(proposal)
        }
        return BrainResponse(proposals: accepted, droppedCount: dropped)
    }
}

/// A bounded envelope reader preserving tool bytes, including numeric tokens and key spellings.
/// The generated codec remains the only tool-schema validator.
struct RawJSON {
    let raw: Data
    var fields: [String: RawJSON]?
    var elements: [RawJSON]?
    var string: String? { try? JSONDecoder().decode(String.self, from: raw) }

    static func parse(_ data: Data) throws -> RawJSON {
        guard data.count <= 1_048_576 else { throw BrainError.responseTooLarge }
        guard String(data: data, encoding: .utf8) != nil else { throw BrainError.invalidResponse }
        var reader = Reader(bytes: Array(data))
        let result = try reader.value(depth: 0)
        reader.whitespace()
        guard reader.index == reader.bytes.count else { throw BrainError.invalidResponse }
        return result
    }

    private struct Reader {
        let bytes: [UInt8]
        var index = 0
        var current: UInt8? { index < bytes.count ? bytes[index] : nil }
        mutating func whitespace() { while let c = current, [9, 10, 13, 32].contains(c) { index += 1 } }
        mutating func take(_ c: UInt8) throws {
            guard current == c else { throw BrainError.invalidResponse }; index += 1
        }
        mutating func value(depth: Int) throws -> RawJSON {
            guard depth <= 64 else { throw BrainError.invalidResponse }
            whitespace()
            let start = index
            var fields: [String: RawJSON]?
            var elements: [RawJSON]?
            if current == 123 {
                index += 1; whitespace(); fields = [:]
                if current != 125 {
                    while true {
                        // Keys have no schema length bound, so scan/decode separately below.
                        let key = try unboundedString()
                        guard fields?[key] == nil else { throw BrainError.invalidResponse }
                        whitespace(); try take(58)
                        fields?[key] = try value(depth: depth + 1)
                        whitespace()
                        if current != 44 { break }
                        index += 1; whitespace()
                    }
                }
                try take(125)
            } else if current == 91 {
                index += 1; whitespace(); elements = []
                if current != 93 {
                    while true {
                        elements?.append(try value(depth: depth + 1)); whitespace()
                        if current != 44 { break }
                        index += 1
                    }
                }
                try take(93)
            } else if current == 34 {
                _ = try unboundedString()
            } else {
                while let c = current, ![9, 10, 13, 32, 44, 93, 125].contains(c) { index += 1 }
                guard index > start else { throw BrainError.invalidResponse }
                let token = Data(bytes[start..<index])
                // Foundation accepts fragments here; the generated codec validates tool token grammar.
                _ = try JSONSerialization.jsonObject(with: token, options: [.fragmentsAllowed])
            }
            return RawJSON(raw: Data(bytes[start..<index]), fields: fields, elements: elements)
        }
        mutating func unboundedString() throws -> String {
            let start = index
            try take(34)
            while let c = current {
                guard c >= 32 else { throw BrainError.invalidResponse }
                index += 1
                if c == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
                if c == 92 {
                    guard current != nil else { throw BrainError.invalidResponse }; index += 1
                }
            }
            throw BrainError.invalidResponse
        }
    }
}
