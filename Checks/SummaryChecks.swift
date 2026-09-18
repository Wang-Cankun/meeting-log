import Foundation
import AVFoundation

@MainActor
func checkSummaryRegeneration() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "summary-check-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ArchiveStore(root: root)
    let project = try store.createProject(named: "项目")
    try "GLOBAL_REGEN".write(to: root.appending(path: "meeting_context.md"), atomically: true, encoding: .utf8)
    try "PROJECT_REGEN".write(to: project.url.appending(path: "meeting_context.md"), atomically: true, encoding: .utf8)
    let directory = project.url.appending(path: "meetings/09102026Original")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let original = "# Custom title\n\n- Date: 2026-09-10 12:49\n- Project: Inbox\n\nOld handwritten summary.\n"
    let transcript = "TRANSCRIPT_REGEN"
    try original.write(to: directory.appending(path: "summary.md"), atomically: true, encoding: .utf8)
    try transcript.write(to: directory.appending(path: "transcript.md"), atomically: true, encoding: .utf8)
    try Data([1, 2, 3]).write(to: directory.appending(path: "audio.m4a"))
    let meeting = ArchivedMeeting(title: "Original", projectName: project.name, dateText: "09102026", date: Date(), createdAt: Date(), url: directory)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SummaryFixture.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let generator = SummaryRegenerator(store: store, client: ProviderClient(baseURL: "https://summary.invalid", apiKey: "secret-fixture", model: "fixture-model", session: session))
    let revision = try await generator.generate(for: meeting)
    precondition(tryText(directory.appending(path: "summary.md")) == original, "Preview must not overwrite")
    precondition(!FileManager.default.fileExists(atPath: directory.appending(path: ".summary-history").path))
    precondition(revision.markdown.contains("# Changed title\n"))
    precondition(revision.markdown.contains("- Date: 2026-09-10 12:49"))
    precondition(revision.markdown.contains("- Project: 项目"))
    precondition(revision.markdown.contains("Needs verification"))
    precondition(revision.chineseMarkdown.contains("- Date: 2026-09-10 12:49"))
    precondition(revision.chineseMarkdown.contains("- Project: 项目"))
    precondition(revision.evidenceSource == .legacy)
    precondition(revision.markdown.contains("transcript.md (legacy fallback"))
    precondition(revision.chineseMarkdown.contains("transcript.md (legacy fallback"))
    try "New original transcription".write(to: directory.appending(path: "transcript_raw.md"), atomically: true, encoding: .utf8)
    do { try generator.save(revision); preconditionFailure("Added raw transcript accepted") } catch RevisionError.changed {}
    try " \n".write(to: directory.appending(path: "transcript_raw.md"), atomically: true, encoding: .utf8)
    do { _ = try await generator.generate(for: meeting); preconditionFailure("Empty raw silently fell back to readable") }
    catch is SummaryEvidence.EmptySource {}
    try Data([0xFF, 0xFE, 0xFF]).write(to: directory.appending(path: "transcript_raw.md"))
    do { _ = try await generator.generate(for: meeting); preconditionFailure("Unreadable raw silently fell back to readable") } catch {}
    try FileManager.default.removeItem(at: directory.appending(path: "transcript_raw.md"))
    try "Concurrent Chinese edit".write(to: directory.appending(path: "summary_cn.md"), atomically: true, encoding: .utf8)
    do { try generator.save(revision); preconditionFailure("Stale Chinese summary accepted") } catch RevisionError.changed {}
    try FileManager.default.removeItem(at: directory.appending(path: "summary_cn.md"))
    try "Edited transcript".write(to: directory.appending(path: "transcript.md"), atomically: true, encoding: .utf8)
    do { try generator.save(revision); preconditionFailure("Stale transcript accepted") } catch RevisionError.changed {}
    try transcript.write(to: directory.appending(path: "transcript.md"), atomically: true, encoding: .utf8)
    try "Edited summary".write(to: directory.appending(path: "summary.md"), atomically: true, encoding: .utf8)
    do { try generator.save(revision); preconditionFailure("Stale summary accepted") } catch RevisionError.changed {}
    try original.write(to: directory.appending(path: "summary.md"), atomically: true, encoding: .utf8)
    try "Changed context".write(to: project.url.appending(path: "meeting_context.md"), atomically: true, encoding: .utf8)
    do { try generator.save(revision); preconditionFailure("Stale context accepted") } catch RevisionError.changed {}
    try "PROJECT_REGEN".write(to: project.url.appending(path: "meeting_context.md"), atomically: true, encoding: .utf8)
    try generator.save(revision)
    precondition(tryText(directory.appending(path: "summary.md")) == revision.markdown)
    precondition(tryText(directory.appending(path: "summary_cn.md")) == revision.chineseMarkdown)
    precondition(tryText(directory.appending(path: "transcript.md")) == transcript)
    let audio = try Data(contentsOf: directory.appending(path: "audio.m4a"))
    precondition(audio == Data([1, 2, 3]))
    let history = try FileManager.default.contentsOfDirectory(at: directory.appending(path: ".summary-history"), includingPropertiesForKeys: nil)
    precondition(history.count == 1)
    precondition(tryText(history[0].appending(path: "previous.md")) == original)
    let metadata = tryText(history[0].appending(path: "provenance.json"))
    precondition(metadata.contains("fixture-model") && !metadata.contains("secret-fixture"))
    let failed = SummaryRegenerator(store: store, client: ProviderClient(baseURL: "https://invalid-summary.invalid", apiKey: "fixture", model: "fixture", session: session))
    do { _ = try await failed.generate(for: meeting); preconditionFailure("Invalid JSON accepted") } catch ProcessingError.invalidJSON {}
    precondition(tryText(directory.appending(path: "summary.md")) == revision.markdown)
    let invalidReview = SummaryRegenerator(store: store, client: ProviderClient(baseURL: "https://invalid-review.invalid", apiKey: "fixture", model: "fixture", session: session))
    do { _ = try await invalidReview.generate(for: meeting); preconditionFailure("Invalid review accepted") } catch ProcessingError.invalidJSON {}
    precondition(tryText(directory.appending(path: "summary.md")) == revision.markdown)
    do { try generator.save(revision); preconditionFailure("Second save must detect changed summary") } catch RevisionError.changed {}
    let approximate = SummaryRegenerator(store: store, client: ProviderClient(baseURL: "https://approximate.invalid", apiKey: "fixture", model: "fixture", session: session))
    let approximateRevision = try await approximate.generate(for: meeting)
    precondition(approximateRevision.markdown.contains("[unverified reference]"))
    precondition(approximateRevision.markdown.contains("Approximate task"))
    try approximate.save(approximateRevision)
    precondition(tryText(directory.appending(path: "summary.md")) == approximateRevision.markdown)
    try await checkOriginalTranscriptEvidence()
    print("Summary regeneration passed: text-only requests, current context, preview isolation, identity preservation, conflict detection, backup and failure safety")
}

