import Foundation

precondition(ArchiveStore.slug("  Café Project / Linux Test  ") == "cafe-project-linux-test")
precondition(ArchiveStore.slug("中文会议") == "zhong-wen-hui-yi")

let analysis = MeetingAnalysis(
    title: "Weekly sync",
    projectName: "Demo",
    projectSlug: "demo",
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

precondition(AppPhase.idle.recordingAction(isBusy: false) == .start)
precondition(AppPhase.recording(startedAt: Date()).recordingAction(isBusy: false) == .stop)
precondition(AppPhase.idle.recordingAction(isBusy: true) == nil)
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
let discardedSession = try discardStore.createPendingSession(videoEnabled: false, microphoneID: nil)
try discardStore.discardPendingSession(id: discardedSession.1.id)
precondition(!FileManager.default.fileExists(atPath: discardedSession.0.path))
try FileManager.default.removeItem(at: compatibilityRoot)
print("MeetingLog check passed")
