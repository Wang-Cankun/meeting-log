import Foundation
import AVFoundation

let cleanupSource = "# Transcript\n\n## 00:00–00:30\n\n[00:00] Speaker A: Um, we have not approved this.\n\n[00:20] Speaker B: Review on Monday, not Friday.\n"
let cleanupExpected = cleanupSource.replacingOccurrences(of: "Um, ", with: "")
precondition(TranscriptPolisher.acceptable(cleanupExpected, raw: cleanupSource))
precondition(!TranscriptPolisher.acceptable("# Transcript\n\nApproved.", raw: cleanupSource))

do {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fresh = try MediaProcessor.chunkDuration(in: root)
    precondition(fresh == 600)
    try Data().write(to: root.appending(path: "0000.m4a"))
    let resumed = try MediaProcessor.chunkDuration(in: root)
    precondition(resumed == 600)
    try FileManager.default.removeItem(at: root.appending(path: "duration.json"))
    let legacy = try MediaProcessor.chunkDuration(in: root)
    precondition(legacy == 300, "Existing five-minute chunks must retain their checkpoint boundaries")
}

precondition(ArchiveStore.meetingTitle("  中文会议 / 讨论: 下一步  ") == "中文会议 讨论 下一步")
do {
    _ = try ArchiveStore.projectName(".pending")
    preconditionFailure("Hidden project names must be rejected")
} catch {}

let analysis = MeetingAnalysis(
    title: "Weekly sync",
    projectName: "Demo",
    summary: ["Reviewed the launch."],
    actionItems: [.init(assignee: "", task: "Send the draft", deadline: "", context: "")],
    decisions: [],
    keyTopics: []
)
let markdown = MarkdownRenderer.summary(analysis, startedAt: Date(timeIntervalSince1970: 0))
precondition(markdown.contains("| Send the draft | — | — | — |"))
precondition(markdown.contains("## Decisions\n\nNone."))

var specialAnalysis = analysis
specialAnalysis.actionItems = [.init(assignee: "A | B", task: "Review <draft>\nthen send", deadline: "", context: "R&D")]
let specialMarkdown = MarkdownRenderer.summary(specialAnalysis, startedAt: Date())
precondition(specialMarkdown.contains("| Review &lt;draft&gt;<br>then send | A &#124; B | — | R&amp;D |"))
specialAnalysis.uncertainties = ["Package name needs confirmation."]
let uncertainMarkdown = MarkdownRenderer.summary(specialAnalysis, startedAt: Date())
precondition(uncertainMarkdown.contains("## Needs verification\n\n- Package name needs confirmation."))

let validTranscript = try TranscriptResponse.validate("[19:20] Speaker A: Hello.\n[19:22] Speaker B: Yes.", start: 1160, end: 1460)
precondition(validTranscript.contains("\n\n"))
for invalid in ["Commentary\n[19:20] Speaker A: Hello.", "[00:00] Speaker A: Hello.", "[24:20] Speaker A: Hello.", "[19:22] Speaker A: Hello.\n[19:21] Speaker B: Yes.", "```markdown\n[19:20] Speaker A: Hello.\n```", ""] {
    do {
        _ = try TranscriptResponse.validate(invalid, start: 1160, end: 1460)
        preconditionFailure("Malformed transcript accepted")
    } catch is TranscriptResponse.ValidationError {}
}

