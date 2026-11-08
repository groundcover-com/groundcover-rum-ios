import Foundation

// gzip from Foundation's raw DEFLATE (NSData's `.zlib` writes RFC 1951 with no header) wrapped in
// the RFC 1952 header and trailer. Importing zlib itself would add it to the SDK's public interface.

private let gzipHeader: [UInt8] = [0x1F, 0x8B, 0x08, 0, 0, 0, 0, 0, 0, 0xFF]

/// `data` as a gzip stream, or nil if it couldn't be compressed.
func gzip(_ data: Data) -> Data? {
    let deflated: Data
    if data.isEmpty {
        // An empty final block: NSData gives back no bytes at all for empty input.
        deflated = Data([0x03, 0x00])
    } else {
        guard let compressed = try? (data as NSData).compressed(using: .zlib) else { return nil }
        deflated = compressed as Data
    }
    var out = Data(gzipHeader)
    out.append(deflated)
    appendLittleEndian(crc32(data), to: &out)
    appendLittleEndian(UInt32(truncatingIfNeeded: data.count), to: &out)
    return out
}

private func appendLittleEndian(_ value: UInt32, to data: inout Data) {
    data.append(contentsOf: [
        UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF),
        UInt8((value >> 24) & 0xFF),
    ])
}

private let crcTable: [UInt32] = (0..<256).map { index in
    var crc = UInt32(index)
    for _ in 0..<8 { crc = crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
    return crc
}

private func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
    return crc ^ 0xFFFF_FFFF
}
