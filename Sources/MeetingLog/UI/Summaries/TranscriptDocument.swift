import Foundation

struct TranscriptLine: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// `## 00:00–10:00`, `## Recording 1: file`, or the document title.
        case heading(String)
        case turn(speaker: String, stamp: String, text: String)
        case text
    }

    var id: Int { number }
    let number: Int
    let text: String
    let seconds: Double?
    let kind: Kind

    /// Numbers match `TranscriptEvidence.annotated`, which counts every newline-separated line.
    static func parse(_ text: String) -> [TranscriptLine] {
        text.components(separatedBy: .newlines).enumerated().compactMap { index, line in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return TranscriptLine(number: index + 1, text: line, seconds: timestamp(line), kind: kind(line))
        }
    }

    private static func kind(_ line: String) -> Kind {
        if line.hasPrefix("#") {
            let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { return .heading(title) }
        }
        let ns = line as NSString
        guard let match = turnPattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return .text }
        return .turn(speaker: ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces),
                     stamp: ns.substring(with: match.range(at: 1)), text: ns.substring(with: match.range(at: 3)))
    }

    private static func timestamp(_ line: String) -> Double? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let parts = line[line.index(after: line.startIndex)..<close].split(separator: ":")
        guard parts.count == 2, let minutes = Int(parts[0]), let seconds = Int(parts[1]) else { return nil }
        return Double(minutes * 60 + seconds)
    }

    private static let turnPattern = try! NSRegularExpression(pattern: #"^\[(\d{2,}:[0-5]\d)\] ([^:\n]+): (.*)$"#)
}

/// A transcript file as the summary window reads it: numbered lines, speakers, and timestamp lookup.
struct TranscriptDocument: Equatable, Sendable {
    let lines: [TranscriptLine]
    /// `Me` first, then other speakers in order of first appearance.
    let speakers: [String]
    private let positions: [Int: Int]

    init(_ text: String) {
        lines = TranscriptLine.parse(text)
        speakers = Self.speakers(in: lines)
        positions = Dictionary(uniqueKeysWithValues: lines.enumerated().map { ($1.number, $0) })
    }

    func line(_ number: Int) -> TranscriptLine? {
        positions[number].map { lines[$0] }
    }

    /// The referenced turn's timestamp, or the nearest earlier one for continuation lines.
    func cueSeconds(for number: Int) -> Double? {
        guard let start = positions[number] ?? lines.lastIndex(where: { $0.number < number }) else { return nil }
        return lines[...start].last { $0.seconds != nil }?.seconds
    }

    /// Stable position among speakers other than `Me`, used to pick a speaker colour.
    func rank(of speaker: String) -> Int? {
        speakers.filter { $0 != "Me" }.firstIndex(of: speaker)
    }

    static func speakers(in lines: [TranscriptLine]) -> [String] {
        var seen: [String] = []
        for line in lines {
            if case let .turn(speaker, _, _) = line.kind, !seen.contains(speaker) { seen.append(speaker) }
        }
        return seen.contains("Me") ? ["Me"] + seen.filter { $0 != "Me" } : seen
    }

    /// The evidence file L numbers refer to: original transcription, or the readable copy in legacy archives.
    static func evidenceSource(in directory: URL) -> SummaryEvidence.Source {
        FileManager.default.fileExists(atPath: directory.appending(path: SummaryEvidence.Source.raw.rawValue).path)
            ? .raw : .legacy
    }
}
