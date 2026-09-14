import Foundation

@MainActor
struct MeetingProcessor {
    let store: ArchiveStore
    let client: ProviderClient
    var progress: @Sendable (String) -> Void = { _ in }

    func process(directory: URL, manifest original: SessionManifest, projectName: String?) async throws -> URL {
        var manifest = original
        manifest.status = .processing
        manifest.lastError = nil
        try store.write(manifest, to: directory)

        do {
            progress("Preparing audio")
            let prepared: (audio: URL, chunks: [AudioChunk])
            switch MediaProcessor.pendingInput(in: directory) {
            case let .combined(capture):
                prepared = try await MediaProcessor().prepareAudio(from: capture, in: directory)
            case let .importedParts(parts):
                prepared = try await MediaProcessor().prepareImportedAudio(parts: parts, in: directory)
            default:
                throw MediaError.emptyRecording
            }
            var blocks = try loadBlocks(in: directory) ?? prepared.chunks.enumerated().map {
                TranscriptBlock(id: $0.offset, startSeconds: $0.element.startSeconds, endSeconds: $0.element.endSeconds)
            }

            guard blocks.count == prepared.chunks.count else { throw ProcessingError.incompleteCoverage }
            let context = try store.globalContext()
            let resolvedProjectName = try store.resolveProject(projectName).name
            let projectContext = try store.meetingContext(for: resolvedProjectName)

            let transcriptionContext = "More-specific meeting context overrides general preferences; context is not evidence of spoken commitments.\nGlobal context:\n\(context)\n\nProject: \(resolvedProjectName)\nProject context:\n\(projectContext)"
            let client = client
            let chunks = prepared.chunks
            blocks = try await TranscriptionBatch.run(blocks: blocks) { index in
                let chunk = chunks[index]
                let prompt = Prompts.transcription(context: transcriptionContext, start: chunk.startSeconds, end: chunk.endSeconds)
                for attempt in 0..<2 {
                    let feedback = attempt == 0 ? "" : "\nYour previous response failed format/timestamp validation. Re-transcribe the audio using the exact output contract; the last timestamp must be strictly before the excerpt end."
                    let response = try await client.transcribe(audio: chunk.url, prompt: prompt + feedback)
                    do {
                        return try TranscriptResponse.validate(response, start: chunk.startSeconds, end: chunk.endSeconds)
                    } catch {
                        if attempt == 1 { throw error }
                    }
                }
                throw TranscriptResponse.ValidationError()
            } checkpoint: { updated in
                try saveBlocks(updated, in: directory)
            } progress: { completed, total in
                progress("Transcribing \(completed) of \(total) blocks · up to 3 at once")
            }
            guard blocks.allSatisfy({ $0.status == .complete && !$0.text.isEmpty }) else {
                throw ProcessingError.incompleteCoverage
            }

            let rawTranscript = MarkdownRenderer.transcript(blocks: blocks, parts: manifest.importedParts ?? [])
            try rawTranscript.write(to: directory.appending(path: "transcript_raw.md"), atomically: true, encoding: .utf8)
            progress("Cleaning transcript across excerpts")
            let transcript = try await TranscriptPolisher.clean(raw: rawTranscript, context: transcriptionContext, client: client)
            try transcript.write(to: directory.appending(path: "transcript.md"), atomically: true, encoding: .utf8)

            progress("Writing summary")
            let analysisPrompt = Prompts.analysis(
                    transcript: transcript,
                    globalContext: context,
                    projectName: resolvedProjectName,
                    projectContext: projectContext
                )
            let analysisText = try await client.complete(prompt: analysisPrompt)
            // Validate the draft schema before spending a second request on evidence review.
            _ = try decode(MeetingAnalysis.self, from: analysisText)
            progress("Checking summary evidence")
            let reviewPrompt = Prompts.review(analysis: analysisText, transcript: transcript, context: transcriptionContext)
            let reviewedText = try await client.complete(prompt: reviewPrompt)
            var analysis = try decode(MeetingAnalysis.self, from: reviewedText)
            analysis = TranscriptEvidence.annotateReferences(analysis, transcript: transcript)
            analysis.title = ArchiveStore.meetingTitle(analysis.title)
            analysis.projectName = resolvedProjectName

            try transcript.write(to: directory.appending(path: "transcript.md"), atomically: true, encoding: .utf8)
            try MarkdownRenderer.summary(analysis, startedAt: manifest.startedAt)
                .write(to: directory.appending(path: "summary.md"), atomically: true, encoding: .utf8)
            progress("Writing Simplified Chinese summary")
            let summary = MarkdownRenderer.summary(analysis, startedAt: manifest.startedAt)
            let chinese = try await TranscriptPolisher.chinese(summary: summary, context: transcriptionContext, client: client)
            try chinese.markdown.write(to: directory.appending(path: "summary_cn.md"), atomically: true, encoding: .utf8)

            let provenance = ["model": client.model, "endpoint": client.baseURL,
                              "analysisPrompt": analysisPrompt, "reviewPrompt": reviewPrompt,
                              "cleanupPrompt": TranscriptPolisher.prompt(raw: rawTranscript, context: transcriptionContext),
                              "chinesePrompt": TranscriptPolisher.chinesePrompt(summary: summary, context: transcriptionContext)]
            try JSONEncoder().encode(provenance).write(to: directory.appending(path: "summary-provenance.json"), options: .atomic)

            let destination = try store.finalDirectory(
                projectName: analysis.projectName,
                title: chinese.folderTitle,
                startedAt: manifest.startedAt
            )
            try store.moveCompletedSession(from: directory, to: destination)
            // The compressed audio and both Markdown outputs are now safely archived.
            // Source files outside the app archive are never touched.
            for ext in AudioImport.supportedExtensions {
                try? FileManager.default.removeItem(at: destination.appending(path: "original.\(ext)"))
            }
            try? FileManager.default.removeItem(at: destination.appending(path: "originals"))
            let archivedCapture = destination.appending(path: "capture.mov")
            let screen = destination.appending(path: "screen.mov")
            if manifest.videoEnabled, !FileManager.default.fileExists(atPath: screen.path) {
                try? FileManager.default.moveItem(at: archivedCapture, to: screen)
            } else {
                try? FileManager.default.removeItem(at: archivedCapture)
            }
            try? FileManager.default.removeItem(at: destination.appending(path: "chunks"))
            try? FileManager.default.removeItem(at: destination.appending(path: "parts"))
            try? FileManager.default.removeItem(at: destination.appending(path: "coverage.json"))
            try? FileManager.default.removeItem(at: destination.appending(path: "session.json"))
            try? FileManager.default.removeItem(at: destination.appending(path: "system-audio.caf"))
            try? FileManager.default.removeItem(at: destination.appending(path: "microphone.m4a"))
            progress("Complete")
            return destination
        } catch {
            manifest.status = .failed
            manifest.lastError = error.localizedDescription
            try? store.write(manifest, to: directory)
            throw error
        }
    }

    private func saveBlocks(_ blocks: [TranscriptBlock], in directory: URL) throws {
        try JSONEncoder().encode(blocks).write(to: directory.appending(path: "coverage.json"), options: .atomic)
    }

    private func loadBlocks(in directory: URL) throws -> [TranscriptBlock]? {
        let url = directory.appending(path: "coverage.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode([TranscriptBlock].self, from: Data(contentsOf: url))
    }

    private func decode<T: Decodable>(_ type: T.Type, from response: String) throws -> T {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let json: String
        if let first = trimmed.firstIndex(of: "{"), let last = trimmed.lastIndex(of: "}") {
            json = String(trimmed[first...last])
        } else {
            throw ProcessingError.invalidJSON
        }
        return try JSONDecoder().decode(type, from: Data(json.utf8))
    }
}

enum ProcessingError: LocalizedError {
    case incompleteCoverage
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .incompleteCoverage: "Not every audio block was transcribed."
        case .invalidJSON: "The summary model did not return JSON."
        }
    }
}
