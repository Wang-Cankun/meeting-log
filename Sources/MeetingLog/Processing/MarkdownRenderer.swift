import Foundation

enum MarkdownRenderer {
    static func transcript(blocks: [TranscriptBlock], parts: [ImportedAudioPart] = []) -> String {
        var output = "# Transcript\n\n"
        if !parts.isEmpty {
            output += "These are separate recordings grouped by the user. File order is playback order, not evidence of continuous conversation. Gaps and real-world chronology are unknown; do not invent missing discussion. Times below refer to the combined audio.\n\n"
        }
        if blocks.contains(where: { $0.track != nil }) {
            output += "Turns labeled Me come from the recording user's microphone. Other speakers come from computer audio; their letters are anonymous within each section.\n\n"
        }
        var offset = 0.0
        var boundaries: [(Double, String)] = []
        for (index, part) in parts.enumerated() {
            let safeName = part.originalName.unicodeScalars.map {
                CharacterSet.controlCharacters.contains($0) ? " " : String($0)
            }.joined()
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "[", with: "\\[")
                .replacingOccurrences(of: "]", with: "\\]")
            boundaries.append((offset, "## Recording \(index + 1): \(safeName)\n\n"))
            offset += part.duration
        }
        var nextPart = 0
        var windows: [[TranscriptBlock]] = []
        for block in blocks {
            if let last = windows.last?.first, last.startSeconds == block.startSeconds, block.track != nil {
                windows[windows.count - 1].append(block)
            } else {
                windows.append([block])
            }
        }
        for window in windows {
            let block = window[0]
            if nextPart < boundaries.count, block.startSeconds >= boundaries[nextPart].0 - 0.01 {
                output += boundaries[nextPart].1
                nextPart += 1
            }
            let heading = parts.isEmpty ? "##" : "###"
            output += "\(heading) \(clock(block.startSeconds))–\(clock(block.endSeconds))\n\n\(merged(window))\n\n"
        }
        return output
    }

    /// Interleaves per-track turns by timestamp. The microphone label is fixed rather than trusted to the model.
    static func merged(_ blocks: [TranscriptBlock]) -> String {
        guard blocks.contains(where: { $0.track != nil }) else {
            return blocks.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
        }
        var turns: [(time: Int, line: String, silent: Bool)] = []
        for block in blocks {
            var time = Int(block.startSeconds)
            for line in block.text.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                let ns = line as NSString
                guard let match = turnPattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
                    turns.append((time, line, false))
                    continue
                }
                time = (Int(ns.substring(with: match.range(at: 1))) ?? 0) * 60 + (Int(ns.substring(with: match.range(at: 2))) ?? 0)
                let speaker = block.track == .microphone ? "Me" : ns.substring(with: match.range(at: 3))
                let text = ns.substring(with: match.range(at: 4))
                turns.append((time, "[\(ns.substring(with: match.range(at: 1))):\(ns.substring(with: match.range(at: 2)))] \(speaker): \(text)",
                              text.trimmingCharacters(in: .whitespaces) == "[no audible speech]"))
            }
        }
        let spoken = turns.filter { !$0.silent }
        let kept = spoken.isEmpty ? Array(turns.prefix(1)) : spoken
        return kept.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
            .map(\.element.line).joined(separator: "\n\n")
    }

    private static let turnPattern = try! NSRegularExpression(pattern: #"^\[(\d{2,}):([0-5]\d)\] ([^:\n]+): (.+)$"#)

    static func summary(_ value: MeetingAnalysis, startedAt: Date, evidenceSource: SummaryEvidence.Source = .legacy) -> String {
        var output = """
        # \(value.title)

        - Date: \(day.string(from: startedAt))
        - Project: \(value.projectName)
        \(evidenceSource.metadata)

        ## Summary

        \(list(value.summary))

        ## Action items

        """
        if value.actionItems.isEmpty {
            output += "None.\n"
        } else {
            output += "| Task | Owner | Deadline | Context / evidence |\n| --- | --- | --- | --- |\n"
            output += value.actionItems.map { item in
                "| " + [item.task, item.assignee, item.deadline,
                    [item.context, TranscriptEvidence.description(item.evidence)].filter { !$0.isEmpty }.joined(separator: "\n")]
                    .map { tableCell($0.isEmpty ? "—" : $0) }.joined(separator: " | ") + " |"
            }.joined(separator: "\n") + "\n"
        }
        output += "\n## Decisions\n\n"
        if value.decisions.isEmpty {
            output += "None.\n"
        } else {
            output += value.decisions.map {
                "- \($0.decision)" + ($0.reasoning.isEmpty ? "" : "\n  \($0.reasoning)")
                    + (($0.evidence ?? []).isEmpty ? "" : "\n  Evidence: \(TranscriptEvidence.description($0.evidence))")
            }.joined(separator: "\n") + "\n"
        }
        for (heading, notes) in [("Milestones", value.milestones), ("Open questions", value.openQuestions), ("Deferred work", value.deferredWork), ("Infrastructure and documents", value.inventory)] {
            guard let notes, !notes.isEmpty else { continue }
            output += "\n## \(heading)\n\n" + notes.map {
                "- \($0.text)\n  Evidence: \(TranscriptEvidence.description($0.evidence))"
            }.joined(separator: "\n") + "\n"
        }
        output += "\n## Key topics\n\n\(list(value.keyTopics))\n"
        if let uncertainties = value.uncertainties, !uncertainties.isEmpty {
            output += "\n## Needs verification\n\n\(list(uncertainties))\n"
        }
        return output
    }

    private static func tableCell(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "|", with: "&#124;")
            .replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
            .replacingOccurrences(of: "\r", with: "<br>")
    }

    private static func list(_ values: [String]) -> String {
        values.isEmpty ? "None." : values.map { "- \($0)" }.joined(separator: "\n")
    }

    private static func clock(_ seconds: Double) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    private static let day: DateFormatter = {
        let value = DateFormatter()
        value.locale = Locale(identifier: "en_US_POSIX")
        value.dateFormat = "yyyy-MM-dd HH:mm"
        return value
    }()
}
