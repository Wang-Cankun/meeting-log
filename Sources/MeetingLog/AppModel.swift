import AppKit
import AVFoundation
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var phase: AppPhase = .idle
    @Published var videoEnabled = false
    @Published var microphoneEnabled = UserDefaults.standard.object(forKey: "microphoneEnabled") as? Bool ?? true
    @Published var selectedMicrophoneID = UserDefaults.standard.string(forKey: "microphoneID")
    @Published var microphoneLevel: Float = 0
    @Published var systemAudioLevel: Float = 0
    @Published var isTestingMicrophone = false
    @Published var apiKey = ""
    @Published var keySaved = false
    @Published var providerStatus: String?
    @Published var isVerifyingProvider = false
    @Published var modelOptions: [OpenRouterModel] = []
    @Published var selectedModelID = UserDefaults.standard.string(forKey: "openRouterModel") ?? OpenRouterClient.defaultModel
    @Published var archiveRootPath = UserDefaults.standard.string(forKey: ArchiveStore.rootDefaultsKey) ?? AppModel.defaultArchiveURL.path
    @Published var applications: [CaptureApplication] = []
    @Published var selectedSystemAudioBundleID: String?
    @Published var selectedSystemAudioName = "All Mac audio"
    @Published var selectedScreenSource: String?
    @Published var microphonePermission = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published var systemAudioError: String?
    @Published private(set) var isPanelOpen = false
    @Published private(set) var processingText: String?
    @Published private(set) var processingCount = 0
    @Published private(set) var processingFailureCount = 0

    let capture = CaptureService()
    let microphone = MicrophonePreflight()
    let microphones = MicrophonePreflight.devices

    private var currentDirectory: URL?
    private var currentManifest: SessionManifest?
    private var processingQueue: [ProcessingJob] = []
    private var currentProcessingPath: String?
    private var processingTask: Task<Void, Never>?

    init() {
        keySaved = KeychainStore().containsKey()
        UserDefaults.standard.set(archiveRootPath, forKey: ArchiveStore.rootDefaultsKey)
        try? FileManager.default.createDirectory(
            at: URL(filePath: archiveRootPath, directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        capture.onScreenSelection = { [weak self] source in
            self?.selectedScreenSource = source
        }
        capture.onError = { [weak self] message in
            self?.systemAudioError = message
            self?.phase = .failed(message)
        }
        microphone.onLevel = { [weak self] in self?.setMicrophoneLevel($0) }
        capture.onMicrophoneLevel = { [weak self] in self?.setMicrophoneLevel($0) }
        capture.onSystemAudioLevel = { [weak self] in self?.setSystemAudioLevel($0) }
        Task {
            await refreshApplications()
            await resumePendingSessions()
        }
    }

    var isRecording: Bool {
        if case .recording = phase { true } else { false }
    }

    var isProcessing: Bool { processingCount > 0 }

    var hasScreenSource: Bool { selectedScreenSource != nil }

    var canStartRecording: Bool {
        guard !isRecording, !isTestingMicrophone, keySaved, !archiveRootPath.isEmpty else { return false }
        guard systemAudioError == nil else { return false }
        if selectedSystemAudioBundleID != nil, !selectedSystemAudioIsAvailable { return false }
        if microphoneEnabled {
            guard microphonePermission != .denied, microphonePermission != .restricted, !microphones.isEmpty else { return false }
        }
        return !videoEnabled || hasScreenSource
    }

    var statusText: String {
        switch phase {
        case .idle:
            if !keySaved { return "OpenRouter setup required" }
            if videoEnabled, !hasScreenSource { return "Choose a screen source" }
            if selectedSystemAudioBundleID != nil, !selectedSystemAudioIsAvailable { return "Audio application unavailable" }
            if microphoneEnabled, microphonePermission == .denied || microphonePermission == .restricted { return "Microphone permission required" }
            if microphoneEnabled, microphones.isEmpty { return "No microphone available" }
            return "Ready to record"
        case .recording: return "Recording"
        case let .failed(value): return value
        }
    }

    var microphoneStateText: String {
        if !microphoneEnabled { return "Not included" }
        if microphones.isEmpty { return "No microphone found" }
        if microphonePermission == .denied || microphonePermission == .restricted { return "Permission required" }
        if isRecording { return "Recording" }
        if !isPanelOpen { return "Preview paused" }
        return signalState(for: microphoneLevel)
    }

    var systemAudioStateText: String {
        if selectedSystemAudioBundleID != nil, !selectedSystemAudioIsAvailable { return "Application unavailable" }
        if systemAudioError != nil { return "Unavailable" }
        if isRecording { return "Recording" }
        if !isPanelOpen { return "Preview paused" }
        return signalState(for: systemAudioLevel)
    }

    var selectedSystemAudioIsAvailable: Bool {
        guard let selectedSystemAudioBundleID else { return true }
        return applications.contains { $0.bundleIdentifier == selectedSystemAudioBundleID }
    }

    func chooseArchiveRoot() {
        guard canChangeArchive else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(filePath: archiveRootPath, directoryHint: .isDirectory)
        panel.message = "Choose where MeetingLog should create project folders."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setArchiveRoot(url)
    }

    func useObsidianArchive() {
        guard canChangeArchive else { return }
        do {
            try FileManager.default.createDirectory(at: Self.defaultArchiveURL, withIntermediateDirectories: true)
            setArchiveRoot(Self.defaultArchiveURL)
        } catch {
            phase = .failed("Cannot use the Obsidian archive: \(error.localizedDescription)")
        }
    }

    func saveAndVerifyKey() {
        Task {
            let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { providerStatus = AppConfigurationError.apiKey.localizedDescription; return }
            isVerifyingProvider = true
            defer { isVerifyingProvider = false }
            do {
                try await OpenRouterClient(apiKey: value, model: selectedModelID).verifyKey()
                try KeychainStore().save(value)
                apiKey = ""
                keySaved = true
                providerStatus = "Connected"
                await resumePendingSessions()
            } catch {
                providerStatus = error.localizedDescription
            }
        }
    }

    func verifySavedKey() {
        Task {
            guard let key = try? KeychainStore().load(), !key.isEmpty else {
                keySaved = false
                providerStatus = "No API key saved"
                return
            }
            isVerifyingProvider = true
            defer { isVerifyingProvider = false }
            do {
                try await OpenRouterClient(apiKey: key, model: selectedModelID).verifyKey()
                providerStatus = "Connected"
            } catch {
                providerStatus = error.localizedDescription
            }
        }
    }

    func removeKey() {
        KeychainStore().delete()
        apiKey = ""
        keySaved = false
        providerStatus = "API key removed"
    }

    func loadModels() {
        Task {
            do {
                modelOptions = try await OpenRouterClient.availableAudioModels()
            } catch {
                providerStatus = "Could not load models: \(error.localizedDescription)"
            }
        }
    }

    func selectModel(_ id: String) {
        selectedModelID = id
        UserDefaults.standard.set(id, forKey: "openRouterModel")
    }

    func selectMicrophone(_ id: String?) {
        selectedMicrophoneID = id
        UserDefaults.standard.set(id, forKey: "microphoneID")
        Task {
            guard microphoneEnabled, isPanelOpen, !isRecording, microphonePermission == .authorized else { return }
            do { try microphone.start(deviceID: selectedMicrophoneID) }
            catch { phase = .failed(error.localizedDescription) }
        }
    }

    func setMicrophoneEnabled(_ enabled: Bool) {
        microphoneEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "microphoneEnabled")
        if enabled {
            Task { await startPreviewMonitoring() }
        } else {
            microphone.stop()
            microphoneLevel = 0
        }
    }

    func selectSystemAudio(_ application: CaptureApplication?) {
        selectedSystemAudioBundleID = application?.bundleIdentifier
        selectedSystemAudioName = application?.name ?? "All Mac audio"
        Task { await restartSystemAudioPreview() }
    }

    func setVideoEnabled(_ enabled: Bool) {
        videoEnabled = enabled
    }

    func chooseScreen() {
        capture.chooseScreen()
    }

    func panelDidOpen() {
        isPanelOpen = true
        Task {
            await refreshApplications()
            await startPreviewMonitoring()
        }
    }

    func panelDidClose() {
        isPanelOpen = false
        microphone.stop()
        Task { await capture.stopPreview() }
    }

    func testMicrophone() {
        Task {
            do {
                guard microphoneEnabled else { return }
                guard await AVCaptureDevice.requestAccess(for: .audio) else { throw PreflightError.permissionDenied }
                microphonePermission = AVCaptureDevice.authorizationStatus(for: .audio)
                isTestingMicrophone = true
                try microphone.start(deviceID: selectedMicrophoneID)
                try await microphone.recordAndPlayTest()
                microphone.stop()
                isTestingMicrophone = false
                await startPreviewMonitoring()
            } catch {
                microphone.stop()
                isTestingMicrophone = false
                microphonePermission = AVCaptureDevice.authorizationStatus(for: .audio)
                phase = .failed(error.localizedDescription)
                await startPreviewMonitoring()
            }
        }
    }

    func openArchive() {
        guard !archiveRootPath.isEmpty else { phase = .failed(AppConfigurationError.archiveRoot.localizedDescription); return }
        NSWorkspace.shared.open(URL(filePath: archiveRootPath, directoryHint: .isDirectory))
    }

    func deleteMediaKeepingMarkdown() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose meeting"
        if !archiveRootPath.isEmpty { panel.directoryURL = URL(filePath: archiveRootPath, directoryHint: .isDirectory) }
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.appending(path: "transcript.md").path),
              fileManager.fileExists(atPath: directory.appending(path: "summary.md").path)
        else {
            phase = .failed("Choose a completed meeting folder containing transcript.md and summary.md.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete recorded media?"
        alert.informativeText = "audio.m4a and screen.mov will be permanently deleted from \(directory.lastPathComponent). Markdown files will remain."
        alert.addButton(withTitle: "Delete media")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for name in ["audio.m4a", "screen.mov"] {
            let url = directory.appending(path: name)
            if fileManager.fileExists(atPath: url.path) { try? fileManager.removeItem(at: url) }
        }
    }

    func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    func retryFailedProcessing() {
        processingFailureCount = 0
        Task { await resumePendingSessions() }
    }

    private func startRecording() {
        Task {
            var startStore: ArchiveStore?
            do {
                let (store, key, model) = try configuration()
                startStore = store
                await stopPreviewMonitoring()
                let created = try store.createPendingSession(
                    videoEnabled: videoEnabled,
                    microphoneID: microphoneEnabled ? selectedMicrophoneID : nil
                )
                currentDirectory = created.0
                currentManifest = created.1
                try await capture.start(
                    audioOutputURL: created.0.appending(path: "capture.mov"),
                    screenOutputURL: videoEnabled ? created.0.appending(path: "screen.mov") : nil,
                    applicationBundleID: selectedSystemAudioBundleID,
                    microphoneID: selectedMicrophoneID,
                    microphoneEnabled: microphoneEnabled
                )
                _ = key
                _ = model
                systemAudioError = nil
                phase = .recording(startedAt: created.1.startedAt)
            } catch {
                if let directory = currentDirectory, var manifest = currentManifest, let startStore {
                    manifest.status = .failed
                    manifest.lastError = error.localizedDescription
                    try? startStore.write(manifest, to: directory)
                }
                currentDirectory = nil
                currentManifest = nil
                phase = .failed(error.localizedDescription)
                await startPreviewMonitoring()
            }
        }
    }

    private func stopRecording() {
        Task {
            do {
                try await capture.stop()
                guard let directory = currentDirectory, var manifest = currentManifest else { return }
                manifest.status = .captured
                let (store, key, model) = try configuration()
                try store.write(manifest, to: directory)
                currentDirectory = nil
                currentManifest = nil
                phase = .idle
                await startPreviewMonitoring()
                enqueue(ProcessingJob(directory: directory, manifest: manifest, store: store, key: key, model: model))
            } catch {
                phase = .failed(error.localizedDescription)
                await startPreviewMonitoring()
            }
        }
    }

    private func startPreviewMonitoring() async {
        guard isPanelOpen, !isRecording, !isTestingMicrophone else { return }

        if microphoneEnabled, microphonePermission == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            microphonePermission = AVCaptureDevice.authorizationStatus(for: .audio)
        }
        guard isPanelOpen, !isRecording, !isTestingMicrophone else { return }
        if microphoneEnabled, microphonePermission == .authorized, !microphones.isEmpty {
            do { try microphone.start(deviceID: selectedMicrophoneID) }
            catch { phase = .failed(error.localizedDescription) }
        }

        guard isPanelOpen, !isRecording, selectedSystemAudioIsAvailable else { return }
        do {
            try await capture.startPreview(applicationBundleID: selectedSystemAudioBundleID)
            if systemAudioError != nil { phase = .idle }
            systemAudioError = nil
        } catch {
            systemAudioError = error.localizedDescription
            phase = .failed(error.localizedDescription)
        }
    }

    private func stopPreviewMonitoring() async {
        microphone.stop()
        await capture.stopPreview()
    }

    private func restartSystemAudioPreview() async {
        await capture.stopPreview()
        guard isPanelOpen, !isRecording, selectedSystemAudioIsAvailable else { return }
        do {
            try await capture.startPreview(applicationBundleID: selectedSystemAudioBundleID)
            if systemAudioError != nil { phase = .idle }
            systemAudioError = nil
        } catch {
            systemAudioError = error.localizedDescription
            phase = .failed(error.localizedDescription)
        }
    }

    private func refreshApplications() async {
        do { applications = try await capture.availableApplications() }
        catch { systemAudioError = error.localizedDescription }
    }

    private func setMicrophoneLevel(_ value: Float) {
        microphoneLevel = max(value, microphoneLevel * 0.72)
    }

    private func setSystemAudioLevel(_ value: Float) {
        systemAudioLevel = max(value, systemAudioLevel * 0.72)
    }

    private func signalState(for level: Float) -> String {
        AudioLevelState(level: level).label
    }

    private func resumePendingSessions() async {
        guard !archiveRootPath.isEmpty,
              let key = try? KeychainStore().load(), !key.isEmpty
        else { return }
        let store = ArchiveStore(root: URL(filePath: archiveRootPath, directoryHint: .isDirectory))
        guard let sessions = try? store.pendingSessions() else { return }
        for (directory, manifest) in sessions where manifest.status != .recording || FileManager.default.fileExists(atPath: directory.appending(path: "capture.mov").path) {
            enqueue(ProcessingJob(
                directory: directory,
                manifest: manifest,
                store: store,
                key: key,
                model: selectedModelID
            ))
        }
    }

    private func enqueue(_ job: ProcessingJob) {
        let path = job.directory.path
        guard currentProcessingPath != path, !processingQueue.contains(where: { $0.directory.path == path }) else { return }
        processingQueue.append(job)
        startProcessingQueue()
    }

    private func startProcessingQueue() {
        guard processingTask == nil else { return }
        processingTask = Task { [weak self] in
            await self?.drainProcessingQueue()
        }
    }

    private func drainProcessingQueue() async {
        while !processingQueue.isEmpty {
            let job = processingQueue.removeFirst()
            currentProcessingPath = job.directory.path
            processingCount = processingQueue.count + 1
            do {
                let destination = try await process(job)
                if !isRecording { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
            } catch {
                if case OpenRouterError.authentication = error { keySaved = false }
                processingFailureCount += 1
                processingText = error.localizedDescription
            }
            currentProcessingPath = nil
        }
        processingCount = 0
        if processingFailureCount == 0 { processingText = nil }
        processingTask = nil
    }

    private func process(_ job: ProcessingJob) async throws -> URL {
        processingText = "Preparing"
        let processor = MeetingProcessor(
            store: job.store,
            client: OpenRouterClient(apiKey: job.key, model: job.model)
        ) { [weak self] text in
            Task { @MainActor in self?.processingText = text }
        }
        return try await processor.process(directory: job.directory, manifest: job.manifest)
    }

    private func configuration() throws -> (ArchiveStore, String, String) {
        guard !archiveRootPath.isEmpty else { throw AppConfigurationError.archiveRoot }
        guard !selectedModelID.isEmpty else { throw AppConfigurationError.model }
        let key = (try? KeychainStore().load()) ?? ""
        guard !key.isEmpty else { throw AppConfigurationError.apiKey }
        return (
            ArchiveStore(root: URL(filePath: archiveRootPath, directoryHint: .isDirectory)),
            key,
            selectedModelID
        )
    }

    private var canChangeArchive: Bool {
        guard !isRecording, !isProcessing else {
            phase = .failed("Wait for recording and processing to finish before changing the archive.")
            return false
        }
        let store = ArchiveStore(root: URL(filePath: archiveRootPath, directoryHint: .isDirectory))
        guard (try? store.pendingSessions().isEmpty) != false else {
            phase = .failed("Finish pending meetings before changing the archive.")
            return false
        }
        return true
    }

    private func setArchiveRoot(_ url: URL) {
        archiveRootPath = url.standardizedFileURL.path
        UserDefaults.standard.set(archiveRootPath, forKey: ArchiveStore.rootDefaultsKey)
        Task { await resumePendingSessions() }
    }

    private static let defaultArchiveURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/CloudStorage/Dropbox/Obsidian/meeting-log", directoryHint: .isDirectory)
}

private struct ProcessingJob {
    let directory: URL
    let manifest: SessionManifest
    let store: ArchiveStore
    let key: String
    let model: String
}

enum AppConfigurationError: LocalizedError {
    case archiveRoot
    case apiKey
    case model

    var errorDescription: String? {
        switch self {
        case .archiveRoot: "Choose an archive folder first."
        case .apiKey: "Save an OpenRouter API key first."
        case .model: "Choose an OpenRouter model first."
        }
    }
}
