import Foundation

@MainActor
struct MeetingProcessor {
    let store: ArchiveStore
    let client: OpenRouterClient
    var progress: @Sendable (String) -> Void = { _ in }

    func process(directory: URL, manifest original: SessionManifest) async throws -> URL {
        var manifest = original
        manifest.status = .processing
        manifest.lastError = nil
        try store.write(manifest, to: directory)

        do {
            progress("Preparing audio")
            let capture = directory.appending(path: "capture.mov")
            let prepared = try await MediaProcessor().prepareAudio(from: capture, in: directory)
            var blocks = try loadBlocks(in: directory) ?? prepared.chunks.enumerated().map {
                TranscriptBlock(id: $0.offset, startSeconds: $0.element.startSeconds, endSeconds: $0.element.endSeconds)
            }

            let context = try store.globalContext()
            for index in blocks.indices where blocks[index].status != .complete {
                progress("Transcribing block \(index + 1) of \(blocks.count)")
                let chunk = prepared.chunks[index]
                do {
                    blocks[index].text = try await retry {
                        try await client.transcribe(
                            audio: chunk.url,
                            prompt: Prompts.transcription(context: context, start: chunk.startSeconds, end: chunk.endSeconds)
                        )
                    }
                    blocks[index].status = .complete
                    blocks[index].error = nil
                } catch {
                    blocks[index].status = .failed
                    blocks[index].error = error.localizedDescription
                    try saveBlocks(blocks, in: directory)
                    throw error
                }
                try saveBlocks(blocks, in: directory)
            }
            guard blocks.allSatisfy({ $0.status == .complete && !$0.text.isEmpty }) else {
                throw ProcessingError.incompleteCoverage
            }

            let transcript = MarkdownRenderer.transcript(blocks: blocks)
            let projects = try store.projectContexts()
            progress("Inferring project")
            let choiceText = try await retry {
                try await client.complete(prompt: Prompts.projectInference(
                    transcript: transcript,
                    globalContext: context,
                    projectContexts: projects
                ))
            }
            var choice = try decode(ProjectChoice.self, from: choiceText)
            choice.projectSlug = ArchiveStore.slug(choice.projectSlug.isEmpty ? choice.projectName : choice.projectSlug)
            if choice.projectName.isEmpty { choice.projectName = choice.projectSlug }
            if choice.title.isEmpty { choice.title = "Meeting" }
            let projectContext = projects.first { $0.slug == choice.projectSlug }?.markdown ?? ""

            progress("Writing summary")
            let analysisText = try await retry {
                try await client.complete(prompt: Prompts.analysis(
                    transcript: transcript,
                    globalContext: context,
                    project: choice,
                    projectContext: projectContext
                ))
            }
            var analysis = try decode(MeetingAnalysis.self, from: analysisText)
            analysis.title = choice.title
            analysis.projectName = choice.projectName
            analysis.projectSlug = choice.projectSlug

            try transcript.write(to: directory.appending(path: "transcript.md"), atomically: true, encoding: .utf8)
            try MarkdownRenderer.summary(analysis, startedAt: manifest.startedAt)
                .write(to: directory.appending(path: "summary.md"), atomically: true, encoding: .utf8)

            let screen = directory.appending(path: "screen.mov")
            if manifest.videoEnabled, !FileManager.default.fileExists(atPath: screen.path) {
                try FileManager.default.moveItem(at: capture, to: screen)
            } else {
                try FileManager.default.removeItem(at: capture)
            }
            try? FileManager.default.removeItem(at: directory.appending(path: "chunks"))
            try? FileManager.default.removeItem(at: directory.appending(path: "coverage.json"))
            try? FileManager.default.removeItem(at: directory.appending(path: "session.json"))
            try? FileManager.default.removeItem(at: directory.appending(path: "system-audio.caf"))
            try? FileManager.default.removeItem(at: directory.appending(path: "microphone.m4a"))

            let destination = try store.finalDirectory(for: analysis, startedAt: manifest.startedAt)
            try store.moveCompletedSession(from: directory, to: destination)
            progress("Complete")
            return destination
        } catch {
            manifest.status = .failed
            manifest.lastError = error.localizedDescription
            try? store.write(manifest, to: directory)
            throw error
        }
    }

    private func retry<T>(_ operation: () async throws -> T) async throws -> T {
        var lastError: Error?
        for _ in 0..<3 {
            do { return try await operation() } catch { lastError = error }
        }
        throw lastError ?? ProcessingError.incompleteCoverage
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
