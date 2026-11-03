import Foundation
import XCTest
@testable import VoiceRemoteProtocol

final class RoundTripTests: XCTestCase {
    struct Vector: Decodable { let name: String; let schema: String; let value: JSONValue; let json: String? }
    struct RawVector: Decodable { let name: String; let schema: String; let json: String }
    struct Vectors: Decodable { let valid: [Vector]; let invalid: [Vector]; let raw_invalid: [RawVector] }
    func vectors() throws -> Vectors {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while root.path != "/" {
            let path = root.appendingPathComponent("SYS/protocol/vectors/golden.json")
            if FileManager.default.fileExists(atPath: path.path) {
                return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: path))
            }
            root.deleteLastPathComponent()
        }
        throw WireError.invalid("Cannot locate shared golden vectors")
    }
    func roundTrip<T: ProtocolRecord>(_ type: T.Type, _ data: Data) throws -> JSONValue {
        let value = try ProtocolCodec.decode(type, from: data)
        let output = try ProtocolCodec.encode(value)
        _ = try ProtocolCodec.decode(type, from: output)
        return try JSONDecoder().decode(JSONValue.self, from: output)
    }
    func typed(_ name: String, _ data: Data) throws -> JSONValue {
        switch name {
        case "AuditArchiveWriter": return try roundTrip(AuditArchiveWriter.self, data)
        case "AuditArchiveBlock": return try roundTrip(AuditArchiveBlock.self, data)
        case "AuditArchiveRead": return try roundTrip(AuditArchiveRead.self, data)
        case "AuditArchivePage": return try roundTrip(AuditArchivePage.self, data)
        case "RelayFrame": return try roundTrip(RelayFrame.self, data)
        case "RelayCiphertext": return try roundTrip(RelayCiphertext.self, data)
        case "RelayPresence": return try roundTrip(RelayPresence.self, data)
        case "RelayWakeRegistration": return try roundTrip(RelayWakeRegistration.self, data)
        case "PairingPayload": return try roundTrip(PairingPayload.self, data)
        case "InnerMessage": return try roundTrip(InnerMessage.self, data)
        case "DictationText": return try roundTrip(DictationText.self, data)
        case "FocusReport": return try roundTrip(FocusReport.self, data)
        case "DeviceInfo": return try roundTrip(DeviceInfo.self, data)
        case "Revoke": return try roundTrip(Revoke.self, data)
        case "TaskStatus": return try roundTrip(TaskStatus.self, data)
        case "CaptureSegment": return try roundTrip(CaptureSegment.self, data)
        case "CandidateAction": return try roundTrip(CandidateAction.self, data)
        case "AuthorizedCommand": return try roundTrip(AuthorizedCommand.self, data)
        case "AuditEntry": return try roundTrip(AuditEntry.self, data)
        case "Grant": return try roundTrip(Grant.self, data)
        case "ModeState": return try roundTrip(ModeState.self, data)
        case "CaptureStateReport": return try roundTrip(CaptureStateReport.self, data)
        case "TargetPrepare": return try roundTrip(TargetPrepare.self, data)
        case "TargetReady": return try roundTrip(TargetReady.self, data)
        case "DictationOutcome": return try roundTrip(DictationOutcome.self, data)
        case "DictationQuery": return try roundTrip(DictationQuery.self, data)
        case "CaptureControl": return try roundTrip(CaptureControl.self, data)
        case "CaptureControlResult": return try roundTrip(CaptureControlResult.self, data)
        case "ToolCall": return try roundTrip(ToolCall.self, data)
        case "SelectTargetTool": return try roundTrip(SelectTargetTool.self, data)
        case "OpenResourceTool": return try roundTrip(OpenResourceTool.self, data)
        case "DelegateTaskTool": return try roundTrip(DelegateTaskTool.self, data)
        case "CancelTaskTool": return try roundTrip(CancelTaskTool.self, data)
        case "PrepareSendTool": return try roundTrip(PrepareSendTool.self, data)
        default: throw WireError.invalid("Missing typed coverage: \(name)")
        }
    }
    func testSharedValidVectorsRoundTripThroughRealTypes() throws {
        let fixtures = try vectors()
        for v in fixtures.valid {
            let data = try v.json.map { Data($0.utf8) } ?? JSONEncoder().encode(v.value)
            XCTAssertNoThrow(try ProtocolCodec.validate(v.schema, json: data), v.name)
            XCTAssertEqual(try typed(v.schema, data), v.value, v.name)
        }
        print("\(fixtures.valid.count) shared valid vectors round-tripped")
    }
    func testSharedInvalidVectorsAreRejected() throws {
        let fixtures = try vectors()
        for v in fixtures.invalid {
            let data = try JSONEncoder().encode(v.value)
            XCTAssertThrowsError(try ProtocolCodec.validate(v.schema, json: data), v.name)
            XCTAssertThrowsError(try typed(v.schema, data), v.name)
        }
        print("\(fixtures.invalid.count) shared invalid vectors rejected")
    }
    func testConstructedValuesAreValidatedWhenEncoded() throws {
        let value = DictationText(account_id: "fixture-account", segment_id: "segment-1", revision: 0,
                                  state: .committed, target_device_id: "fixture-desktop", text: "SYNTHETIC\n")
        XCTAssertThrowsError(try ProtocolCodec.encode(value))
        XCTAssertThrowsError(try ProtocolCodec.decode(InnerMessage.self, from: Data("{\"kind\":\"unknown\"}".utf8)))
        XCTAssertThrowsError(try ProtocolCodec.decode(RelayFrame.self, from: Data("not JSON".utf8)))
    }
    func testSharedRawInvalidVectorsAreRejected() throws {
        let fixtures = try vectors()
        for v in fixtures.raw_invalid {
            let data = Data(v.json.utf8)
            XCTAssertThrowsError(try ProtocolCodec.validate(v.schema, json: data), v.name)
            XCTAssertThrowsError(try typed(v.schema, data), v.name)
        }
        print("\(fixtures.raw_invalid.count) shared raw invalid vectors rejected")
    }
}

