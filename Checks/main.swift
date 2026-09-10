import Foundation

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
precondition(markdown.contains("- Send the draft\n"))
precondition(markdown.contains("## Decisions\n\nNone."))

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
print("MeetingLog check passed")

// Optional real audio fixtures remain local; no provider requests are made.
for path in CommandLine.arguments.dropFirst() {
    let source = URL(filePath: path)
    let root = FileManager.default.temporaryDirectory.appending(path: "meeting-log-import-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ArchiveStore(root: root)
    let project = try store.createProject(named: "导入测试")
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
    for chunk in prepared.chunks { _ = try await AudioImport.inspect(chunk.url) }
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
    for name in ["original.m4a", "audio.m4a", "transcript.md", "summary.md"] {
        precondition(FileManager.default.fileExists(atPath: destination.appending(path: name).path))
    }
    precondition(!FileManager.default.fileExists(atPath: directory.path))
    print("Import fixture passed: \(source.lastPathComponent), \(prepared.chunks.count) blocks")
}


final class FixtureProvider: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // Synthetic responses exercise archiving without sending recordings anywhere.
        let content = """
        {"title":"Import fixture","projectName":"导入测试","summary":["Synthetic test response."],"actionItems":[],"decisions":[],"keyTopics":[]}
        """
        let data = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: request.url?.host == "failure.invalid" ? 401 : 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
