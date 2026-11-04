import Foundation
import Pairing
#if os(Linux)
import Glibc
#else
import Darwin
#endif

private func closeDescriptor(_ descriptor: Int32) {
    #if os(Linux)
    _ = Glibc.close(descriptor)
    #else
    _ = Darwin.close(descriptor)
    #endif
}

/// Real loopback TCP client for the local E2E executable. The phone uses the
/// Network adapter; this executable has no fake transport or relay implementation.
final class SocketStream: LANByteStream, @unchecked Sendable {
    private let descriptor: Int32
    private let reader = DispatchQueue(label: "e2e.socket.read")
    private let writer = DispatchQueue(label: "e2e.socket.write")
    init(port: UInt16) throws {
        #if os(Linux)
        descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        descriptor = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard descriptor >= 0 else { throw PairingError.closedTransport }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { closeDescriptor(descriptor); throw PairingError.closedTransport }
        var limit = timeval(tv_sec: 15, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
    }
    deinit { closeDescriptor(descriptor) }
    private func stop() { _ = shutdown(descriptor, Int32(SHUT_RDWR)) }
    func read(upTo count: Int) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reader.async { [self] in
                    var bytes = [UInt8](repeating: 0, count: count)
                    let n = recv(descriptor, &bytes, count, 0)
                    if n > 0 { continuation.resume(returning: Data(bytes.prefix(n))) }
                    else { continuation.resume(throwing: PairingError.closedTransport) }
                }
            }
        } onCancel: { self.stop() }
    }
    func write(_ bytes: Data) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                writer.async { [self] in
                    do {
                        try bytes.withUnsafeBytes { buffer in
                            var offset = 0
                            while offset < buffer.count {
                                #if os(Linux)
                                let n = send(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, Int32(MSG_NOSIGNAL))
                                #else
                                let n = send(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                                #endif
                                guard n > 0 else { throw PairingError.closedTransport }; offset += n
                            }
                        }
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { self.stop() }
    }
    func close() async { stop() }
    func exact(_ count: Int) async throws -> Data {
        var bytes = Data()
        while bytes.count < count { bytes += try await read(upTo: count - bytes.count) }
        return bytes
    }
}