extension RoundTripTests {
    func testDictationRejectsControlScalarsInsideGraphemeClusters() throws {
        let controls = Array(0...0x1f) + Array(0x7f...0x9f) + [0x2028, 0x2029]
        let clusters = ["\r\n", "a\r\nb", "\n\u{0301}", "a\r\n\u{0301}b"]
            + controls.map { "a" + String(Unicode.Scalar($0)!) + "\u{0301}b" }
        for (index, text) in clusters.enumerated() {
            let value = DictationText(account_id: "fixture-account", segment_id: "segment-1", revision: 0,
                                      state: .committed, target_device_id: "fixture-desktop", text: text)
            let wire = try JSONEncoder().encode(value) // Bypass encode's validation to test inbound data too.
            XCTAssertThrowsError(try ProtocolCodec.validate("DictationText", json: wire), "cluster \(index)")
            XCTAssertThrowsError(try ProtocolCodec.decode(DictationText.self, from: wire), "cluster \(index)")
            XCTAssertThrowsError(try ProtocolCodec.encode(value), "cluster \(index)")
        }
        let safe = DictationText(account_id: "fixture-account", segment_id: "segment-1", revision: 0,
                                 state: .committed, target_device_id: "fixture-desktop", text: "a\u{0301} 😀")
        XCTAssertNoThrow(try ProtocolCodec.decode(DictationText.self, from: ProtocolCodec.encode(safe)))
    }
    func testPortablePatternsRejectControlsWithoutRegexBoundarySemantics() {
        let base64 = "^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$"
        let key = "^[A-Za-z0-9+/]{43}=$"
        let hex = "^[0-9a-f]+$"
        func matches(_ pattern: String, _ text: String) -> Bool {
            Schema.accepts(.object(["pattern": .string(pattern)]), .string(text))
        }
        for text in ["", "YQ==", "YWI=", "YWJj", "YWJjYQ==", String(repeating: "A", count: 43) + "="] {
            XCTAssertTrue(matches(base64, text))
        }
        for text in ["A", "AA=", "A===", "=AAA", "AAAA=", "AA==AAAA"] { XCTAssertFalse(matches(base64, text)) }
        XCTAssertTrue(matches(key, String(repeating: "A", count: 43) + "="))
        XCTAssertTrue(matches(hex, "0123456789abcdef"))
        for text in ["", "ABCDEF", "g", "é"] { XCTAssertFalse(matches(hex, text)) }
        for cluster in ["\r\n", "a\r\nb", "\n\u{0301}", "\u{0000}\u{0301}"] {
            XCTAssertFalse(matches(base64, "YQ==" + cluster))
            XCTAssertFalse(matches(key, String(repeating: "A", count: 43) + "=" + cluster))
            XCTAssertFalse(matches(hex, "ab" + cluster))
            XCTAssertTrue(matches("[^A-Za-z0-9+/=]", cluster))
            XCTAssertTrue(matches("[^0-9a-f]", cluster))
        }
        XCTAssertFalse(matches("[^A-Za-z0-9+/=]", "YQ=="))
        XCTAssertFalse(matches("[^0-9a-f]", "abcdef0123"))
        XCTAssertFalse(matches("unreviewed-pattern", "unreviewed-pattern"))
    }
}
