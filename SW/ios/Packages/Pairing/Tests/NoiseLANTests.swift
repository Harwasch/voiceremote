import Foundation
import XCTest
@testable import Pairing

private actor ByteStream: LANByteStream {
    var input: Data
    var output = Data()
    var closed = false
    let chunk: Int
    init(_ bytes: Data, chunk: Int = 1) { input = bytes; self.chunk = chunk }
    func read(upTo count: Int) throws -> Data {
        guard !closed, !input.isEmpty else { throw PairingError.closedTransport }
        let part = Data(input.prefix(min(chunk, count))); input.removeFirst(part.count); return part
    }
    func write(_ bytes: Data) throws {
        guard !closed else { throw PairingError.closedTransport }
        output += bytes
    }
    func close() { closed = true }
}
final class NoiseLANTests: XCTestCase, @unchecked Sendable {
    func testPrivateLANAddressPolicy() throws {
        for address in [[10, 1, 2, 3], [127, 0, 0, 1], [172, 16, 0, 1], [192, 168, 1, 2], [169, 254, 1, 1]] {
            XCTAssertTrue(LANAddress.allowed(Data(address.map(UInt8.init))))
        }
        for address in [[0, 0, 0, 0], [8, 8, 8, 8], [172, 15, 0, 1], [172, 32, 0, 1], [192, 169, 0, 1], [224, 0, 0, 1]] {
            XCTAssertFalse(LANAddress.allowed(Data(address.map(UInt8.init))))
        }
        for (address, expected) in [("00000000000000000000000000000001", true), ("fc000000000000000000000000000001", true), ("fe800000000000000000000000000001", true), ("20010000000000000000000000000001", false), ("00000000000000000000000000000000", false)] {
            XCTAssertEqual(LANAddress.allowed(try hex(address)), expected)
        }
    }
    func testTCPFrameSplitsCoalescingAndMaximum() async throws {
        try await testDeadline(seconds: 20) { [self] in
            let frames = [Data([1, 2, 3]), Data(repeating: 7, count: 65_535)]
            let wire = frames.reduce(Data()) { $0 + SessionWire.u32($1.count) + $1 }
            let stream = ByteStream(wire, chunk: 3); let transport = LANTransport(stream: stream)
            for frame in frames {
                let decoded = try await transport.receive(); XCTAssertEqual(decoded, frame)
                try await transport.send(frame)
            }
            let output = await stream.output; XCTAssertEqual(output, wire)
            await transport.close()
        }
    }
    func testZeroOversizeTruncatedFramesAndDisconnectClose() async throws {
        try await testDeadline(seconds: 20) { [self] in
            for bytes in [SessionWire.u32(0), SessionWire.u32(65_536), Data([0, 0]), SessionWire.u32(3) + Data([1])] {
                let stream = ByteStream(bytes); let transport = LANTransport(stream: stream)
                do { _ = try await transport.receive(); XCTFail() } catch {}
                let closed = await stream.closed; XCTAssertTrue(closed)
                do { try await transport.send(Data([1])); XCTFail() } catch {}
            }
            for frame in [Data(), Data(repeating: 0, count: 65_536)] {
                let stream = ByteStream(Data()); let transport = LANTransport(stream: stream)
                do { try await transport.send(frame); XCTFail() } catch {}
                let closed = await stream.closed; XCTAssertTrue(closed)
            }
        }
    }
}