// Integer timestamp limits must include the final fractional second.
for (start, end, lastTime, upperBound) in [(0.0, 0.6, "00:00", "00:01"), (0.0, 19.8, "00:19", "00:20"), (19.8, 20.2, "00:20", "00:21"), (0.0, 20.0, "00:19", "00:20")] {
    let prompt = Prompts.transcription(context: "", start: start, end: end)
    precondition(prompt.contains("strictly before \(upperBound);"))
    _ = try TranscriptResponse.validate("[\(lastTime)] Speaker A: Final turn.", start: start, end: end)
    do {
        _ = try TranscriptResponse.validate("[\(upperBound)] Speaker A: Outside clip.", start: start, end: end)
        preconditionFailure("Exclusive upper bound accepted")
    } catch is TranscriptResponse.ValidationError {}
}
let evidenceTranscript = "# Transcript\n## 00:00–05:00\n[00:01] Speaker A: Access by Tuesday.\n## 04:50–09:50\n[04:51] Speaker A: Migration is not decided."
var evidenceAnalysis = analysis
evidenceAnalysis.actionItems = [.init(assignee: "", task: "Set up access", deadline: "Tuesday", context: "", evidence: [.init(line: 3, quote: "Access by Tuesday.")])]
evidenceAnalysis.milestones = [.init(text: "Access target: Tuesday", evidence: [.init(line: 3, quote: "Access by Tuesday.")])]
evidenceAnalysis.openQuestions = [.init(text: "Migration remains undecided", evidence: [.init(line: 5, quote: "Migration is not decided.")])]
evidenceAnalysis.deferredWork = []
evidenceAnalysis.inventory = []
evidenceAnalysis = TranscriptEvidence.annotateReferences(evidenceAnalysis, transcript: evidenceTranscript)
let annotated = TranscriptEvidence.annotated(evidenceTranscript)
precondition(annotated.contains("scope 1") && annotated.contains("scope 2") && annotated.contains("L5: [04:51]"))
let evidenceMarkdown = MarkdownRenderer.summary(evidenceAnalysis, startedAt: Date())
precondition(evidenceMarkdown.contains("## Open questions") && evidenceMarkdown.contains("L3: “Access by Tuesday.”"))
evidenceAnalysis.actionItems[0].evidence = [.init(line: 3, quote: "Access by Friday.")]
let approximateAnalysis = TranscriptEvidence.annotateReferences(evidenceAnalysis, transcript: evidenceTranscript)
precondition(approximateAnalysis.actionItems[0].task == evidenceAnalysis.actionItems[0].task)
precondition(approximateAnalysis.actionItems[0].evidence?[0].verified == false)
precondition(MarkdownRenderer.summary(approximateAnalysis, startedAt: Date()).contains("[unverified reference]"))
evidenceAnalysis.actionItems[0].evidence = nil
let missingReferences = TranscriptEvidence.annotateReferences(evidenceAnalysis, transcript: evidenceTranscript)
precondition(missingReferences.actionItems.count == 1 && !(missingReferences.uncertainties ?? []).isEmpty)
let longTitle = "Workstation, Server, and Pipeline Knowledge Transfer for Minna Lab"
precondition(ArchiveStore.meetingTitle(longTitle) == longTitle)

let requestedMeeting = URL(filePath: "/tmp/meeting-a")
let firstOpen = SummaryOpenRequest(url: requestedMeeting)
let repeatedOpen = SummaryOpenRequest(url: requestedMeeting)
precondition(firstOpen.url == repeatedOpen.url && firstOpen != repeatedOpen,
             "Opening A after selecting B must emit another observable request")

precondition(AudioLevelState(level: 0.02) == .silence)
precondition(AudioLevelState(level: 0.03) == .active)
precondition(AudioLevelState(level: 0.82) == .high)
precondition(AudioLevelState(level: 0.96) == .clipping)

