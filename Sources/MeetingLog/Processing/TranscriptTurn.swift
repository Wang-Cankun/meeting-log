import Foundation

struct TranscriptTurn: Codable, Sendable {
    let startMilliseconds: Int
    var durationMilliseconds: Int? = nil
    var speaker: String
    var text: String

    static let recordingUser = "Me"
    static let silence = "[no audible speech]"

    var line: String {
        let seconds = startMilliseconds / 1000
        return String(format: "[%02d:%02d] ", seconds / 60, seconds % 60) + "\(speaker): \(text)"
    }

    static func parse(_ text: String) -> [TranscriptTurn] {
        text.components(separatedBy: .newlines).compactMap { line in
            let ns = line as NSString
            guard let match = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  let minutes = Int(ns.substring(with: match.range(at: 2))),
                  minutes <= Int.max / 60_000 - 1,
                  let seconds = Int(ns.substring(with: match.range(at: 3))) else { return nil }
            var totalMinutes = minutes
            if match.range(at: 1).location != NSNotFound {
                guard minutes < 60, let hours = Int(ns.substring(with: match.range(at: 1))) else { return nil }
                totalMinutes += hours * 60
            }
            return TranscriptTurn(startMilliseconds: (totalMinutes * 60 + seconds) * 1000,
                                  speaker: ns.substring(with: match.range(at: 4)),
                                  text: ns.substring(with: match.range(at: 5)))
        }
    }

    private static let pattern = try! NSRegularExpression(pattern: #"^\[(?:(\d{1,2}):)?(\d{2,}):([0-5]\d)\] ([^:\n]+): (.+)$"#)
}
