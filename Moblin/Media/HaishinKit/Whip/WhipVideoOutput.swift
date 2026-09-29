import Foundation

struct WhipVideoOutput {
    private var startedAt: UInt64?
    private var bytes: Int64 = 0
    private var bitrate: Int64?

    mutating func start(now: UInt64) {
        startedAt = now
        bytes = 0
        bitrate = nil
    }

    mutating func add(bytes: Int) {
        self.bytes += Int64(bytes)
    }

    mutating func sample(now: UInt64) -> Int64? {
        guard let startedAt, now >= startedAt else {
            return nil
        }
        let elapsed = now - startedAt
        guard elapsed >= 500_000_000 else {
            return bitrate
        }
        bitrate = Int64(Double(bytes) * 8_000_000_000 / Double(elapsed))
        self.startedAt = now
        bytes = 0
        return bitrate
    }
}
