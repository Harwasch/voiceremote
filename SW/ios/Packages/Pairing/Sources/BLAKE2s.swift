import Foundation

/// Unkeyed BLAKE2s-256, RFC 7693 §§2–3. Noise uses HMAC, not keyed BLAKE2.
/// Written from the algorithm; no third-party implementation is embedded.
enum BLAKE2s {
    private static let iv: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ]
    private static let sigma: [[Int]] = [
        [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15],
        [14,10,4,8,9,15,13,6,1,12,0,2,11,7,5,3],
        [11,8,12,0,5,2,15,13,10,14,3,6,7,1,9,4],
        [7,9,3,1,13,12,11,14,2,6,5,10,4,0,15,8],
        [9,0,5,7,2,4,10,15,14,1,11,12,6,8,3,13],
        [2,12,6,10,0,11,8,3,4,13,7,5,15,14,1,9],
        [12,5,1,15,14,13,4,10,0,7,6,3,9,2,8,11],
        [13,11,7,14,12,1,3,9,5,0,15,4,8,6,2,10],
        [6,15,14,9,11,3,0,8,12,2,13,7,1,4,10,5],
        [10,2,8,4,7,6,1,5,15,11,9,14,3,12,13,0]
    ]
    private static func rotate(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
    private static func g(_ v: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt32, _ y: UInt32) {
        v[a] = v[a] &+ v[b] &+ x; v[d] = rotate(v[d] ^ v[a], 16)
        v[c] = v[c] &+ v[d]; v[b] = rotate(v[b] ^ v[c], 12)
        v[a] = v[a] &+ v[b] &+ y; v[d] = rotate(v[d] ^ v[a], 8)
        v[c] = v[c] &+ v[d]; v[b] = rotate(v[b] ^ v[c], 7)
    }
    static func hash(_ data: Data) -> Data {
        let input = [UInt8](data)
        var h = iv
        h[0] ^= 0x01010020 // fanout=1, depth=1, key length=0, digest length=32
        var offset = 0
        repeat {
            let size = min(64, input.count - offset)
            var block = [UInt8](repeating: 0, count: 64)
            if size > 0 { block.replaceSubrange(0..<size, with: input[offset..<(offset + size)]) }
            let m: [UInt32] = stride(from: 0, to: 64, by: 4).map { i -> UInt32 in
                let low = UInt32(block[i]) | (UInt32(block[i+1]) << 8)
                let high = (UInt32(block[i+2]) << 16) | (UInt32(block[i+3]) << 24)
                return low | high
            }
            var v = h + iv
            let count = UInt64(offset + size)
            v[12] ^= UInt32(truncatingIfNeeded: count)
            v[13] ^= UInt32(truncatingIfNeeded: count >> 32)
            if offset + size == input.count { v[14] = ~v[14] }
            for s in sigma {
                g(&v,0,4,8,12,m[s[0]],m[s[1]]); g(&v,1,5,9,13,m[s[2]],m[s[3]])
                g(&v,2,6,10,14,m[s[4]],m[s[5]]); g(&v,3,7,11,15,m[s[6]],m[s[7]])
                g(&v,0,5,10,15,m[s[8]],m[s[9]]); g(&v,1,6,11,12,m[s[10]],m[s[11]])
                g(&v,2,7,8,13,m[s[12]],m[s[13]]); g(&v,3,4,9,14,m[s[14]],m[s[15]])
            }
            for i in 0..<8 { h[i] ^= v[i] ^ v[i+8] }
            offset += size
        } while offset < input.count
        return Data(h.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) } })
    }
    static func hmac(key: Data, data: Data) -> Data {
        var bytes = [UInt8](key.count > 64 ? hash(key) : key)
        bytes += [UInt8](repeating: 0, count: 64 - bytes.count)
        return hash(Data(bytes.map { $0 ^ 0x5c }) + hash(Data(bytes.map { $0 ^ 0x36 }) + data))
    }
    static func hkdf(chainingKey: Data, input: Data) -> (Data, Data) {
        let temp = hmac(key: chainingKey, data: input)
        let first = hmac(key: temp, data: Data([1]))
        return (first, hmac(key: temp, data: first + Data([2])))
    }
}
