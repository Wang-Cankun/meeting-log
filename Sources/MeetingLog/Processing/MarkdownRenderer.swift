import Foundation

enum MarkdownRenderer {
    static func transcript(blocks: [TranscriptBlock]) -> String {
        "# Transcript\n\n" + blocks.map {
            "## \(clock($0.startSeconds))–\(clock($0.endSeconds))\n\n\($0.text.trimmingCharacters(in: .whitespacesAndNewlines))"
        }.joined(separator: "\n\n") + "\n"
    }

    static func summary(_ value: MeetingAnalysis, startedAt: Date) -> String {
        var output = """
        # \(value.title)

        - Date: \(day.string(from: startedAt))
        - Project: \(value.projectName)

        ## Summary

        \(list(value.summary))

        ## Action items

        """
        if value.actionItems.isEmpty {
            output += "None.\n"
        } else {
            output += value.actionItems.map { item in
                let details = [item.assignee, item.deadline, item.context].filter { !$0.isEmpty }
                return "- \(item.task)" + (details.isEmpty ? "" : " (\(details.joined(separator: "; ")))" )
            }.joined(separator: "\n") + "\n"
        }
        output += "\n## Decisions\n\n"
        if value.decisions.isEmpty {
            output += "None.\n"
        } else {
            output += value.decisions.map {
                "- \($0.decision)" + ($0.reasoning.isEmpty ? "" : ": \($0.reasoning)")
            }.joined(separator: "\n") + "\n"
        }
        output += "\n## Key topics\n\n\(list(value.keyTopics))\n"
        return output
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
