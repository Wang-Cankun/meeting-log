import Foundation

struct SummaryRevision {
    let meeting: ArchivedMeeting
    let original: String
    let transcriptSnapshot: SummaryEvidence.Snapshot
    let evidenceSource: SummaryEvidence.Source
    let capturePreparation: CapturePreparation?
    let globalContext: String
    let projectContext: String
    let markdown: String
    let model: String
    let endpoint: String
    let draftPrompt: String
    let reviewPrompt: String
    var chineseMarkdown: String = ""
    var originalChinese: String? = nil
    var chinesePrompt: String = ""
}

@MainActor
struct SummaryRegenerator {
    let store: ArchiveStore
    let client: ProviderClient

    func generate(for meeting: ArchivedMeeting) async throws -> SummaryRevision {
        let original = try read(meeting.url.appending(path: "summary.md"))
        let chineseURL = meeting.url.appending(path: "summary_cn.md")
        let originalChinese = FileManager.default.fileExists(atPath: chineseURL.path) ? try read(chineseURL) : nil
        let transcriptSnapshot = try SummaryEvidence.Snapshot.load(in: meeting.url)
        let evidence = try transcriptSnapshot.evidence()
        let capturePreparation = try CapturePreparation.load(in: meeting.url)
        let global = try context(store.root.appending(path: "meeting_context.md"))
        let project = try store.meetingContext(for: meeting.projectName)
        let prompt = Prompts.analysis(evidence: evidence, globalContext: global, projectName: meeting.projectName, projectContext: project)
        let draft = try await client.complete(prompt: prompt)
        _ = try decode(draft)
        try Task.checkCancellation()
        let reviewPrompt = Prompts.review(analysis: draft, evidence: evidence, context: global + "\n" + project)
        var analysis = try decode(await client.complete(prompt: reviewPrompt))
        try Task.checkCancellation()
        analysis = TranscriptEvidence.annotateReferences(analysis, transcript: evidence.text)
        analysis.title = ArchiveStore.meetingTitle(analysis.title)
        analysis.projectName = meeting.projectName
        var markdown = MarkdownRenderer.summary(analysis, startedAt: meeting.date, evidenceSource: evidence.source)
        if let dateLine = original.components(separatedBy: .newlines).first(where: { $0.hasPrefix("- Date: ") }) {
            markdown = markdown.components(separatedBy: .newlines).map { $0.hasPrefix("- Date: ") ? dateLine : $0 }.joined(separator: "\n")
        }
        let chinese = try await TranscriptPolisher.chinese(summary: markdown, context: global + "\n" + project, client: client)
        try Task.checkCancellation()
        return SummaryRevision(meeting: meeting, original: original, transcriptSnapshot: transcriptSnapshot, evidenceSource: evidence.source,
                               capturePreparation: capturePreparation,
                               globalContext: global, projectContext: project,
                               markdown: capturePreparation?.addingNotice(to: markdown) ?? markdown,
                               model: client.model, endpoint: client.baseURL, draftPrompt: prompt, reviewPrompt: reviewPrompt,
                               chineseMarkdown: capturePreparation?.addingNotice(to: chinese.markdown, chinese: true) ?? chinese.markdown,
                               originalChinese: originalChinese,
                               chinesePrompt: TranscriptPolisher.chinesePrompt(summary: markdown, context: global + "\n" + project))
    }

    func save(_ revision: SummaryRevision) throws {
        let directory = revision.meeting.url
        let chineseURL = directory.appending(path: "summary_cn.md")
        let currentChinese = FileManager.default.fileExists(atPath: chineseURL.path) ? try read(chineseURL) : nil
        let currentPreparation: CapturePreparation?
        do { currentPreparation = try CapturePreparation.load(in: directory) }
        catch { throw RevisionError.changed }
        guard try read(directory.appending(path: "summary.md")) == revision.original,
              currentChinese == revision.originalChinese,
              currentPreparation == revision.capturePreparation,
              (try? SummaryEvidence.Snapshot.load(in: directory)) == revision.transcriptSnapshot,
              try context(store.root.appending(path: "meeting_context.md")) == revision.globalContext,
              try store.meetingContext(for: revision.meeting.projectName) == revision.projectContext else {
            throw RevisionError.changed
        }
        let history = directory.appending(path: ".summary-history/\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        // Back up before replacement. A failed write never removes the existing summary.
        try revision.original.write(to: history.appending(path: "previous.md"), atomically: true, encoding: .utf8)
        try revision.markdown.write(to: history.appending(path: "replacement.md"), atomically: true, encoding: .utf8)
        try revision.originalChinese?.write(to: history.appending(path: "previous_cn.md"), atomically: true, encoding: .utf8)
        try revision.chineseMarkdown.write(to: history.appending(path: "replacement_cn.md"), atomically: true, encoding: .utf8)
        let metadata = ["model": revision.model, "endpoint": revision.endpoint, "analysisPrompt": revision.draftPrompt,
                        "evidenceSource": revision.evidenceSource.rawValue,
                        "reviewPrompt": revision.reviewPrompt, "globalContext": revision.globalContext, "projectContext": revision.projectContext,
                        "chinesePrompt": revision.chinesePrompt]
        try JSONEncoder().encode(metadata).write(to: history.appending(path: "provenance.json"), options: .atomic)
        try revision.chineseMarkdown.write(to: chineseURL, atomically: true, encoding: .utf8)
        do {
            try revision.markdown.write(to: directory.appending(path: "summary.md"), atomically: true, encoding: .utf8)
        } catch {
            if let previous = revision.originalChinese {
                try previous.write(to: chineseURL, atomically: true, encoding: .utf8)
            } else { try FileManager.default.removeItem(at: chineseURL) }
            throw error
        }
    }

    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    private func context(_ url: URL) throws -> String {
        FileManager.default.fileExists(atPath: url.path) ? try read(url) : ""
    }
    private func decode(_ text: String) throws -> MeetingAnalysis {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end else { throw ProcessingError.invalidJSON }
        return try JSONDecoder().decode(MeetingAnalysis.self, from: Data(text[start...end].utf8))
    }
}

enum RevisionError: LocalizedError {
    case changed
    var errorDescription: String? {
        switch self {
        case .changed: "The summary, transcript, recording recovery details, or context changed after generation. Discard this preview and generate again to use the latest files."
        }
    }
}