/// Exercise real preparation/archiving with a local provider that makes the readable
/// transcript reverse a negation, while checking the actual summary HTTP requests.
@MainActor
private func checkOriginalTranscriptEvidence() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "evidence-check-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ArchiveStore(root: root)
    let project = try store.createProject(named: "Evidence")
    let (directory, manifest) = try store.createPendingSession(videoEnabled: false, microphoneID: nil)
    let systemAudio = directory.appending(path: "system-audio.caf")
    do {
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let audio = try AVAudioFile(forWriting: systemAudio, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000)!
        buffer.frameLength = 24_000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 24_000)
        try audio.write(from: buffer)
    }
    try await MediaProcessor().makeCaptureMovie(systemAudio: systemAudio, microphone: nil,
                                               destination: directory.appending(path: "capture.mov"))
    // The marker represents an excluded, broken microphone that must remain visible.
    try Data([1, 2, 3]).write(to: directory.appending(path: "microphone.m4a"))
    let recovery = CapturePreparation(state: .ready, mode: .systemAudioOnly, reason: "Fixture microphone failure")
    try recovery.write(in: directory)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OriginalEvidenceFixture.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let provider = ProviderClient(baseURL: "https://evidence.invalid", apiKey: "fixture", model: "fixture", session: session)
    let archived = try await MeetingProcessor(store: store, client: provider)
        .process(directory: directory, manifest: manifest, projectName: project.name)
    let rawURL = archived.appending(path: "transcript_raw.md")
    let readableURL = archived.appending(path: "transcript.md")
    let raw = try String(contentsOf: rawURL, encoding: .utf8)
    let readable = try String(contentsOf: readableURL, encoding: .utf8)
    precondition(raw.contains("We did not approve the launch."))
    precondition(readable.contains("We did approve the launch."), "Fixture must exercise a structurally accepted polarity edit")
    let initial = try String(contentsOf: archived.appending(path: "summary.md"), encoding: .utf8)
    precondition(initial.contains("- Evidence: transcript_raw.md") && !initial.contains("[unverified reference]"))
    precondition(initial.contains("Only system audio was recovered"))
    let initialChinese = tryText(archived.appending(path: "summary_cn.md"))
    precondition(initialChinese.contains("- Evidence: transcript_raw.md") && initialChinese.contains("仅恢复了系统音频"))
    precondition(!initialChinese.contains("invented.md"), "Chinese metadata must be copied deterministically")
    precondition(tryText(archived.appending(path: "summary-provenance.json")).contains("\"evidenceSource\":\"transcript_raw.md\""))
    precondition(FileManager.default.fileExists(atPath: archived.appending(path: "microphone.m4a").path))

    let meeting = ArchivedMeeting(title: "Evidence", projectName: project.name, dateText: "", date: Date(), createdAt: Date(), url: archived)
    let generator = SummaryRegenerator(store: store, client: provider)
    let revision = try await generator.generate(for: meeting)
    precondition(revision.evidenceSource == .raw && !revision.markdown.contains("[unverified reference]"))
    precondition(revision.markdown.contains("Only system audio was recovered"))
    precondition(revision.chineseMarkdown.contains("仅恢复了系统音频"))
    precondition(!revision.chinesePrompt.contains("Only system audio was recovered"), "Recovery warnings must be appended deterministically after translation")
    try (raw + "\nExternal edit").write(to: rawURL, atomically: true, encoding: .utf8)
    do { try generator.save(revision); preconditionFailure("Edited raw transcript accepted") } catch RevisionError.changed {}
    try FileManager.default.removeItem(at: rawURL)
    do { try generator.save(revision); preconditionFailure("Removed raw transcript accepted") } catch RevisionError.changed {}
    try raw.write(to: rawURL, atomically: true, encoding: .utf8)
    try FileManager.default.removeItem(at: readableURL)
    do { try generator.save(revision); preconditionFailure("Removed readable transcript accepted") } catch RevisionError.changed {}
    let withoutReadable = try await generator.generate(for: meeting)
    precondition(withoutReadable.evidenceSource == .raw, "Raw source remains usable without an editorial copy")
    try readable.write(to: readableURL, atomically: true, encoding: .utf8)
    do { try generator.save(withoutReadable); preconditionFailure("Added readable transcript accepted") } catch RevisionError.changed {}
    let receiptURL = archived.appending(path: CapturePreparation.fileName)
    try FileManager.default.removeItem(at: receiptURL)
    do { try generator.save(revision); preconditionFailure("Removed recovery metadata accepted") } catch RevisionError.changed {}
    try Data("invalid".utf8).write(to: receiptURL)
    do { try generator.save(revision); preconditionFailure("Corrupt recovery metadata accepted") } catch RevisionError.changed {}
    try recovery.write(in: archived)
    try generator.save(revision)
    precondition(tryText(archived.appending(path: "summary.md")) == revision.markdown)
    precondition(tryText(archived.appending(path: "summary_cn.md")) == revision.chineseMarkdown)
    precondition(tryText(rawURL) == raw && tryText(readableURL) == readable)
    print("Original evidence passed: initial + regenerated HTTP inputs, polarity edit, source metadata, legacy fallback, raw/readable conflicts, recovery notices")
}

