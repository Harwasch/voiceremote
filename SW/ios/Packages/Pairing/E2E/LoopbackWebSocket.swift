import Foundation
import Crypto
import Pairing

/// RFC6455 client over real loopback TCP. Linux FoundationNetworking lacks
/// WebSocket support in some libcurl builds. Never accepts a remote ws:// URL.
struct LoopbackWebSocketConnector: WebSocketConnector {
    func connect(_ request: RelayRequest) async throws -> WebSocketUpgrade {
        guard request.url.scheme == "ws", request.url.host == "127.0.0.1", let port = request.url.port,
              let tcpPort = UInt16(exactly: port) else { throw PairingError.invalidMessage }
        let stream = try SocketStream(port: tcpPort)
        do {
            let key = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0).base64EncodedString() }
            var headers = request.headers
            headers["Host"] = "127.0.0.1:\(port)"; headers["Upgrade"] = "websocket"; headers["Connection"] = "Upgrade"
            headers["Sec-WebSocket-Version"] = "13"; headers["Sec-WebSocket-Key"] = key
            var raw = "GET \(request.url.path) HTTP/1.1\r\n"
            for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
                guard !(name + value).contains("\r"), !(name + value).contains("\n") else { throw PairingError.invalidMessage }
                raw += "\(name): \(value)\r\n"
            }
            try await stream.write(Data((raw + "\r\n").utf8))
            var response = Data()
            while !response.suffix(4).elementsEqual([13, 10, 13, 10]) {
                guard response.count < 16_384 else { throw PairingError.messageTooLarge }
                response += try await stream.exact(1)
            }
            let lines = String(decoding: response, as: UTF8.self).components(separatedBy: "\r\n")
            let status = Int(lines[0].split(separator: " ").dropFirst().first ?? "") ?? 0
            guard status == 101 else { throw RelayError.httpRefused(status) }
            var received: [String: String] = [:]
            for line in lines.dropFirst() {
                if let colon = line.firstIndex(of: ":") { received[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces) }
            }
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            guard received["sec-websocket-accept"] == accept, received["upgrade"]?.lowercased() == "websocket" else { throw PairingError.invalidMessage }
            let socket = LoopbackWebSocket(stream: stream)
            await socket.start()
            return .init(socket: socket, headers: received)
        } catch { await stream.close(); throw error }
    }
}
private actor LoopbackWebSocket: WebSocket {
    let stream: SocketStream
    private var task: Task<Void, Never>?
    private var queued: [WebSocketMessage] = []
    private var waiter: CheckedContinuation<WebSocketMessage, any Error>?
    private var pong: CheckedContinuation<Void, any Error>?
    private var pingBytes: Data?
    private var closed = false
    init(stream: SocketStream) { self.stream = stream }
    func start() { task = Task { [weak self] in await self?.readLoop() } }
    private func write(opcode: UInt8, bytes: Data) async throws {
        guard !closed, bytes.count <= 16_384 else { throw PairingError.closedTransport }
        let mask = SymmetricKey(size: .bits128).withUnsafeBytes { Array($0.prefix(4)) }
        var frame = Data([0x80 | opcode])
        if bytes.count < 126 { frame.append(0x80 | UInt8(bytes.count)) }
        else { frame += Data([0xfe, UInt8(bytes.count >> 8), UInt8(bytes.count & 255)]) }
        frame += Data(mask)
        frame += Data(bytes.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        try await stream.write(frame)
    }
    func send(text: String) async throws { try await write(opcode: 1, bytes: Data(text.utf8)) }
    func receive() async throws -> WebSocketMessage {
        try await withTaskCancellationHandler {
            guard !closed else { throw PairingError.closedTransport }
            if !queued.isEmpty { return queued.removeFirst() }
            guard waiter == nil else { throw PairingError.invalidState }
            return try await withCheckedThrowingContinuation { waiter = $0 }
        } onCancel: { Task { await self.close() } }
    }
    func ping() async throws {
        guard pong == nil else { throw PairingError.invalidState }
        let bytes = Data([1, 2, 3, 4]); pingBytes = bytes
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                pong = continuation
                Task {
                    do { try await self.write(opcode: 9, bytes: bytes) }
                    catch { await self.close() }
                }
            }
        } onCancel: { Task { await self.close() } }
    }
    private func readLoop() async {
        do {
            var fragment = Data(); var fragmentOpcode: UInt8?
            while !closed {
                let head = try await stream.exact(2)
                guard head[0] & 0x70 == 0, head[1] & 0x80 == 0 else { throw PairingError.invalidMessage }
                let final = head[0] & 0x80 != 0; let opcode = head[0] & 15
                var count = Int(head[1] & 127)
                if count == 126 { count = try await stream.exact(2).reduce(0) { $0 * 256 + Int($1) } }
                else if count == 127 {
                    let length = try await stream.exact(8)
                    guard length.prefix(6).allSatisfy({ $0 == 0 }) else { throw PairingError.messageTooLarge }
                    count = length.suffix(2).reduce(0) { $0 * 256 + Int($1) }
                }
                guard count <= 16_384, opcode < 8 || (final && count <= 125) else { throw PairingError.messageTooLarge }
                let bytes = try await stream.exact(count)
                switch opcode {
                case 8: throw PairingError.closedTransport
                case 9: try await write(opcode: 10, bytes: bytes)
                case 10:
                    if bytes == pingBytes { pong?.resume(); pong = nil; pingBytes = nil }
                case 0, 1, 2:
                    if opcode != 0 { guard fragmentOpcode == nil else { throw PairingError.invalidMessage }; fragmentOpcode = opcode }
                    guard fragmentOpcode != nil, fragment.count + count <= 16_384 else { throw PairingError.invalidMessage }
                    fragment += bytes
                    if final {
                        let message: WebSocketMessage
                        if fragmentOpcode == 1 {
                            guard let text = String(data: fragment, encoding: .utf8) else { throw PairingError.invalidMessage }
                            message = .text(text)
                        } else { message = .binary(fragment) }
                        fragment = Data(); fragmentOpcode = nil
                        if let waiter { self.waiter = nil; waiter.resume(returning: message) }
                        else { guard queued.count < 32 else { throw PairingError.messageTooLarge }; queued.append(message) }
                    }
                default: throw PairingError.invalidMessage
                }
            }
        } catch { await close() }
    }
    func close() async {
        guard !closed else { return }; closed = true
        task?.cancel(); task = nil
        waiter?.resume(throwing: PairingError.closedTransport); waiter = nil
        pong?.resume(throwing: PairingError.closedTransport); pong = nil
        await stream.close()
    }
}
