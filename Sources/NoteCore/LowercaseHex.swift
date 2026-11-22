import CryptoKit

extension Sequence<UInt8> {
    /// The same text as `String(format: "%02x")` per byte, without
    /// Foundation formatting, which dominated hashing every note on a scan.
    var lowercaseHex: String {
        let digits = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(underestimatedCount * 2)
        for byte in self {
            bytes.append(digits[Int(byte >> 4)])
            bytes.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
