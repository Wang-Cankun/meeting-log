import AppKit
import AVFoundation
import Combine
import Foundation

@MainActor
final class AudioLevels: ObservableObject {
    @Published private(set) var microphone: Float = 0
    @Published private(set) var system: Float = 0

    func setMicrophone(_ value: Float) {
        microphone = max(value, microphone * 0.72)
    }

    func setSystem(_ value: Float) {
        system = max(value, system * 0.72)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var phase: AppPhase = .idle
    @Published var videoEnabled = false
    @Published var microphoneEnabled = UserDefaults.standard.object(forKey: "microphoneEnabled") as? Bool ?? false
    @Published var selectedMicrophoneID = UserDefaults.standard.string(forKey: "microphoneID")
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
    @Published private(set) var waitingForProcessingCount = 0
    @Published private(set) var isChangingRecording = false
    @Published private(set) var projects: [ProjectFolder] = []
    @Published private(set) var recentMeetings: [ArchivedMeeting] = []

    let capture = CaptureService()
    let microphone = MicrophoneCapture()
    let microphones = MicrophoneCapture.devices
    let audioLevels = AudioLevels()

    private var currentDirectory: URL?
    private var currentManifest: SessionManifest?
    private var processingQueue: [ProcessingJob] = []
    private var currentProcessingPath: String?
    private var processingTask: Task<Void, Never>?
    private var previewGeneration = 0
    private var isResumingPendingSessions = false
    private var pendingCaptureFailure: String?

    init() {
        keySaved = KeychainStore().containsKey()
        UserDefaults.standard.set(archiveRootPath, forKey: ArchiveStore.rootDefaultsKey)
        try? FileManager.default.createDirectory(
            at: URL(filePath: archiveRootPath, directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        refreshArchive()
        capture.onScreenSelection = { [weak self] source in
            self?.selectedScreenSource = source
        }
        capture.onError = { [weak self] message in self?.handleCaptureError(message) }
        microphone.onLevel = { [weak self] value in
            Task { @MainActor in self?.audioLevels.setMicrophone(value) }
        }
        capture.onSystemAudioLevel = { [weak self] in self?.audioLevels.setSystem($0) }
        Task {
            refreshApplications()
            await resumePendingSessions()
        }
    }

    var isRecording: Bool {
        if case .recording = phase { true } else { false }
    }

    var isProcessing: Bool { processingCount > 0 }

    var hasScreenSource: Bool { selectedScreenSource != nil }

    var canStartRecording: Bool {
        guard !isRecording, !isChangingRecording, !archiveRootPath.isEmpty else { return false }
        guard systemAudioError == nil else { return false }
        if selectedSystemAudioBundleID != nil, !selectedSystemAudioIsAvailable { return false }
        return !videoEnabled || hasScreenSource
    }

    var statusText: String {
        switch phase {
        case .idle:
            if videoEnabled, !hasScreenSource { return "Choose a screen source" }
            if selectedSystemAudioBundleID != nil, !selectedSystemAudioIsAvailable { return "Audio application unavailable" }
            return "Ready to record"
        case .recording: return "Recording"
        case let .failed(value): return value
        }
    }

    var microphoneStateText: String {
        if !microphoneEnabled { return "Not included" }
        if microphones.isEmpty { return "No microphone found" }
        if microphonePermission == .denied || microphonePermission == .restricted { return "Permission required, not included" }
        if isRecording { return "Recording" }
        if !isPanelOpen { return "Preview paused" }
        return AudioLevelState(level: audioLevels.microphone).label
    }

    var systemAudioStateText: String {
        if selectedSystemAudioBundleID != nil, !selectedSystemAudioIsAvailable { return "Application unavailable" }
        if systemAudioError != nil { return "Unavailable" }
        if isRecording { return "Recording" }
        if !isPanelOpen { return "Preview paused" }
        return AudioLevelState(level: audioLevels.system).label
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
        schedulePreviewStart()
    }

    func setMicrophoneEnabled(_ enabled: Bool) {
        microphoneEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "microphoneEnabled")
        if enabled {
            schedulePreviewStart()
        } else {
            schedulePreviewStop()
        }
    }

    func selectSystemAudio(_ application: CaptureApplication?) {
        selectedSystemAudioBundleID = application?.bundleIdentifier
        selectedSystemAudioName = application?.name ?? "All Mac audio"
        schedulePreviewRestart()
    }

    func setVideoEnabled(_ enabled: Bool) {
        videoEnabled = enabled
    }

    func chooseScreen() {
        capture.chooseScreen()
    }

    func openSystemAudioPrivacy() {
        openPrivacySettings(anchor: "Privacy_AudioCapture")
    }

    func openMicrophonePrivacy() {
        openPrivacySettings(anchor: "Privacy_Microphone")
    }

    func panelDidOpen() {
        isPanelOpen = true
        refreshArchive()
        refreshApplications()
        schedulePreviewStart()
    }

    func panelDidClose() {
        isPanelOpen = false
        guard !isRecording else { return }
        schedulePreviewStop()
    }

    func settingsDidOpen() {
        refreshArchive()
        loadModels()
    }

    func showArchiveInFinder() {
        showInFinder(URL(filePath: archiveRootPath, directoryHint: .isDirectory))
    }

    func showInFinder(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            showError("The folder no longer exists.")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func createProject() {
        guard canManageArchive else { return }
        let alert = NSAlert()
        alert.messageText = "New Project"
        alert.informativeText = "Enter the folder name MeetingLog should use."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Project name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            _ = try recordingStore().createProject(named: field.stringValue)
            refreshArchive()
        } catch {
            showError(error.localizedDescription)
        }
    }

    func deleteMeeting(_ meeting: ArchivedMeeting) {
        guard canManageArchive else { return }
        let alert = NSAlert()
        alert.messageText = "Move meeting to Trash?"
        alert.informativeText = "\(meeting.title)\nProject: \(meeting.projectName)\n\(meeting.url.path)"
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: meeting.url, resultingItemURL: nil)
            refreshArchive()
        } catch {
            showError("The meeting was not deleted: \(error.localizedDescription)")
        }
    }

