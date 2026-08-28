struct LevelUpdateGate {
    private let intervalNanoseconds: UInt64
    private var nextUpdate: UInt64 = 0

    init(intervalNanoseconds: UInt64 = 100_000_000) {
        self.intervalNanoseconds = intervalNanoseconds
    }

    mutating func shouldPublish(at uptimeNanoseconds: UInt64) -> Bool {
        guard nextUpdate == 0 || uptimeNanoseconds >= nextUpdate else { return false }
        nextUpdate = uptimeNanoseconds &+ intervalNanoseconds
        return true
    }

    mutating func reset() {
        nextUpdate = 0
    }
}
