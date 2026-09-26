import Foundation

/// Stable runtime values derived from encounter identity + event sequence.
/// LiveState reducers must not create random IDs or wall-clock timestamps.
public enum Determinism {
    public static func id(encounterID: UUID, sequence: Int, domain: String, index: Int = 0) -> UUID {
        let input = "\(encounterID.uuidString.lowercased())|\(sequence)|\(domain)|\(index)"
        let a = fnv1a64(input, seed: 0xcbf29ce484222325)
        let b = fnv1a64(input, seed: 0x84222325cbf29ce4)
        let hex = String(format: "%016llx%016llx", a, b)
        let value = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-4\(hex.dropFirst(13).prefix(3))-a\(hex.dropFirst(17).prefix(3))-\(hex.dropFirst(20).prefix(12))"
        return UUID(uuidString: value)!
    }

    public static func timestamp(sequence: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(sequence) / 1_000)
    }

    private static func fnv1a64(_ value: String, seed: UInt64) -> UInt64 {
        var hash = seed
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }
}
