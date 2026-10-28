import Foundation

enum MarkdownRenderer {
    static func transcript(blocks: [TranscriptBlock], parts: [ImportedAudioPart] = []) -> String {
        let online = isOnline(blocks)
        var output = "# Transcript\n\n"
        if !parts.isEmpty {
            output += "These are separate recordings grouped by the user. File order is playback order, not evidence of continuous conversation. Gaps and real-world chronology are unknown; do not invent missing discussion. Times below refer to the combined audio.\n\n"
        }
        if blocks.contains(where: { $0.track != nil }) {
            output += online
                ? "Turns labeled \(TranscriptTurn.recordingUser) come from the recording user's microphone. Other speakers come from computer audio; their letters are anonymous within each section.\n\n"
                : "Speakers below were recorded by the microphone; their letters are anonymous within each section. Turns labeled Computer come from computer audio.\n\n"
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
        let covering = Set(blocks.indices.filter { blockIndex in
            let block = blocks[blockIndex]
            guard let track = block.track else { return false }
            return blocks.filter {
                $0.track != nil && $0.track != track && $0.startSeconds >= block.startSeconds && $0.endSeconds <= block.endSeconds
            }.count > 1
        })
        var windows: [(indices: [Int], blocks: [TranscriptBlock])] = []
        for index in blocks.indices where !covering.contains(index) {
            let block = blocks[index]
            if let last = windows.last?.indices.first, blocks[last].startSeconds == block.startSeconds,
               blocks[last].track != nil, block.track != nil {
                windows[windows.count - 1].indices.append(index)
            } else {
                windows.append(([index], []))
            }
        }
        for (index, block) in blocks.enumerated() {
            if let window = windows.firstIndex(where: { $0.indices.contains(index) }) {
                windows[window].blocks.append(block)
                continue
            }
            let targets = windows.indices.filter { windowIndex in
                let finer = blocks[windows[windowIndex].indices[0]]
                return finer.track != nil && finer.track != block.track
                    && finer.startSeconds >= block.startSeconds && finer.endSeconds <= block.endSeconds
            }
            var turnsByWindow: [Int: [TranscriptTurn]] = [:]
            for turn in block.resolvedTurns {
                if let target = targets.last(where: { turn.startMilliseconds >= Int(blocks[windows[$0].indices[0]].startSeconds * 1000) }) {
                    turnsByWindow[target, default: []].append(turn)
                }
            }
            for target in targets {
                var portion = block
                portion.turns = turnsByWindow[target] ?? []
                windows[target].blocks.append(portion)
            }
        }
        for window in windows {
            let block = blocks[window.indices[0]]
            if nextPart < boundaries.count, block.startSeconds >= boundaries[nextPart].0 - 0.01 {
                output += boundaries[nextPart].1
                nextPart += 1
            }
            let heading = parts.isEmpty ? "##" : "###"
            output += "\(heading) \(clock(block.startSeconds))–\(clock(block.endSeconds))\n\n\(merged(window.blocks, online: online))\n\n"
        }
        return output
    }

    /// Microphone voices are anonymous unless computer speech establishes an online session.
    static func merged(_ blocks: [TranscriptBlock]) -> String {
        merged(blocks, online: isOnline(blocks))
    }

    private static func merged(_ blocks: [TranscriptBlock], online: Bool) -> String {
        let systemTurns = online ? blocks.filter { $0.track == .system }.flatMap(\.resolvedTurns) : []
        let turns = blocks.flatMap { block in
            block.resolvedTurns.compactMap { turn -> TranscriptTurn? in
                if online, block.track == .microphone, isEcho(turn, systemTurns: systemTurns) { return nil }
                var turn = turn
                turn.speaker = simplifiedChinese(turn.speaker)
                turn.text = simplifiedChinese(turn.text)
                if block.track != nil, turn.text.trimmingCharacters(in: .whitespaces) == TranscriptTurn.silence {
                    turn.speaker = "Speaker"
                } else if block.track == .microphone, online {
                    turn.speaker = TranscriptTurn.recordingUser
                } else if block.track == .system, !online {
                    turn.speaker = "Computer"
                }
                return turn
            }
        }
        guard blocks.contains(where: { $0.track != nil }) else {
            return turns.map(\.line).joined(separator: "\n\n")
        }
        let spoken = turns.filter { $0.text.trimmingCharacters(in: .whitespaces) != TranscriptTurn.silence }
        let kept = spoken.isEmpty ? Array(turns.prefix(1)) : spoken
        return kept.enumerated().sorted { ($0.element.startMilliseconds, $0.offset) < ($1.element.startMilliseconds, $1.offset) }
            .map(\.element.line).joined(separator: "\n\n")
    }

    private static func isEcho(_ microphone: TranscriptTurn, systemTurns: [TranscriptTurn]) -> Bool {
        guard let duration = microphone.durationMilliseconds else { return false }
        let text = normalizedEchoText(microphone.text)
        guard text.count >= 8 else { return false }
        let end = microphone.startMilliseconds + duration
        // A turn that starts after a computer turn ends is a reply to it, even within the trailing allowance.
        // Speech split at pauses can divide one echoed passage between neighbouring computer turns.
        let playing = systemTurns.filter { system in
            guard let systemDuration = system.durationMilliseconds else { return false }
            return microphone.startMilliseconds < system.startMilliseconds + systemDuration && end > system.startMilliseconds
        }
        guard let first = playing.first, let last = playing.last, let lastDuration = last.durationMilliseconds else { return false }
        let overlap = min(end, last.startMilliseconds + lastDuration + 500) - max(microphone.startMilliseconds, first.startMilliseconds)
        return Double(overlap) >= Double(duration) / 2 && playing.map { normalizedEchoText($0.text) }.joined().contains(text)
    }

    private static func normalizedEchoText(_ text: String) -> String {
        simplifiedChinese(text).lowercased()
            .components(separatedBy: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)).joined()
    }

    private static func isOnline(_ blocks: [TranscriptBlock]) -> Bool {
        var systemCharacters = 0
        var speechCharacters = 0
        for block in blocks {
            for turn in block.resolvedTurns where turn.text.trimmingCharacters(in: .whitespaces) != TranscriptTurn.silence {
                let count = simplifiedChinese(turn.text).count
                speechCharacters += count
                if block.track == .system { systemCharacters += count }
            }
        }
        return systemCharacters >= 100 || (speechCharacters > 0 && Double(systemCharacters) / Double(speechCharacters) >= 0.05)
    }

    /// Models sometimes write Chinese speech in Traditional characters. Converting script is deterministic
    /// and leaves other languages untouched; it runs before the transcript becomes summary evidence.
    static func simplifiedChinese(_ text: String) -> String {
        text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
    }

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
        output += "\n"
        if value.actionItems.isEmpty {
            output += "None.\n"
        } else {
            // A list, like the other sections, copies cleanly into chat and notes; tables do not.
            output += value.actionItems.map { item in
                "- \(oneLine(item.task))\n  Owner: \(oneLine(item.assignee).isEmpty ? "—" : oneLine(item.assignee))"
                    + " · Deadline: \(oneLine(item.deadline).isEmpty ? "—" : oneLine(item.deadline))"
                    + (item.context.isEmpty ? "" : "\n  \(oneLine(item.context))")
                    + ((item.evidence ?? []).isEmpty ? "" : "\n  Evidence: \(TranscriptEvidence.description(item.evidence))")
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

    private static func oneLine(_ value: String) -> String {
        value.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
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
