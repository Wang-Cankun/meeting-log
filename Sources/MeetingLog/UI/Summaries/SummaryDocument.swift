import Foundation

/// One `L<n>` reference in a summary. The renderer marks references whose quote was not found on the cited
/// line with `[unverified reference]`; the Chinese summary may translate that marker.
struct EvidenceMark: Equatable, Hashable, Sendable {
    let line: Int
    var verified = true
    /// The words the summary quoted for this reference, when an evidence line carries them.
    var quote: String? = nil
}

enum InlineRun: Equatable {
    case text(String)
    case reference(EvidenceMark)
}

/// Inline evidence parsing shared by the structured summary, snippets, and the scrubber's evidence ticks.
enum SummaryInline {
    /// Splits text into plain runs and `L<n>` references. References inside quoted transcript words stay text.
    static func runs(_ text: String) -> [InlineRun] {
        let ns = text as NSString
        let quotes = quoteRanges(in: text)
        var result: [InlineRun] = []
        var cursor = 0
        func appendText(_ value: String) {
            guard !value.isEmpty else { return }
            if case let .text(previous)? = result.last { result[result.count - 1] = .text(previous + value) }
            else { result.append(.text(value)) }
        }
        for match in referencePattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard !quotes.contains(where: { NSLocationInRange(match.range.location, $0) }),
                  let line = Int(ns.substring(with: match.range(at: 1))) else { continue }
            var end = match.range(at: 1).location + match.range(at: 1).length
            var verified = true
            if match.range(at: 2).location != NSNotFound, isUnverifiedMarker(ns.substring(with: match.range(at: 2))) {
                verified = false
                end = match.range.location + match.range.length
            }
            appendText(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            result.append(.reference(EvidenceMark(line: line, verified: verified)))
            cursor = end
        }
        appendText(ns.substring(from: cursor))
        return result
    }

    /// Every distinct reference in order of first appearance.
    static func references(inMarkdown text: String) -> [EvidenceMark] {
        var seen = Set<Int>()
        return runs(text).compactMap {
            guard case let .reference(mark) = $0, seen.insert(mark.line).inserted else { return nil }
            return mark
        }
    }

    /// The reference list of an evidence line such as `Evidence: L12: “quote”; L40 [unverified reference]: “quote”`
    /// or a legacy table cell line `L39: “quote”`. Returns nil when the line holds anything besides references,
    /// so no content is hidden behind chips.
    static func evidenceList(_ line: String) -> [EvidenceMark]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let ns = trimmed as NSString
        guard let label = evidenceLabel.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let body = ns.substring(from: label.range.length)
        let bodyNS = body as NSString
        var marks: [EvidenceMark] = []
        var remainder = ""
        var cursor = 0
        for match in evidenceItem.matches(in: body, range: NSRange(location: 0, length: bodyNS.length)) {
            remainder += bodyNS.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length
            guard let number = Int(bodyNS.substring(with: match.range(at: 1))) else { return nil }
            let status = match.range(at: 2).location == NSNotFound ? "" : bodyNS.substring(with: match.range(at: 2))
            let quote = (3...5).lazy.map { match.range(at: $0) }.first { $0.location != NSNotFound }.map { bodyNS.substring(with: $0) }
            marks.append(EvidenceMark(line: number, verified: !isUnverifiedMarker(status), quote: quote))
        }
        remainder += bodyNS.substring(from: cursor)
        guard !marks.isEmpty,
              remainder.unicodeScalars.allSatisfy({ CharacterSet.whitespaces.contains($0) || ";；,，、。.".unicodeScalars.contains($0) })
        else { return nil }
        return marks
    }

    /// Stands in for an inline `[needs verification]` marker (or its Chinese form) so the view can draw it as an
    /// icon; a private-use character never occurs in summary text and stays attached to the preceding word.
    static let verificationMark: Character = "\u{E000}"

    /// Replaces each inline needs-verification marker, and the space before it, with `verificationMark`.
    static func markingVerification(_ text: String) -> String {
        let ns = text as NSString
        return verificationPattern.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length),
                                                            withTemplate: String(verificationMark))
    }

    /// Plain text without evidence references or verification markers, for list snippets.
    static func plain(_ text: String) -> String {
        let joined = runs(markingVerification(text)).map { run -> String in
            if case let .text(value) = run { return value }
            return ""
        }.joined()
        .replacingOccurrences(of: String(verificationMark), with: "")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let unformatted = (try? AttributedString(markdown: joined, options: options)).map { String($0.characters) } ?? joined
        return unformatted
            .replacingOccurrences(of: #"[(（\[]\s*[,;，；、\s]*\s*[)）\]]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([.,;:!?。，；：！？])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isUnverifiedMarker(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("unverified") || lower.contains("approximate")
            || ["未验证", "未经验证", "未核实", "未经核实", "未确认", "无法核实", "近似"].contains { value.contains($0) }
    }

    private static func quoteRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        return quotePattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
    }

    private static let referencePattern = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_\[])L(\d+)\b(?:[ \t]*\[([^\]\n]{1,40})\])?"#)
    private static let verificationPattern = try! NSRegularExpression(
        pattern: #"[ \t]*\[(?:needs verification|待核实|需核实|需要核实)\]"#,
        options: [.caseInsensitive])
    private static let quotePattern = try! NSRegularExpression(pattern: #"“[^”\n]*”|「[^」\n]*」"#)
    /// An optional short label such as `Evidence:`, `证据：` or `依据:` directly before the first reference.
    private static let evidenceLabel = try! NSRegularExpression(pattern: #"^(?:[^\s:：“”「」]{1,16}\s?[:：]\s*)?(?=L\d)"#)
    private static let evidenceItem = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_])L(\d+)\b(?:\s*\[([^\]\n]*)\])?(?:\s*[:：]\s*(?:“([^”]*)”|"([^"]*)"|「([^」]*)」))?"#)
}