private final class OriginalEvidenceFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let body = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let messages = body["messages"] as! [[String: Any]]
        let parts = messages[0]["content"] as! [[String: Any]]
        let prompt = parts.first { $0["type"] as? String == "text" }!["text"] as! String
        let content: String
        if parts.contains(where: { $0["type"] as? String == "input_audio" }) {
            content = "[00:00] Speaker A: We did not approve the launch."
        } else if prompt.contains("CLEAN_TRANSCRIPT") {
            let raw = prompt.components(separatedBy: "<raw_transcript>\n")[1].components(separatedBy: "\n</raw_transcript>")[0]
            let edited = raw.replacingOccurrences(of: "did not approve", with: "did approve")
            content = String(data: try! JSONSerialization.data(withJSONObject: ["transcript": edited]), encoding: .utf8)!
        } else if prompt.contains("CHINESE_SUMMARY") {
            // Deliberately invent metadata; the application must replace it from the source.
            content = ##"{"folderTitle":"发布讨论","markdown":"# 发布讨论\n\n- Evidence: invented.md\n\n## 摘要\n\n发布尚未批准。"}"##
        } else {
            precondition(prompt.contains("authoritative evidence is transcript_raw.md"))
            precondition(prompt.contains("L5: [00:00] Speaker A: We did not approve the launch."))
            precondition(!prompt.contains("We did approve the launch."), "An editorial polarity reversal reached the evidence request")
            content = #"{"title":"Launch discussion","projectName":"Evidence","summary":["Launch was not approved."],"actionItems":[],"decisions":[],"keyTopics":["Launch"],"uncertainties":[],"openQuestions":[{"text":"Launch approval remains unresolved","evidence":[{"line":5,"quote":"We did not approve the launch."}]}]}"#
        }
        let response = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func tryText(_ url: URL) -> String { try! String(contentsOf: url, encoding: .utf8) }

