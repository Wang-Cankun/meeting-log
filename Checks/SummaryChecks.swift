import Foundation

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
    print("Summary regeneration passed: text-only requests, current context, preview isolation, identity preservation, conflict detection, backup and failure safety")
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
