import Foundation

/// Block parser for the Markdown MeetingLog writes and users may edit in Obsidian.
/// Evidence references such as `L12` become links that open the transcript at that line.
enum SummaryMarkdown: Equatable {
    case heading(level: Int, text: String)
    case bullet(marker: String, text: String, depth: Int)
    case detail(text: String, depth: Int)
    case quote(String)
    case table(header: [String], rows: [[String]])
    case paragraph(String)
    case rule

    static let lineScheme = "meetinglog-line"

    static func parse(_ markdown: String) -> [SummaryMarkdown] {
        let lines = markdown.components(separatedBy: .newlines)
        var blocks: [SummaryMarkdown] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let depth = line.prefix { $0 == " " }.count / 2
            index += 1
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("|") {
                var rows = [cells(trimmed)]
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[index].trimmingCharacters(in: .whitespaces)))
                    index += 1
                }
                let isSeparator = rows.count > 1 && rows[1].allSatisfy { cell in
                    !cell.isEmpty && cell.allSatisfy { "-: ".contains($0) }
                }
                blocks.append(isSeparator ? .table(header: rows[0], rows: Array(rows.dropFirst(2))) : .table(header: [], rows: rows))
            } else if let level = headingLevel(trimmed) {
                blocks.append(.heading(level: level, text: String(trimmed.dropFirst(level + 1))))
            } else if ["---", "***", "___"].contains(trimmed) {
                blocks.append(.rule)
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                blocks.append(.bullet(marker: "•", text: String(trimmed.dropFirst(2)), depth: depth))
            } else if let (number, text) = numbered(trimmed) {
                blocks.append(.bullet(marker: "\(number).", text: text, depth: depth))
            } else if trimmed.hasPrefix(">") {
                blocks.append(.quote(trimmed.dropFirst().trimmingCharacters(in: .whitespaces)))
            } else if depth > 0 {
                // Indented continuation, such as a decision's reasoning or evidence line.
                blocks.append(.detail(text: trimmed, depth: depth - 1))
            } else {
                blocks.append(.paragraph(trimmed))
            }
        }
        return blocks
    }

    static func inline(_ text: String) -> AttributedString {
        let ns = text as NSString
        let linked = referencePattern.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "[L$1](\(lineScheme):$1)")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: linked, options: options)) ?? AttributedString(text)
    }

    static func line(from url: URL) -> Int? {
        guard url.scheme == lineScheme else { return nil }
        return Int(url.absoluteString.dropFirst(lineScheme.count + 1))
    }

    private static let referencePattern = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_\[])L(\d+)\b"#)

    private static func headingLevel(_ line: String) -> Int? {
        let level = line.prefix { $0 == "#" }.count
        guard (1...6).contains(level), line.dropFirst(level).hasPrefix(" ") else { return nil }
        return level
    }

    private static func numbered(_ line: String) -> (Int, String)? {
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (number, String(rest.dropFirst(2)))
    }

    private static func cells(_ line: String) -> [String] {
        var body = Substring(line)
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|") { body = body.dropLast() }
        return body.split(separator: "|", omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "<br>", with: "\n")
                .replacingOccurrences(of: "&#124;", with: "|")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&amp;", with: "&")
        }
    }
}