private final class SummaryFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let body = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let messages = body["messages"] as! [[String: Any]]
        let parts = messages[0]["content"] as! [[String: Any]]
        precondition(parts.allSatisfy { $0["type"] as? String == "text" })
        let prompt = parts[0]["text"] as! String
        precondition(["GLOBAL_REGEN", "PROJECT_REGEN"].allSatisfy { prompt.contains($0) })
        if !prompt.contains("CHINESE_SUMMARY") { precondition(prompt.contains("TRANSCRIPT_REGEN")) }
        var content = (request.url!.host == "invalid-summary.invalid" || (request.url!.host == "invalid-review.invalid" && prompt.contains("<draft>"))) ? "invalid" : #"{"title":"Changed title","projectName":"Wrong project","summary":["New content"],"actionItems":[],"decisions":[],"keyTopics":[],"uncertainties":["Verify terminology"],"milestones":[],"openQuestions":[],"deferredWork":[],"inventory":[]}"#
        if request.url!.host == "approximate.invalid" {
            content = content.replacingOccurrences(of: #""actionItems":[]"#, with: #""actionItems":[{"assignee":"","task":"Approximate task","deadline":"","context":"","evidence":[{"line":999,"quote":"Paraphrased wording"}]}]"#)
        }
        if prompt.contains("CHINESE_SUMMARY") { content = ##"{"folderTitle":"会议测试","markdown":"# 会议测试\n\n## 摘要\n\n中文摘要。"}"## }
        let response = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
