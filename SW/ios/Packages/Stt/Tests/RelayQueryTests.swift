import Foundation
import XCTest
@testable import Stt

final class RelayQueryTests: XCTestCase {
    func testVocabularyUsesFormEncodingWithoutLosingLiteralPlus() throws {
        let engine = CloudEngine(vendor: .elevenLabs, settings: try ProxySettings(url: URL(string: "wss://relay.example/proxy/elevenlabs")!))
        let url = try engine.connectionURL(vocabulary: Vocabulary(userID: "synthetic", terms: ["O'Brien", "C++ ~ é"]))
        XCTAssertTrue(url.absoluteString.hasSuffix("&keyterms=O%27Brien&keyterms=C%2B%2B+%7E+%C3%A9"))
    }
}
