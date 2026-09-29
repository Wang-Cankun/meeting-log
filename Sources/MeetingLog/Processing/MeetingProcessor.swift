import Foundation

@MainActor
struct MeetingProcessor {
    let store: ArchiveStore
    let client: ProviderClient
    /// When set, a speech service transcribes audio and the provider handles only text steps.
    var speech: SpeechTranscriber? = nil
    var progress: @Sendable (ProcessingProgress) -> Void = { _ in }

    func process(directory: URL, manifest original: SessionManifest, projectName: String?) async throws -> URL {
        var manifest = original
        manifest.status = .processing
        manifest.lastError = nil
        try store.write(manifest, to: directory)

        do {
            let capturePreparation = try CapturePreparation.load(in: directory)
            if let capturePreparation, capturePreparation.state != .ready {
                throw ProcessingError.captureNotReady
            }
            let context = try store.globalContext()
            let resolvedProjectName = try store.resolveProject(projectName).name
            let projectContext = try store.meetingContext(for: resolvedProjectName)

            let transcriptionContext = "More-specific meeting context overrides general preferences; context is not evidence of spoken commitments.\nGlobal context:\n\(context)\n\nProject: \(resolvedProjectName)\nProject context:\n\(projectContext)"
            progress(.init(stage: .prepare, detail: "Preparing audio"))
            var blocks: [TranscriptBlock]
            if let speech {
                blocks = try await transcribeWithSpeech(speech, directory: directory, preparation: capturePreparation,
                                                        context: projectContext + "\n" + context)
            } else {
                let prepared: (audio: URL, chunks: [AudioChunk])
                switch MediaProcessor.pendingInput(in: directory) {
                case let .combined(capture):
                    if let tracks = try separateTracks(in: directory, capture: capture, preparation: capturePreparation) {
                        prepared = try await MediaProcessor().prepareTrackAudio(from: capture, tracks: tracks, in: directory)
                    } else {
                        prepared = try await MediaProcessor().prepareAudio(from: capture, in: directory)
                    }
                case let .importedParts(parts):
                    prepared = try await MediaProcessor().prepareImportedAudio(parts: parts, in: directory)
                default:
                    throw MediaError.emptyRecording
                }
                blocks = try loadBlocks(in: directory) ?? prepared.chunks.enumerated().map {
                    TranscriptBlock(id: $0.offset, startSeconds: $0.element.startSeconds, endSeconds: $0.element.endSeconds, track: $0.element.track)
                }

                guard blocks.count == prepared.chunks.count,
                      zip(blocks, prepared.chunks).allSatisfy({ $0.track == $1.track }) else { throw ProcessingError.incompleteCoverage }
                let client = client
                let chunks = prepared.chunks
                blocks = try await TranscriptionBatch.run(blocks: blocks) { index in
                    let chunk = chunks[index]
                    let prompt = Prompts.transcription(context: transcriptionContext, start: chunk.startSeconds, end: chunk.endSeconds, track: chunk.track)
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
                    progress(.init(stage: .transcribe(completed: completed, total: total),
                                   detail: "Transcribing \(completed) of \(total) blocks · up to \(TranscriptionBatch.concurrencyLimit) at once"))
                }
            }
            guard blocks.allSatisfy({ $0.status == .complete && !$0.text.isEmpty }) else {
                throw ProcessingError.incompleteCoverage
            }

            let rawTranscript = MarkdownRenderer.transcript(blocks: blocks, parts: manifest.importedParts ?? [])
            let evidence = try SummaryEvidence(text: rawTranscript, source: .raw)
            try rawTranscript.write(to: directory.appending(path: "transcript_raw.md"), atomically: true, encoding: .utf8)
            progress(.init(stage: .clean, detail: "Cleaning transcript across excerpts"))
            // Speech-service output is already clean-style; local rules keep its words and speaker labels intact.
            let transcript = speech == nil
                ? try await TranscriptPolisher.clean(raw: rawTranscript, context: transcriptionContext, client: client)
                : TranscriptPolisher.tidy(rawTranscript)
            try transcript.write(to: directory.appending(path: "transcript.md"), atomically: true, encoding: .utf8)

            progress(.init(stage: .summary, detail: "Writing summary"))
            let analysisPrompt = Prompts.analysis(
                    evidence: evidence,
                    globalContext: context,
                    projectName: resolvedProjectName,
                    projectContext: projectContext
                )
            let analysisText = try await client.complete(prompt: analysisPrompt)
            // Validate the draft schema before spending a second request on evidence review.
            _ = try decode(MeetingAnalysis.self, from: analysisText)
            progress(.init(stage: .evidence, detail: "Checking summary evidence"))
            let reviewPrompt = Prompts.review(analysis: analysisText, evidence: evidence, context: transcriptionContext)
            let reviewedText = try await client.complete(prompt: reviewPrompt)
            var analysis = try decode(MeetingAnalysis.self, from: reviewedText)
            analysis = TranscriptEvidence.annotateReferences(analysis, transcript: evidence.text)
            analysis.title = ArchiveStore.meetingTitle(analysis.title)
            analysis.projectName = resolvedProjectName

            try transcript.write(to: directory.appending(path: "transcript.md"), atomically: true, encoding: .utf8)
            progress(.init(stage: .chinese, detail: "Writing Simplified Chinese summary"))
            let summary = MarkdownRenderer.summary(analysis, startedAt: manifest.startedAt, evidenceSource: evidence.source)
            let chinese = try await TranscriptPolisher.chinese(summary: summary, context: transcriptionContext, client: client)
            try (capturePreparation?.addingNotice(to: summary) ?? summary)
                .write(to: directory.appending(path: "summary.md"), atomically: true, encoding: .utf8)
            try (capturePreparation?.addingNotice(to: chinese.markdown, chinese: true) ?? chinese.markdown)
                .write(to: directory.appending(path: "summary_cn.md"), atomically: true, encoding: .utf8)

            let provenance = ["model": client.model, "endpoint": client.baseURL,
                              "transcription": speech.map { "\(SpeechTranscriber.model) via \($0.endpoint)" } ?? client.model,
                              "evidenceSource": evidence.source.rawValue,
                              "analysisPrompt": analysisPrompt, "reviewPrompt": reviewPrompt,
                              "cleanupPrompt": speech == nil ? TranscriptPolisher.prompt(raw: rawTranscript, context: transcriptionContext) : "local rules",
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
            if capturePreparation?.retainsRawTracks != true {
                try? FileManager.default.removeItem(at: destination.appending(path: "system-audio.caf"))
                try? FileManager.default.removeItem(at: destination.appending(path: "microphone.m4a"))
            }
            progress(.init(stage: .complete, detail: "Complete"))
            return destination
        } catch {
            manifest.status = .failed
            manifest.lastError = error.localizedDescription
            try? store.write(manifest, to: directory)
            throw error
        }
    }

    /// Transcribes microphone and computer audio separately when both raw tracks reached the capture mix.
    /// Sessions whose saved coverage predates per-track blocks keep their mixed transcription.
    private func separateTracks(in directory: URL, capture: URL, preparation: CapturePreparation?) throws -> [(TranscriptTrack, URL)]? {
        let system = directory.appending(path: "system-audio.caf")
        let microphone = directory.appending(path: "microphone.m4a")
        let fm = FileManager.default
        guard capture.lastPathComponent == "capture.mov", preparation?.mode == .complete,
              fm.fileExists(atPath: system.path), fm.fileExists(atPath: microphone.path) else { return nil }
        if let saved = try loadBlocks(in: directory), !saved.isEmpty, saved.allSatisfy({ $0.track == nil }) { return nil }
        return [(.system, system), (.microphone, microphone)]
    }

    /// One diarized request per recording, imported file, or capture track keeps speaker letters stable for the
    /// whole section. A long section that still fails is retried as overlapping ten-minute windows, whose letters
    /// are then scoped per window, as with chat transcription.
    private func transcribeWithSpeech(_ speech: SpeechTranscriber, directory: URL, preparation: CapturePreparation?,
                                      context: String) async throws -> [TranscriptBlock] {
        let media = MediaProcessor()
        let audio: URL
        var plan: [TranscriptBlock] = []
        switch MediaProcessor.pendingInput(in: directory) {
        case let .combined(capture):
            let playback = try await media.playbackAudio(from: capture, in: directory)
            audio = playback.audio
            let separated = try separateTracks(in: directory, capture: capture, preparation: preparation)
            let tracks: [TranscriptTrack?] = separated?.map(\.0) ?? [nil]
            plan = tracks.enumerated().map { TranscriptBlock(id: $0.offset, startSeconds: 0, endSeconds: playback.duration, track: $0.element) }
        case let .importedParts(parts):
            audio = try await media.joinImportedAudio(parts: parts, in: directory)
            var offset = 0.0
            for (index, part) in parts.enumerated() {
                plan.append(TranscriptBlock(id: index, startSeconds: offset, endSeconds: offset + part.duration))
                offset += part.duration
            }
        default:
            throw MediaError.emptyRecording
        }
        let sources: [TranscriptTrack?: URL] = [
            nil: audio,
            .system: directory.appending(path: "system-audio.caf"),
            .microphone: directory.appending(path: "microphone.m4a"),
        ]
        let uploads = directory.appending(path: "chunks", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true)
        let phrases = SpeechTranscriber.phrases(fromContext: context)

        func run(_ blocks: [TranscriptBlock]) async throws -> [TranscriptBlock] {
            try await TranscriptionBatch.run(blocks: blocks, limit: SpeechTranscriber.concurrencyLimit) { index in
                let block = blocks[index]
                guard let source = sources[block.track] else { throw MediaError.emptyRecording }
                let upload = uploads.appending(path: "speech-\(index).flac")
                defer { try? FileManager.default.removeItem(at: upload) }
                let range = (start: block.startSeconds, end: block.endSeconds)
                try await Task.detached { try MediaProcessor.encodeFLAC(source: source, destination: upload, range: range) }.value
                let result = try await speech.transcribe(audio: upload, diarize: block.track != .microphone, phrases: phrases)
                return try SpeechTranscriber.transcript(result, start: block.startSeconds, end: block.endSeconds, track: block.track)
            } checkpoint: { updated in
                try saveBlocks(updated, in: directory)
            } progress: { completed, total in
                progress(.init(stage: .transcribe(completed: completed, total: total),
                               detail: "Transcribing with \(SpeechTranscriber.model) · \(completed) of \(total)"))
            }
        }

        let initial = try loadBlocks(in: directory) ?? plan
        do {
            return try await run(initial)
        } catch {
            if error is CancellationError { throw error }
            if case ProviderError.authentication = error { throw error }
            if case ProviderError.configuration = error { throw error }
            let saved = try loadBlocks(in: directory) ?? initial
            var split: [TranscriptBlock] = []
            for block in saved {
                guard block.status != .complete, block.endSeconds - block.startSeconds > 900 else { split.append(block); continue }
                split += MediaProcessor.windows(from: block.startSeconds, to: block.endSeconds).map {
                    TranscriptBlock(id: 0, startSeconds: $0.start, endSeconds: $0.end, track: block.track)
                }
            }
            guard split.count > saved.count else { throw error }
            split = split.enumerated()
                .sorted { ($0.element.startSeconds, $0.element.track == .microphone ? 1 : 0, $0.offset)
                    < ($1.element.startSeconds, $1.element.track == .microphone ? 1 : 0, $1.offset) }
                .enumerated().map { index, entry in
                    var block = TranscriptBlock(id: index, startSeconds: entry.element.startSeconds,
                                                endSeconds: entry.element.endSeconds, track: entry.element.track)
                    block.status = entry.element.status
                    block.text = entry.element.text
                    return block
                }
            try saveBlocks(split, in: directory)
            return try await run(split)
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
    case captureNotReady

    var errorDescription: String? {
        switch self {
        case .incompleteCoverage: "Not every audio block was transcribed."
        case .invalidJSON: "The summary model did not return JSON."
        case .captureNotReady: "Audio recovery is incomplete. Retry this recording before processing it."
        }
    }
}
