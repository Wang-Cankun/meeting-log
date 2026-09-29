/// Detects an included microphone that delivers essentially no input during recording.
///
/// Levels are raw dBFS from the capture channel, not the meter scale: the meter bottoms out at −60 dBFS and
/// cannot distinguish a quiet room (roughly −85…−60 dBFS) from a muted or disconnected device (−120 dBFS or
/// −∞). −96 dBFS is about one 16-bit step.
struct MicrophoneSilenceMonitor {
    static let floorDecibels: Float = -96
    static let warningDelayNanoseconds: UInt64 = 30_000_000_000
    /// Input must hold this long to end an episode, so a crackle or one gated word does not re-arm the warning.
    static let recoveryDelayNanoseconds: UInt64 = 2_000_000_000
    /// Minimum spacing between system notifications in one recording; the inline warning follows every episode.
    static let notificationSpacingNanoseconds: UInt64 = 300_000_000_000

    enum Event: Equatable {
        case none
        case began
        case ended
    }

    private(set) var silentSince: UInt64?
    private(set) var inputSince: UInt64?
    private(set) var isWarning = false
    private(set) var hasReading = false
    private var lastNotification: UInt64?

    /// A missing reading (`nil` channel or NaN) is unknown until the first real reading, while the session
    /// starts; after that it counts as silence, because the capture connection has lost its audio channel.
    mutating func observe(decibels: Float?, at uptimeNanoseconds: UInt64) -> Event {
        let reading = decibels.flatMap { $0.isNaN ? nil : $0 }
        if reading != nil { hasReading = true } else if !hasReading { return .none }

        guard let reading, reading > Self.floorDecibels else {
            inputSince = nil
            let start = silentSince ?? uptimeNanoseconds
            silentSince = start
            guard !isWarning, uptimeNanoseconds >= start,
                  uptimeNanoseconds - start >= Self.warningDelayNanoseconds else { return .none }
            isWarning = true
            return .began
        }

        silentSince = nil
        guard isWarning else { return .none }
        let start = inputSince ?? uptimeNanoseconds
        inputSince = start
        guard uptimeNanoseconds >= start,
              uptimeNanoseconds - start >= Self.recoveryDelayNanoseconds else { return .none }
        isWarning = false
        inputSince = nil
        return .ended
    }

    /// Whether a new episode also posts a system notification; records the post when it does.
    mutating func shouldNotify(at uptimeNanoseconds: UInt64) -> Bool {
        if let lastNotification, uptimeNanoseconds >= lastNotification,
           uptimeNanoseconds - lastNotification < Self.notificationSpacingNanoseconds { return false }
        lastNotification = uptimeNanoseconds
        return true
    }

    mutating func reset() {
        silentSince = nil
        inputSince = nil
        isWarning = false
        hasReading = false
        lastNotification = nil
    }
}
