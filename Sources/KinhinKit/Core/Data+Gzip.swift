import Foundation

// MARK: - gzip

extension Data {
    /// This data as a gzip member (RFC 1952), decodable with `gzip -dc` on
    /// macOS and Debian/Ubuntu guests. Foundation's `.zlib` algorithm emits
    /// raw DEFLATE (RFC 1951); this adds the gzip header and CRC32/size trailer.
    func gzipped() throws -> Data {
        let deflated = try (self as NSData).compressed(using: .zlib) as Data
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03])
        out.append(deflated)
        Swift.withUnsafeBytes(of: Self.crc32(self).littleEndian) { out.append(contentsOf: $0) }
        Swift.withUnsafeBytes(of: UInt32(truncatingIfNeeded: count).littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    /// CRC-32 (IEEE 802.3, reflected polynomial 0xEDB88320) as gzip requires.
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return ~crc
    }
}