    func toggleRecording() {
        guard let action = phase.recordingAction(isBusy: isChangingRecording) else { return }
        isChangingRecording = true
        switch action {
        case .start: startRecording()
        case .stop: stopRecording()
        }
    }

    func retryFailedProcessing() {
        processingFailureCount = 0
        Task { await resumePendingSessions() }
    }

    private func startRecording() {
        let generation = nextPreviewGeneration()
        Task {
            var startStore: ArchiveStore?
            do {
                pendingCaptureFailure = nil
                let store = try recordingStore()
                startStore = store
                await stopPreviewMonitoring(generation: generation)
                let recordsMicrophone = microphoneEnabled
                    && microphonePermission == .authorized
                    && !microphones.isEmpty
                let created = try store.createPendingSession(
                    videoEnabled: videoEnabled,
                    microphoneID: recordsMicrophone ? selectedMicrophoneID : nil
                )
                currentDirectory = created.0
                currentManifest = created.1
                if recordsMicrophone {
                    try await microphone.startRecording(
                        to: created.0.appending(path: "microphone.m4a"),
                        deviceID: selectedMicrophoneID
                    )
                }
                try await capture.start(
                    systemAudioOutputURL: created.0.appending(path: "system-audio.caf"),
                    screenOutputURL: videoEnabled ? created.0.appending(path: "screen.mov") : nil,
                    applicationBundleID: selectedSystemAudioBundleID
                )
                if let pendingCaptureFailure { throw CaptureError.recordingFailed(pendingCaptureFailure) }
                systemAudioError = nil
                phase = .recording(startedAt: Date())
                isChangingRecording = false
            } catch {
                try? await capture.stop()
                try? await microphone.stopRecording()
                if let directory = currentDirectory, var manifest = currentManifest, let startStore {
                    manifest.status = .failed
                    manifest.lastError = error.localizedDescription
                    try? startStore.write(manifest, to: directory)
                }
                currentDirectory = nil
                currentManifest = nil
                pendingCaptureFailure = nil
                phase = .failed(error.localizedDescription)
                isChangingRecording = false
                schedulePreviewStart()
            }
        }
    }

