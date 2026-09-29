import Foundation

/// Short source names for the collapsed sources row, where three sources share one 400 pt line.
enum SourceNames {
    /// Generic words a device name ends with; dropping them leaves the part that tells devices apart.
    private static let genericSuffixes = ["microphone", "mic", "audio input", "input"]

    /// "Default" for the system default input; otherwise the device name without a generic suffix,
    /// so "MacBook Pro Microphone" reads "MacBook Pro". A name that is only the generic word is kept.
    static func microphone(_ deviceName: String?) -> String {
        guard let name = deviceName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return "Default" }
        for suffix in genericSuffixes {
            guard let range = name.range(of: suffix, options: [.caseInsensitive, .anchored, .backwards]),
                  range.lowerBound > name.startIndex,
                  name[name.index(before: range.lowerBound)].isWhitespace else { continue }
            let trimmed = name[..<range.lowerBound].trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
            if !trimmed.isEmpty { return trimmed }
        }
        return name
    }

    /// The Mac audio source as picked: "All apps" or the application's name.
    static func macAudio(applicationName: String?) -> String {
        guard let name = applicationName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return "All apps" }
        return name
    }
}