struct SummaryItem: Equatable {
    var marker = "•"
    let text: String
    /// Indented continuation lines, such as a decision's reasoning or an action's context.
    var notes: [String] = []
    var evidence: [EvidenceMark] = []
}

struct ActionCard: Equatable {
    let task: String
    /// Whether the source states owner and deadline fields at all; legacy one-line items do not.
    var hasFields = false
    /// nil means the field exists but was not stated.
    var owner: String? = nil
    var deadline: String? = nil
    var notes: [String] = []
    var evidence: [EvidenceMark] = []
}

enum SummarySectionBody: Equatable {
    case items([SummaryItem])
    case actions([ActionCard])
    /// Anything the structured forms cannot represent losslessly renders as generic Markdown blocks.
    case blocks([SummaryMarkdown])
}

struct SummarySection: Equatable, Identifiable {
    enum Kind: Equatable {
        case summary, actionItems, decisions, milestones, openQuestions, deferredWork, inventory, keyTopics
        case needsVerification, other
    }

    let id: Int
    let kind: Kind
    /// nil for content before the first section heading.
    let heading: String?
    let body: SummarySectionBody

    /// `summary_cn.md` translates headings freely, so classification uses keywords from both languages.
    static func kind(for heading: String) -> Kind {
        let value = heading.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { value.contains($0) } }
        if has(["question", "问题"]) { return .openQuestions }
        if has(["verif", "核实", "确认", "验证", "核查"]) { return .needsVerification }
        if has(["milestone", "里程碑"]) { return .milestones }
        if has(["deferred", "postpone", "延期", "延后", "推迟", "暂缓", "搁置"]) { return .deferredWork }
        if has(["infrastructure", "document", "基础设施", "文档"]) { return .inventory }
        if has(["action", "to-do", "todo", "待办", "行动", "任务"]) { return .actionItems }
        if has(["decision", "决定", "决策", "已决", "决议"]) { return .decisions }
        if has(["topic", "议题", "主题", "话题"]) { return .keyTopics }
        if has(["summary", "overview", "总结", "概述", "摘要", "概要"]) { return .summary }
        return .other
    }
}

/// A summary Markdown file split into its title, metadata and typed sections.
struct SummaryDocument: Equatable {
    var title: String?
    /// Raw `- Date:` value, `yyyy-MM-dd HH:mm` for summaries MeetingLog wrote.
    var date: String?
    var project: String?
    var evidence: String?
    var sections: [SummarySection] = []

    static func parse(_ markdown: String) -> SummaryDocument {
        var document = SummaryDocument()
        var preamble: [String] = []
        var parts: [(heading: String, lines: [String])] = []
        for line in markdown.components(separatedBy: .newlines) {
            if line.hasPrefix("## ") {
                parts.append((line.dropFirst(3).trimmingCharacters(in: .whitespaces), []))
            } else if parts.isEmpty {
                if document.title == nil, line.hasPrefix("# ") {
                    document.title = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
                } else if document.date == nil, let value = metadata(line, "- Date: ") {
                    document.date = value
                } else if document.project == nil, let value = metadata(line, "- Project: ") {
                    document.project = value
                } else if document.evidence == nil, let value = metadata(line, "- Evidence: ") {
                    document.evidence = value
                } else {
                    preamble.append(line)
                }
            } else {
                parts[parts.count - 1].lines.append(line)
            }
        }
        let leading = SummaryMarkdown.parse(preamble.joined(separator: "\n"))
        if !leading.isEmpty {
            document.sections.append(SummarySection(id: 0, kind: .other, heading: nil, body: .blocks(leading)))
        }
        for part in parts {
            let kind = SummarySection.kind(for: part.heading)
            document.sections.append(SummarySection(id: document.sections.count, kind: kind, heading: part.heading,
                                                    body: body(kind: kind, lines: part.lines)))
        }
        return document
    }