let provider = ProviderClient(
    baseURL: "https://openrouter.ai/api/v1",
    apiKey: "test",
    model: "test"
)
let providerEndpoint = try provider.endpoint
precondition(providerEndpoint.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
do {
    _ = try ProviderClient(baseURL: "http://localhost", apiKey: "test", model: "test").endpoint
    preconditionFailure("Provider URLs must use HTTPS")
} catch {}

precondition(AppPhase.idle.recordingAction(isBusy: false) == .start)
precondition(AppPhase.recording(startedAt: Date()).recordingAction(isBusy: false) == .stop)
precondition(AppPhase.idle.recordingAction(isBusy: true) == nil)
precondition(AppPhase.failed("x").clearingFailure == .idle)
precondition(AppPhase.idle.clearingFailure == .idle)
let clearingRecordingDate = Date(timeIntervalSince1970: 0)
precondition(AppPhase.recording(startedAt: clearingRecordingDate).clearingFailure == .recording(startedAt: clearingRecordingDate))
precondition(!RecordingDurationPolicy.shouldProcess(
    startedAt: Date(timeIntervalSince1970: 0),
    stoppedAt: Date(timeIntervalSince1970: 9.999)
))
precondition(RecordingDurationPolicy.shouldProcess(
    startedAt: Date(timeIntervalSince1970: 0),
    stoppedAt: Date(timeIntervalSince1970: 10)
))

let earlyRecordingStatus = StatusItemPresentation(phase: .recording(startedAt: Date(timeIntervalSince1970: 0)))
let lateRecordingStatus = StatusItemPresentation(phase: .recording(startedAt: Date(timeIntervalSince1970: 3_600)))
precondition(earlyRecordingStatus == lateRecordingStatus)

var levelGate = LevelUpdateGate(intervalNanoseconds: 100)
precondition(levelGate.shouldPublish(at: 1_000))
precondition(!levelGate.shouldPublish(at: 1_099))
precondition(levelGate.shouldPublish(at: 1_100))
levelGate.reset()
precondition(levelGate.shouldPublish(at: 1_101))

let compatibilityRoot = FileManager.default.temporaryDirectory
    .appending(path: "meeting-log-compatibility-\(UUID().uuidString)", directoryHint: .isDirectory)
let legacyDirectory = compatibilityRoot.appending(path: "legacy", directoryHint: .isDirectory)
let currentDirectory = compatibilityRoot.appending(path: "current", directoryHint: .isDirectory)
let interruptedDirectory = compatibilityRoot.appending(path: "interrupted", directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: currentDirectory, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: interruptedDirectory, withIntermediateDirectories: true)
FileManager.default.createFile(atPath: legacyDirectory.appending(path: "capture.mov").path, contents: Data([0]))
FileManager.default.createFile(atPath: currentDirectory.appending(path: "system-audio.caf").path, contents: Data())
FileManager.default.createFile(atPath: currentDirectory.appending(path: "microphone.m4a").path, contents: Data())
FileManager.default.createFile(atPath: interruptedDirectory.appending(path: "capture.mov").path, contents: Data())
FileManager.default.createFile(atPath: interruptedDirectory.appending(path: "system-audio.caf").path, contents: Data())
precondition(MediaProcessor.pendingInput(in: legacyDirectory) == .combined(legacyDirectory.appending(path: "capture.mov")))
precondition(MediaProcessor.pendingInput(in: currentDirectory) == .raw(
    systemAudio: currentDirectory.appending(path: "system-audio.caf"),
    microphone: currentDirectory.appending(path: "microphone.m4a")
))
precondition(MediaProcessor.pendingInput(in: interruptedDirectory) == .raw(
    systemAudio: interruptedDirectory.appending(path: "system-audio.caf"),
    microphone: nil
))

let discardStore = ArchiveStore(root: compatibilityRoot)
let noPendingBeforeCreate = try discardStore.hasPendingSessions()
let pendingListBeforeCreate = try discardStore.pendingSessions()
precondition(!noPendingBeforeCreate)
precondition(pendingListBeforeCreate.isEmpty)
let discardedSession = try discardStore.createPendingSession(videoEnabled: false, microphoneID: nil)
let pendingAfterCreate = try discardStore.hasPendingSessions()
let pendingListAfterCreate = try discardStore.pendingSessions()
precondition(pendingAfterCreate)
precondition(pendingListAfterCreate.count == 1)
try discardStore.discardPendingSession(id: discardedSession.1.id)
let pendingAfterDiscard = try discardStore.hasPendingSessions()
precondition(!pendingAfterDiscard)
precondition(!FileManager.default.fileExists(atPath: discardedSession.0.path))
try FileManager.default.removeItem(at: compatibilityRoot)
try await checkConcurrentTranscription()
try await checkSummaryRegeneration()
print("MeetingLog check passed")

// Optional real audio fixtures remain local; no provider requests are made.
for path in CommandLine.arguments.dropFirst() {
    let source = URL(filePath: path)
    let root = FileManager.default.temporaryDirectory.appending(path: "meeting-log-import-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ArchiveStore(root: root)
    let project = try store.createProject(named: "导入测试")
    try "GLOBAL_CONTEXT_FIXTURE".write(to: root.appending(path: "meeting_context.md"), atomically: true, encoding: .utf8)
    try "PROJECT_CONTEXT_FIXTURE".write(to: project.url.appending(path: "meeting_context.md"), atomically: true, encoding: .utf8)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let before = try Data(contentsOf: source)
    let (directory, manifest) = try await AudioImport.stage(source, date: date, projectName: project.name, store: store)
    precondition(manifest.startedAt == date && manifest.projectName == project.name)
    precondition(manifest.status == .captured && !manifest.videoEnabled)
    let recovered = try store.pendingSessions()
    precondition(recovered.count == 1 && recovered[0].1.importedFileName == source.lastPathComponent)
    guard case let .combined(input) = MediaProcessor.pendingInput(in: directory) else {
        preconditionFailure("Imported audio must be recoverable")
    }
    let copy = try Data(contentsOf: input)
    precondition(copy == before)
    let prepared = try await MediaProcessor().prepareAudio(from: input, in: directory)
    precondition(!prepared.chunks.isEmpty)
    for chunk in prepared.chunks {
        let duration = try await AudioImport.inspect(chunk.url)
        let file = try AVAudioFile(forReading: chunk.url)
        precondition(file.fileFormat.channelCount == 1)
        precondition(file.fileFormat.sampleRate == 24_000)
        precondition(abs(duration - (chunk.endSeconds - chunk.startSeconds)) < 0.2)
        if duration >= 30 {
            let size = try chunk.url.resourceValues(forKeys: [.fileSizeKey]).fileSize!
            precondition(Double(size) < duration * 9_000 + 20_000, "Speech upload exceeded its bitrate budget")
            print("Speech upload: \(Int(duration)) seconds, \(size) bytes, mono 24 kHz")
        }
    }
    let retry = try await MediaProcessor().prepareAudio(from: input, in: directory)
    precondition(retry.chunks.count == prepared.chunks.count)
    let after = try Data(contentsOf: source)
    precondition(before == after)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FixtureProvider.self]
    let client = ProviderClient(baseURL: "https://fixture.invalid", apiKey: "fixture", model: "fixture",
                                session: URLSession(configuration: configuration))
    let failingClient = ProviderClient(baseURL: "https://failure.invalid", apiKey: "fixture", model: "fixture",
                                       session: URLSession(configuration: configuration))
    do {
        _ = try await MeetingProcessor(store: store, client: failingClient)
            .process(directory: directory, manifest: manifest, projectName: manifest.projectName)
        preconditionFailure("Provider failure must leave a recoverable import")
    } catch ProviderError.authentication {}
    let failed = try store.pendingSessions()
    precondition(failed.count == 1 && failed[0].1.status == .failed)
    let retained = try Data(contentsOf: input)
    precondition(retained == before)
    let destination = try await MeetingProcessor(store: store, client: client)
        .process(directory: directory, manifest: recovered[0].1, projectName: recovered[0].1.projectName)
    precondition(destination.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath().path == project.url.resolvingSymlinksInPath().path,
                 "Unexpected destination: \(destination.path), project: \(project.url.path)")
    precondition(destination.lastPathComponent.hasPrefix(ArchiveStore.timestamp.string(from: date)))
    precondition(destination.lastPathComponent.dropFirst(8).hasPrefix("-"))
    precondition(destination.lastPathComponent.contains("导入测试"))
    for name in ["audio.m4a", "transcript_raw.md", "transcript.md", "summary.md", "summary_cn.md"] {
        precondition(FileManager.default.fileExists(atPath: destination.appending(path: name).path))
    }
    precondition(!FileManager.default.fileExists(atPath: destination.appending(path: input.lastPathComponent).path))
    precondition(!FileManager.default.fileExists(atPath: directory.path))
    print("Import fixture passed: \(source.lastPathComponent), \(prepared.chunks.count) blocks")
}


let multipleSources = CommandLine.arguments.dropFirst().map { URL(filePath: $0) }
if multipleSources.count > 1 {
    let root = FileManager.default.temporaryDirectory.appending(path: "meeting-log-multiple-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ArchiveStore(root: root)
    let project = try store.createProject(named: "Multi-part test")
    try "GLOBAL_CONTEXT_FIXTURE".write(to: root.appending(path: "meeting_context.md"), atomically: true, encoding: .utf8)
    try "PROJECT_CONTEXT_FIXTURE".write(to: project.url.appending(path: "meeting_context.md"), atomically: true, encoding: .utf8)
    let chosenOrder = Array(multipleSources.reversed())
    do {
        _ = try await AudioImport.stage([chosenOrder[0], chosenOrder[0]], date: Date(), projectName: project.name, store: store)
        preconditionFailure("Duplicate sources must be rejected")
    } catch ImportError.duplicate {}
    do {
        _ = try await AudioImport.stage([chosenOrder[0], root.appending(path: "missing.m4a")], date: Date(), projectName: project.name, store: store)
        preconditionFailure("An invalid file must reject the whole group")
    } catch {}
    let emptyPending = try store.pendingSessions()
    precondition(emptyPending.isEmpty)
    let (directory, manifest) = try await AudioImport.stage(chosenOrder, date: Date(), projectName: project.name, store: store)
    let recovered = try store.pendingSessions()
    precondition(recovered.count == 1)
    precondition(recovered[0].1.importedParts == manifest.importedParts)
    guard case let .importedParts(parts) = MediaProcessor.pendingInput(in: directory) else {
        preconditionFailure("Multi-part import must be recoverable")
    }
    precondition(parts.map(\.originalName) == chosenOrder.map(\.lastPathComponent))
    for (index, part) in parts.enumerated() {
        let copied = try Data(contentsOf: directory.appending(path: "originals/\(part.fileName)"))
        let original = try Data(contentsOf: chosenOrder[index])
        precondition(copied == original)
    }
    let prepared = try await MediaProcessor().prepareImportedAudio(parts: parts, in: directory)
    let combinedDuration = try await AudioImport.inspect(prepared.audio)
    precondition(abs(combinedDuration - parts.reduce(0) { $0 + $1.duration }) < 1)
    var start = 0.0
    for part in parts {
        let end = start + part.duration
        let chunks = prepared.chunks.filter { $0.startSeconds >= start && $0.startSeconds < end }
        precondition(!chunks.isEmpty)
        precondition(abs(chunks[0].startSeconds - start) < 0.01)
        precondition(chunks.allSatisfy { $0.endSeconds <= end + 0.01 && $0.endSeconds > $0.startSeconds })
        precondition(abs(chunks.last!.endSeconds - end) < 0.1)
        start = end
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FixtureProvider.self]
    let failedClient = ProviderClient(baseURL: "https://failure.invalid", apiKey: "fixture", model: "fixture",
                                      session: URLSession(configuration: configuration))
    do {
        _ = try await MeetingProcessor(store: store, client: failedClient)
            .process(directory: directory, manifest: manifest, projectName: project.name)
        preconditionFailure("Failure must preserve all parts")
    } catch ProviderError.authentication {}
    let failedSessions = try store.pendingSessions()
    precondition(failedSessions[0].1.status == .failed)
    let client = ProviderClient(baseURL: "https://fixture.invalid", apiKey: "fixture", model: "fixture",
                                session: URLSession(configuration: configuration))
    let final = try await MeetingProcessor(store: store, client: client)
        .process(directory: directory, manifest: failedSessions[0].1, projectName: project.name)
    let transcript = try String(contentsOf: final.appending(path: "transcript.md"), encoding: .utf8)
    precondition(transcript.contains("Gaps and real-world chronology are unknown"))
    for (index, part) in parts.enumerated() {
        precondition(transcript.contains("## Recording \(index + 1): \(part.originalName)"))
        precondition(FileManager.default.fileExists(atPath: chosenOrder[index].path))
    }
    precondition(FileManager.default.fileExists(atPath: final.appending(path: "sources.json").path))
    precondition(!FileManager.default.fileExists(atPath: final.appending(path: "originals").path))
    precondition(!FileManager.default.fileExists(atPath: final.appending(path: "parts").path))
    let meetings = try store.recentMeetings()
    precondition(meetings.count == 1 && meetings[0].projectName == project.name)
    print("Multi-part import passed: \(parts.count) originals, \(prepared.chunks.count) bounded blocks, one archive")
}


final class FixtureProvider: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // Verify context reaches the actual HTTP request for both audio and summary.
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let object = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
        let messages = object["messages"] as! [[String: Any]]
        let parts = messages[0]["content"] as! [[String: Any]]
        let prompt = parts.first { $0["type"] as? String == "text" }!["text"] as! String
        precondition(prompt.contains("GLOBAL_CONTEXT_FIXTURE"))
        precondition(prompt.contains("PROJECT_CONTEXT_FIXTURE"))
        // Synthetic responses exercise archiving without sending recordings anywhere.
        let summaryContent = """
        {"title":"Import fixture","projectName":"导入测试","summary":["Synthetic test response."],"actionItems":[],"decisions":[],"keyTopics":[],"milestones":[],"openQuestions":[],"deferredWork":[],"inventory":[]}
        """
        let content: String
        if parts.contains(where: { $0["type"] as? String == "input_audio" }) {
            let regex = try! NSRegularExpression(pattern: #"recording is (\d+:\d+)"#)
            let ns = prompt as NSString
            let match = regex.firstMatch(in: prompt, range: NSRange(location: 0, length: ns.length))!
            content = "[\(ns.substring(with: match.range(at: 1)))] Speaker A: Synthetic transcript."
        } else if prompt.contains("CLEAN_TRANSCRIPT") {
            let raw = prompt.components(separatedBy: "<raw_transcript>\n")[1].components(separatedBy: "\n</raw_transcript>")[0]
            content = String(data: try! JSONSerialization.data(withJSONObject: ["transcript": raw]), encoding: .utf8)!
        } else if prompt.contains("CHINESE_SUMMARY") {
            content = ##"{"folderTitle":"导入测试","markdown":"# 导入测试\n\n## 摘要\n\n测试摘要。"}"##
        } else {
            content = summaryContent
        }
        let data = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: request.url?.host == "failure.invalid" ? 401 : 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