    private func stopRecording(failure initialFailure: String? = nil) {
        let stoppedAt = Date()
        let recordingStartedAt: Date? = if case let .recording(startedAt) = phase { startedAt } else { nil }
        Task {
            var failure = initialFailure ?? pendingCaptureFailure
            pendingCaptureFailure = nil
            do { try await capture.stop() }
            catch { failure = failure ?? error.localizedDescription }
            do { try await microphone.stopRecording() }
            catch { failure = failure ?? error.localizedDescription }

            guard let directory = currentDirectory, var manifest = currentManifest else {
                isChangingRecording = false
                if let failure { phase = .failed(failure) }
                return
            }

            if let failure {
                manifest.status = .failed
                manifest.lastError = failure
                if let store = try? recordingStore() { try? store.write(manifest, to: directory) }
                currentDirectory = nil
                currentManifest = nil
                phase = .failed(failure)
                isChangingRecording = false
                schedulePreviewStart()
                return
            }

            if let recordingStartedAt,
               !RecordingDurationPolicy.shouldProcess(startedAt: recordingStartedAt, stoppedAt: stoppedAt) {
                do {
                    try recordingStore().discardPendingSession(id: manifest.id)
                    currentDirectory = nil
                    currentManifest = nil
                    phase = .idle
                } catch {
                    phase = .failed(error.localizedDescription)
                }
                isChangingRecording = false
                schedulePreviewStart()
                return
            }

            do {
                let microphoneURL = directory.appending(path: "microphone.m4a")
                try await MediaProcessor().makeCaptureMovie(
                    systemAudio: directory.appending(path: "system-audio.caf"),
                    microphone: FileManager.default.fileExists(atPath: microphoneURL.path) ? microphoneURL : nil,
                    destination: directory.appending(path: "capture.mov")
                )
                manifest.status = .captured
                let store = try recordingStore()
                try store.write(manifest, to: directory)
                currentDirectory = nil
                currentManifest = nil
                phase = .idle
                isChangingRecording = false
                schedulePreviewStart()
                await resumePendingSessions()
            } catch {
                manifest.status = .failed
                manifest.lastError = error.localizedDescription
                if let store = try? recordingStore() { try? store.write(manifest, to: directory) }
                currentDirectory = nil
                currentManifest = nil
                processingFailureCount += 1
                phase = .failed(error.localizedDescription)
                isChangingRecording = false
                schedulePreviewStart()
            }
        }
    }

    private func startPreviewMonitoring(generation: Int) async {
        guard generation == previewGeneration, isPanelOpen, !isRecording else { return }

        if microphoneEnabled, microphonePermission == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            microphonePermission = AVCaptureDevice.authorizationStatus(for: .audio)
        }
        guard generation == previewGeneration, isPanelOpen, !isRecording else { return }
        if microphoneEnabled, microphonePermission == .authorized, !microphones.isEmpty {
            do {
                try await microphone.setPreview(
                    enabled: true,
                    deviceID: selectedMicrophoneID,
                    generation: generation
                )
            }
            catch { phase = .failed(error.localizedDescription) }
        }