    /// First Summary bullet without evidence markers; older summaries without that section use their first item.
    var snippet: String? {
        let ordered = sections.filter { $0.kind == .summary } + sections.filter { $0.kind != .summary }
        for section in ordered {
            let text: String?
            switch section.body {
            case let .items(items): text = items.first?.text
            case let .actions(cards): text = cards.first?.task
            case let .blocks(blocks):
                text = blocks.lazy.compactMap { block -> String? in
                    switch block {
                    case let .bullet(_, text, _), let .paragraph(text): return text
                    default: return nil
                    }
                }.first
            }
            if let text {
                let plain = SummaryInline.plain(text)
                if !plain.isEmpty { return plain }
            }
        }
        return nil
    }

    /// Start time from the `- Date:` line, interpreted in the current time zone like the renderer wrote it.
    static func startDate(_ value: String?, timeZone: TimeZone = .current) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: String(value.trimmingCharacters(in: .whitespaces).prefix(16)))
    }

    private static func metadata(_ line: String, _ prefix: String) -> String? {
        line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) : nil
    }

    private static func body(kind: SummarySection.Kind, lines: [String]) -> SummarySectionBody {
        let blocks = SummaryMarkdown.parse(lines.joined(separator: "\n"))
        if kind == .actionItems, blocks.count == 1, case let .table(header, rows) = blocks[0],
           let cards = actionCards(header: header, rows: rows) {
            return .actions(cards)
        }
        guard !blocks.isEmpty, let items = items(from: blocks) else { return .blocks(blocks) }
        return kind == .actionItems ? .actions(items.map(actionCard)) : .items(items)
    }

    private static func items(from blocks: [SummaryMarkdown]) -> [SummaryItem]? {
        var items: [SummaryItem] = []
        for block in blocks {
            switch block {
            case .bullet(let marker, let text, 0):
                items.append(SummaryItem(marker: marker, text: text))
            case let .detail(text, _) where !items.isEmpty:
                if let marks = SummaryInline.evidenceList(text) { items[items.count - 1].evidence += marks }
                else { items[items.count - 1].notes.append(text) }
            default:
                return nil
            }
        }
        return items
    }

    private static func actionCard(_ item: SummaryItem) -> ActionCard {
        var card = ActionCard(task: item.text, evidence: item.evidence)
        for note in item.notes {
            if !card.hasFields, let fields = ownerAndDeadline(note) {
                card.hasFields = true
                card.owner = fields.owner
                card.deadline = fields.deadline
            } else {
                card.notes.append(note)
            }
        }
        return card
    }

    /// Parses `Owner: X · Deadline: Y`, including translated labels such as `负责人：X · 截止日期：Y`.
    static func ownerAndDeadline(_ line: String) -> (owner: String?, deadline: String?)? {
        var owner: String?? = nil
        var deadline: String?? = nil
        let parts = line.components(separatedBy: "·").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count <= 3 else { return nil }
        for part in parts {
            guard let colon = part.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return nil }
            let label = part[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "*_ ")).lowercased()
            let value = stated(String(part[part.index(after: colon)...]))
            if isLabel(label, ownerLabels) { owner = .some(value) }
            else if isLabel(label, deadlineLabels) { deadline = .some(value) }
            else { return nil }
        }
        guard owner != nil || deadline != nil else { return nil }
        return (owner ?? nil, deadline ?? nil)
    }

    /// English labels must be the whole label, so a note such as `Due to the holiday: …` stays visible text.
    /// Translated labels vary (`截止日期`, `截止时间`), so those match by keyword.
    private static func isLabel(_ label: String, _ words: [String]) -> Bool {
        guard label.unicodeScalars.allSatisfy(\.isASCII) else { return words.contains { label.contains($0) } }
        return words.contains { label == $0 || label == $0 + "s" || label == $0 + " date" }
    }

    private static func actionCards(header: [String], rows: [[String]]) -> [ActionCard]? {
        let lower = header.map { $0.lowercased() }
        func column(_ labels: [String]) -> Int? {
            lower.indices.dropFirst().first { index in labels.contains { lower[index].contains($0) } }
        }
        let owner = column(ownerLabels)
        let deadline = column(deadlineLabels)
        guard owner != nil || deadline != nil else { return nil }
        return rows.map { cells in
            func cell(_ index: Int?) -> String? {
                guard let index, index < cells.count else { return nil }
                return stated(cells[index])
            }
            var card = ActionCard(task: cells.first ?? "", hasFields: true, owner: cell(owner), deadline: cell(deadline))
            for index in cells.indices.dropFirst() where index != owner && index != deadline {
                for line in cells[index].components(separatedBy: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard stated(trimmed) != nil else { continue }
                    if let marks = SummaryInline.evidenceList(trimmed) { card.evidence += marks }
                    else { card.notes.append(trimmed) }
                }
            }
            return card
        }
    }

    private static func stated(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return ["", "—", "–", "-", "无", "未指定", "未说明", "未提及", "未明确"].contains(trimmed) ? nil : trimmed
    }

    private static let ownerLabels = ["owner", "assignee", "负责人", "负责", "执行人", "责任人", "承担"]
    private static let deadlineLabels = ["deadline", "due", "截止", "期限"]
}
