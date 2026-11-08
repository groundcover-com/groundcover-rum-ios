/// Event, span and trace ids, as lowercase hex.
protocol IdGenerator {
    /// 32 hex characters: 16 zeros, then 64 random bits.
    func generateTraceId() -> String

    /// 16 hex characters.
    func generateSpanId() -> String

    /// 32 hex characters.
    func generateId() -> String
}

/// Ids from the system's secure random source.
struct RandomIdGenerator: IdGenerator {
    private static let digits = Array("0123456789abcdef".utf8)
    private static let traceIdZeroPrefix = String(repeating: "0", count: 16)

    func generateTraceId() -> String { Self.traceIdZeroPrefix + Self.hex(count: 16) }

    func generateSpanId() -> String { Self.hex(count: 16) }

    func generateId() -> String { Self.hex(count: 32) }

    // One draw per 16 characters, 4 bits each.
    private static func hex(count: Int) -> String {
        var random = SystemRandomNumberGenerator()
        var characters = [UInt8](repeating: 0, count: count)
        for start in stride(from: 0, to: count, by: 16) {
            var bits = random.next()
            for index in start..<min(start + 16, count) {
                characters[index] = digits[Int(bits & 0xf)]
                bits >>= 4
            }
        }
        return String(decoding: characters, as: UTF8.self)
    }
}
