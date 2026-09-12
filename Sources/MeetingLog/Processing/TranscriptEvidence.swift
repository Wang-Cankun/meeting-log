import Foundation

enum TranscriptEvidence {
    static func annotated(_ transcript: String) -> String {
        var chunk = 0
        return transcript.components(separatedBy: .newlines).enumerated().map { index, line in
            if line.hasPrefix("## ") || line.hasPrefix("### ") {
                chunk += 1
                return "L\(index + 1): \(line) [scope \(chunk): anonymous speaker labels apply only inside this section]"
            }
            return "L\(index + 1): \(line)"
        }.joined(separator: "\n")
    }

    /// Reference quality is advisory: model paraphrases must not block a usable summary.
    static func annotateReferences(_ original: MeetingAnalysis, transcript: String) -> MeetingAnalysis {
        var analysis = original
        let lines = transcript.components(separatedBy: .newlines)
        var hasUnverified = false
        func checked(_ references: [EvidenceReference]?) -> [EvidenceReference]? {
            guard let references, !references.isEmpty else {
                hasUnverified = true
                return references
            }
            return references.map { reference in
                var result = reference
                let quote = reference.quote.trimmingCharacters(in: .whitespacesAndNewlines)
                result.verified = reference.line > 0 && reference.line <= lines.count && !quote.isEmpty
                    && lines[reference.line - 1].contains(quote)
                if result.verified != true { hasUnverified = true }
                return result
            }
        }
        for index in analysis.actionItems.indices {
            analysis.actionItems[index].evidence = checked(analysis.actionItems[index].evidence)
        }
        for index in analysis.decisions.indices {
            analysis.decisions[index].evidence = checked(analysis.decisions[index].evidence)
        }
        func notes(_ values: [EvidenceNote]?) -> [EvidenceNote]? {
            values?.map { EvidenceNote(text: $0.text, evidence: checked($0.evidence)) }
        }
        analysis.milestones = notes(analysis.milestones)
        analysis.openQuestions = notes(analysis.openQuestions)
        analysis.deferredWork = notes(analysis.deferredWork)
        analysis.inventory = notes(analysis.inventory)
        if hasUnverified {
            let note = "Some source references are approximate or missing. Check the transcript when exact wording or attribution matters."
            if !(analysis.uncertainties ?? []).contains(note) {
                analysis.uncertainties = (analysis.uncertainties ?? []) + [note]
            }
        }
        return analysis
    }

    static func description(_ references: [EvidenceReference]?) -> String {
        (references ?? []).map {
            let status = $0.verified == false ? " [unverified reference]" : ""
            return "L\($0.line)\(status): “\($0.quote)”"
        }.joined(separator: "; ")
    }
}