        guard generation == previewGeneration, isPanelOpen, !isRecording, selectedSystemAudioIsAvailable else { return }
        do {
            try await capture.startPreview(applicationBundleID: selectedSystemAudioBundleID)
            if systemAudioError != nil { phase = .idle }
            systemAudioError = nil
        } catch {
            systemAudioError = error.localizedDescription
            phase = .failed(error.localizedDescription)
        }
    }

    private func stopPreviewMonitoring(generation: Int) async {
        capture.stopPreview()
        try? await microphone.setPreview(enabled: false, deviceID: nil, generation: generation)
    }

    private func schedulePreviewStart() {
        let generation = nextPreviewGeneration()
        Task { [weak self] in
            await self?.startPreviewMonitoring(generation: generation)
        }
    }

    private func schedulePreviewStop() {
        let generation = nextPreviewGeneration()
        capture.stopPreview()
        Task { [weak self] in
            try? await self?.microphone.setPreview(enabled: false, deviceID: nil, generation: generation)
        }
    }

    private func schedulePreviewRestart() {
        capture.stopPreview()
        schedulePreviewStart()
    }

    private func nextPreviewGeneration() -> Int {
        previewGeneration += 1
        return previewGeneration
    }

    private func refreshApplications() {
        applications = SystemAudioCapture.applications()
        if selectedSystemAudioBundleID != nil, !selectedSystemAudioIsAvailable {
            selectedSystemAudioBundleID = nil
            selectedSystemAudioName = "All Mac audio"
        }
    }

    private func resumePendingSessions() async {
        guard !archiveRootPath.isEmpty,
              !isRecording,
              !isChangingRecording,
              !isResumingPendingSessions
        else { return }
        isResumingPendingSessions = true
        defer { isResumingPendingSessions = false }
        let store = ArchiveStore(root: URL(filePath: archiveRootPath, directoryHint: .isDirectory))
        guard let sessions = try? store.pendingSessions() else { return }
        var recoverable: [(URL, SessionManifest)] = []
        for (directory, originalManifest) in sessions {
            guard directory != currentDirectory else { continue }
            var manifest = originalManifest
            guard let input = MediaProcessor.pendingInput(in: directory) else { continue }
            if case let .raw(systemAudio, microphone) = input {
                do {
                    try await MediaProcessor().makeCaptureMovie(
                        systemAudio: systemAudio,
                        microphone: microphone,
                        destination: directory.appending(path: "capture.mov")
                    )
                } catch {
                    if microphone != nil {
                        try? await MediaProcessor().makeCaptureMovie(
                            systemAudio: systemAudio,
                            microphone: nil,
                            destination: directory.appending(path: "capture.mov")
                        )
                    }
                }
                guard FileManager.default.fileExists(atPath: directory.appending(path: "capture.mov").path) else {
                    continue
                }
                manifest.status = .captured
                manifest.lastError = nil
                try? store.write(manifest, to: directory)
            }
            recoverable.append((directory, manifest))
        }
        waitingForProcessingCount = recoverable.count
        guard let key = try? KeychainStore().load(), !key.isEmpty, !selectedModelID.isEmpty else { return }
        for (directory, manifest) in recoverable {
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
                waitingForProcessingCount = max(0, waitingForProcessingCount - 1)
                refreshArchive()
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

    private func recordingStore() throws -> ArchiveStore {
        guard !archiveRootPath.isEmpty else { throw AppConfigurationError.archiveRoot }
        return ArchiveStore(root: URL(filePath: archiveRootPath, directoryHint: .isDirectory))
    }

    private func handleCaptureError(_ message: String) {
        guard currentDirectory != nil else {
            phase = .failed(message)
            return
        }
        pendingCaptureFailure = message
        guard !isChangingRecording else { return }
        isChangingRecording = true
        stopRecording(failure: message)
    }

    private var canChangeArchive: Bool {
        guard !isRecording, !isChangingRecording, !isProcessing else {
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
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            archiveRootPath = url.standardizedFileURL.path
            UserDefaults.standard.set(archiveRootPath, forKey: ArchiveStore.rootDefaultsKey)
            refreshArchive()
            Task { await resumePendingSessions() }
        } catch {
            showError("The archive folder could not be used: \(error.localizedDescription)")
        }
    }

    private func refreshArchive() {
        guard let store = try? recordingStore() else {
            projects = []
            recentMeetings = []
            return
        }
        projects = (try? store.projects()) ?? []
        recentMeetings = (try? store.recentMeetings()) ?? []
    }

    private var canManageArchive: Bool {
        guard !isRecording, !isChangingRecording, !isProcessing else {
            showError("Wait for recording and processing to finish.")
            return false
        }
        return true
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "MeetingLog"
        alert.informativeText = message
        alert.runModal()
    }

    private func openPrivacySettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
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

    var errorDescription: String? {
        switch self {
        case .archiveRoot: "Choose an archive folder first."
        case .apiKey: "Save an OpenRouter API key first."
        }
    }
}
