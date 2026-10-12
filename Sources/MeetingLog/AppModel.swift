import AppKit
import AVFoundation
import Combine
import Foundation
import UserNotifications

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

/// Mix export progress lives outside `AppModel` so frequent updates do not redraw the menu bar label.
@MainActor
final class SavingProgress: ObservableObject {
    /// Export fraction in 0...1 while mixing; nil when unknown or not mixing.
    @Published var fraction: Double?
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var isImporting = false
    @Published var phase: AppPhase = .idle
    @Published var videoEnabled = false
    @Published var microphoneEnabled = UserDefaults.standard.object(forKey: "microphoneEnabled") as? Bool ?? false
    @Published var selectedMicrophoneID = UserDefaults.standard.string(forKey: "microphoneID")
    @Published var providerBaseURL = UserDefaults.standard.string(forKey: "providerBaseURL") ?? "https://openrouter.ai/api/v1"
    @Published var apiKey = UserDefaults.standard.string(forKey: "providerAPIKey") ?? ""
    @Published var keySaved = false
    @Published var configurationStatus: String?
    @Published var isVerifyingConfiguration = false
    @Published var selectedModelID = UserDefaults.standard.string(forKey: "providerModel") ?? ""
    @Published var speechEndpoint = UserDefaults.standard.string(forKey: "speechEndpoint") ?? ""
    @Published var speechKey = UserDefaults.standard.string(forKey: "speechAPIKey") ?? ""
    @Published var summariesEnabled = UserDefaults.standard.object(forKey: "summariesEnabled") as? Bool ?? true
    @Published var archiveRootPath = UserDefaults.standard.string(forKey: ArchiveStore.rootDefaultsKey) ?? AppModel.defaultArchiveURL.path
    @Published var applications: [CaptureApplication] = []
    @Published var selectedSystemAudioBundleID: String?
    @Published var selectedSystemAudioName = "All Mac audio"
    @Published var selectedScreenSource: String?
    @Published var microphonePermission = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published var systemAudioError: String?
    @Published private(set) var isPanelOpen = false
    /// Stage and readable detail of the meeting being processed; nil when nothing is processing.
    @Published private(set) var processingProgress: ProcessingProgress?
    /// Pending sessions for the Recent list, ordered processing, queued, failed, waiting, needs retry.
    @Published private(set) var pendingItems: [PendingMeetingItem] = []
    /// Fixed project path for the recording in progress or being saved.
    @Published private(set) var recordingDestinationPath: String?
    @Published private(set) var recordingIncludesMicrophone = false
    @Published private(set) var recordingMicrophoneName: String?
    /// Inline warning while an included microphone has delivered no input for 30 s.
    @Published private(set) var microphoneSilenceWarning: String?
    @Published private(set) var processingCount = 0
    @Published private(set) var processingFailureCount = 0
    @Published private(set) var waitingForProcessingCount = 0
    @Published private(set) var pendingFailureText: String?
    @Published private(set) var isChangingRecording = false
    @Published private(set) var projects: [ProjectFolder] = []
    @Published var meetingToMove: ArchivedMeeting?
    @Published var summaryLockedURLs: Set<URL> = []
    @Published var lastMeetingMove: MeetingMove?
    @Published var summaryOpenRequest: SummaryOpenRequest?
    @Published private(set) var recentMeetings: [ArchivedMeeting] = []
    @Published var selectedProjectName = UserDefaults.standard.string(forKey: AppModel.projectDefaultsKey)
    /// Feedback shown inside the menu bar panel, where modal alerts would detach from the panel.
    @Published private(set) var notice: PanelNotice?
    @Published private(set) var missingProjectRetry: MissingProjectRetry?

    let capture = CaptureService()
    let microphone = MicrophoneCapture()
    let microphones = MicrophoneCapture.devices
    let audioLevels = AudioLevels()
    let savingProgress = SavingProgress()

    private var currentDirectory: URL?
    private var currentManifest: SessionManifest?
    private var processingQueue: [ProcessingJob] = []
    private var currentProcessingPath: String?
    private var processingTask: Task<Void, Never>?
    private var previewGeneration = 0
    private var isResumingPendingSessions = false
    private var pendingCaptureFailure: String?
    /// Fallback failure text per pending path when the processor could not persist its failure.
    private var processingErrors: [String: String] = [:]
    private var silenceMonitor = MicrophoneSilenceMonitor()
    private(set) var silenceEpisodeCount = 0
    private(set) var silenceNotificationCount = 0

    private static let projectDefaultsKey = "selectedProjectName"
    /// False only for the debug renderers: nothing previews, enumerates sources or rereads the archive.
    private let startsServices: Bool

    /// `startsServices` is false only for the debug window renderer, which reads the archive without
    /// persisting settings, creating folders, enumerating capture sources or resuming pending sessions.
    init(startsServices: Bool = true) {
        self.startsServices = startsServices
        keySaved = !apiKey.isEmpty
        if startsServices {
            UserDefaults.standard.set(archiveRootPath, forKey: ArchiveStore.rootDefaultsKey)
            try? FileManager.default.createDirectory(
                at: URL(filePath: archiveRootPath, directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
        }
        refreshArchive()
        capture.onScreenSelection = { [weak self] source in
            self?.selectedScreenSource = source
        }
        capture.onError = { [weak self] message in self?.handleCaptureError(message) }
        microphone.onLevel = { [weak self] value in
            Task { @MainActor in self?.audioLevels.setMicrophone(value) }
        }
        microphone.onSignal = { [weak self] decibels, time in
            Task { @MainActor in self?.observeMicrophoneSignal(decibels, at: time) }
        }
        capture.onSystemAudioLevel = { [weak self] in self?.audioLevels.setSystem($0) }
        guard startsServices else { return }
        Task {
            refreshApplications()
            await resumePendingSessions()
        }
    }

    var isRecording: Bool {
        if case .recording = phase { true } else { false }
    }

    var isSaving: Bool {
        if case .saving = phase { true } else { false }
    }

    /// Recording or saving: sources stay locked and previews stay off.
    var isCaptureBusy: Bool { isRecording || isSaving }

    var isProcessing: Bool { processingCount > 0 }

    /// The saved configuration can process recordings: a summary model when AI summaries are on, otherwise Azure Speech.
    var providerReady: Bool {
        guard !isVerifyingConfiguration else { return false }
        return summariesEnabled ? keySaved && !selectedModelID.isEmpty : speechTranscriber != nil
    }

    /// Off means MeetingLog never contacts a language model, including Regenerate with a key saved earlier.
    var canGenerateSummaries: Bool {
        summariesEnabled && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasScreenSource: Bool { selectedScreenSource != nil }

    var canSelectRecordingProject: Bool { !isRecording && !isChangingRecording }

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
        case .saving: return "Saving recording"
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

    var pendingMeetingsExist: Bool {
        guard let store = try? recordingStore() else { return false }
        return (try? store.hasPendingSessions()) ?? true
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

    /// Saves only after every selected service passes. With AI summaries off, only Azure Speech is tested and saved;
    /// the saved summary provider stays as it was for when summaries are turned back on.
    func testProcessingConfiguration(baseURL: String, modelID: String, key: String,
                                     useSpeech: Bool, speechEndpoint: String, speechKey: String,
                                     summaries: Bool = true) async {
        guard !isVerifyingConfiguration, !isRecording, !isChangingRecording, !isProcessing, !isImporting else { return }
        // Without a summary model, Azure Speech is the only service that can transcribe.
        let useSpeech = useSpeech || !summaries
        let baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = useSpeech ? speechEndpoint.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let speechKey = useSpeech ? speechKey.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        guard !summaries || (!baseURL.isEmpty && !modelID.isEmpty && !key.isEmpty) else {
            configurationStatus = "Complete the AI provider URL, model, and API key."
            return
        }
        guard !useSpeech || (!endpoint.isEmpty && !speechKey.isEmpty) else {
            configurationStatus = summaries
                ? "Complete the Azure Speech endpoint and key, or choose AI provider for transcription."
                : "Complete the Azure Speech endpoint and key."
            return
        }
        isVerifyingConfiguration = true
        defer { isVerifyingConfiguration = false }
        var service = "AI provider"
        do {
            if summaries {
                configurationStatus = "Testing AI provider…"
                try await ProviderClient(baseURL: baseURL, apiKey: key, model: modelID).verifyConfiguration(includingAudio: !useSpeech)
            }
            if useSpeech {
                service = "Azure Speech"
                configurationStatus = "Testing Azure Speech…"
                try await SpeechTranscriber(endpoint: endpoint, apiKey: speechKey).verifyConfiguration()
            }
            // Commit every service before pending jobs can snapshot the configuration.
            if summaries {
                providerBaseURL = baseURL
                selectedModelID = modelID
                apiKey = key
                saveProviderConfiguration()
            }
            self.speechEndpoint = endpoint
            self.speechKey = speechKey
            summariesEnabled = summaries
            UserDefaults.standard.set(endpoint, forKey: "speechEndpoint")
            UserDefaults.standard.set(speechKey, forKey: "speechAPIKey")
            UserDefaults.standard.set(summaries, forKey: "summariesEnabled")
            configurationStatus = "Connected"
            isVerifyingConfiguration = false
            await resumePendingSessions()
        } catch {
            configurationStatus = "\(service): \(error.localizedDescription) Configuration was not changed."
        }
    }

    /// Optional speech service; without it the provider model transcribes audio.
    var speechTranscriber: SpeechTranscriber? {
        speechEndpoint.isEmpty || speechKey.isEmpty ? nil : SpeechTranscriber(endpoint: speechEndpoint, apiKey: speechKey)
    }

    func removeProviderConfiguration() {
        guard !isVerifyingConfiguration, !isRecording, !isChangingRecording, !isProcessing, !isImporting else { return }
        providerBaseURL = "https://openrouter.ai/api/v1"
        selectedModelID = ""
        apiKey = ""
        speechEndpoint = ""
        speechKey = ""
        summariesEnabled = true
        keySaved = false
        configurationStatus = nil
        for key in ["providerName", "providerBaseURL", "providerModel", "providerAPIKey", "speechEndpoint", "speechAPIKey",
                    "summariesEnabled"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        refreshPendingStatus()
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

    func selectProject(_ name: String?) {
        guard canSelectRecordingProject else { return }
        selectedProjectName = name
        if let name {
            UserDefaults.standard.set(name, forKey: Self.projectDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.projectDefaultsKey)
        }
    }

    func selectSystemAudio(_ application: CaptureApplication?) {
        guard !isRecording, !isChangingRecording else { return }
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
        guard startsServices else { return }
        refreshArchive()
        refreshApplications()
        schedulePreviewStart()
    }

    func panelDidClose() {
        isPanelOpen = false
        guard startsServices, !isCaptureBusy else { return }
        schedulePreviewStop()
    }

    func settingsDidOpen() {
        refreshArchive()
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

    func createProject(named name: String) throws {
        let project = try recordingStore().createProject(named: name)
        selectProject(project.name)
        refreshArchive()
    }

    func discardPendingMeetings() {
        guard canManageArchive, let store = try? recordingStore() else { return }
        let sessions = (try? store.pendingSessions()) ?? []
        guard !sessions.isEmpty else { return }
        do {
            for (directory, _) in sessions {
                try FileManager.default.trashItem(at: directory, resultingItemURL: nil)
            }
        } catch {
            showError("Pending meetings were not discarded: \(error.localizedDescription)")
        }
        refreshArchive()
    }

    var pendingMeetingCount: Int {
        guard let store = try? recordingStore() else { return 0 }
        return ((try? store.pendingSessions()) ?? []).count
    }

    func canMoveMeeting(_ meeting: ArchivedMeeting) -> Bool {
        !isRecording && !isChangingRecording && !isProcessing && !isImporting
            && !summaryLockedURLs.contains(meeting.url)
    }

    func moveMeeting(_ meeting: ArchivedMeeting, to project: String) throws -> ArchivedMeeting {
        guard canMoveMeeting(meeting) else {
            throw NSError(domain: "MeetingLog", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "Finish recording, processing, or reviewing this meeting’s summary before moving it."])
        }
        let moved = try recordingStore().moveMeeting(meeting, to: project)
        refreshArchive()
        lastMeetingMove = MeetingMove(source: meeting.url, destination: moved.url)
        return moved
    }

    func deleteMeeting(_ meeting: ArchivedMeeting) {
        guard canManageArchive else { return }
        do {
            var trashed: NSURL?
            try FileManager.default.trashItem(at: meeting.url, resultingItemURL: &trashed)
            refreshArchive()
            let original = meeting.url
            notice = PanelNotice(message: "Moved “\(meeting.title)” to Trash.", undo: trashed.map { trashed in
                { [weak self] in self?.restoreFromTrash(trashed as URL, to: original) }
            })
        } catch {
            showError("The meeting was not deleted: \(error.localizedDescription)")
        }
    }

    private func restoreFromTrash(_ trashed: URL, to original: URL) {
        notice = nil
        do {
            guard !FileManager.default.fileExists(atPath: original.path) else {
                throw CocoaError(.fileWriteFileExists)
            }
            try FileManager.default.moveItem(at: trashed, to: original)
            refreshArchive()
        } catch {
            showError("The meeting could not be restored. It remains in the Trash. \(error.localizedDescription)")
        }
    }

    func dismissNotice() {
        notice = nil
    }

    func toggleRecording() {
        guard let action = phase.recordingAction(isBusy: isChangingRecording) else { return }
        phase = phase.clearingFailure
        isChangingRecording = true
        switch action {
        case .start: startRecording()
        case .stop: stopRecording()
        }
    }

    var canRetryProcessing: Bool {
        !isRecording && !isChangingRecording && !isImporting && !isResumingPendingSessions
            && processingTask == nil && currentProcessingPath == nil && processingQueue.isEmpty
    }

    var showsRecoveryActions: Bool {
        processingFailureCount > 0 || (waitingForProcessingCount > 0 && !isProcessing)
    }

    func retryFailedProcessing() {
        guard canRetryProcessing else { return }
        do {
            let store = try recordingStore()
            let pending = try store.pendingSessions()
            let missing = pending.filter { _, manifest in
                guard let name = manifest.projectName else { return false }
                return (try? store.resolveProject(name)) == nil
            }
            if !missing.isEmpty {
                let replacement = try store.resolveProject(selectedProjectName)
                missingProjectRetry = MissingProjectRetry(count: missing.count, projectName: replacement.name,
                                                          displayPath: replacement.displayPath)
                return
            }
        } catch { showError(error.localizedDescription); return }
        missingProjectRetry = nil
        processingFailureCount = 0
        Task { await resumePendingSessions() }
    }

    /// Pending meetings whose project disappeared are only reassigned after explicit confirmation.
    func confirmMissingProjectRetry() {
        guard let request = missingProjectRetry, canRetryProcessing else { return }
        missingProjectRetry = nil
        do {
            let store = try recordingStore()
            for (directory, original) in try store.pendingSessions() {
                guard let name = original.projectName, (try? store.resolveProject(name)) == nil else { continue }
                var manifest = original
                manifest.projectName = request.projectName
                try store.write(manifest, to: directory)
            }
        } catch { showError(error.localizedDescription); return }
        retryFailedProcessing()
    }

    func cancelMissingProjectRetry() {
        missingProjectRetry = nil
    }

    func showPendingMeetingsInFinder() {
        showInFinder(URL(filePath: archiveRootPath).appending(path: ".pending"))
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
                refreshApplications()
                guard selectedSystemAudioIsAvailable else {
                    throw CaptureError.recordingFailed("The selected audio application is unavailable. Reopen it or choose another source.")
                }
                let recordsMicrophone = microphoneEnabled
                    && microphonePermission == .authorized
                    && !microphones.isEmpty
                let destination = try store.resolveProject(selectedProjectName)
                recordingDestinationPath = destination.displayPath
                var created = try store.createPendingSession(
                    videoEnabled: videoEnabled,
                    microphoneID: recordsMicrophone ? selectedMicrophoneID : nil
                )
                created.1.projectName = destination.name
                try store.write(created.1, to: created.0)
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
                recordingIncludesMicrophone = recordsMicrophone
                recordingMicrophoneName = recordsMicrophone ? currentMicrophoneName : nil
                resetMicrophoneSilence()
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
                endRecordingSession()
                phase = .failed(error.localizedDescription)
                isChangingRecording = false
                refreshPendingStatus()
                schedulePreviewStart()
            }
        }
    }

    private var currentMicrophoneName: String {
        microphones.first { $0.uniqueID == selectedMicrophoneID }?.localizedName
            ?? AVCaptureDevice.default(for: .audio)?.localizedName
            ?? "the microphone"
    }

    private func resetMicrophoneSilence() {
        silenceMonitor.reset()
        microphoneSilenceWarning = nil
    }

    /// Clears per-recording presentation state at every exit from recording or saving.
    private func endRecordingSession() {
        resetMicrophoneSilence()
        recordingIncludesMicrophone = false
        recordingMicrophoneName = nil
        recordingDestinationPath = nil
        savingProgress.fraction = nil
    }

    private func observeMicrophoneSignal(_ decibels: Float?, at uptimeNanoseconds: UInt64) {
        guard isRecording, recordingIncludesMicrophone else { return }
        switch silenceMonitor.observe(decibels: decibels, at: uptimeNanoseconds) {
        case .none: break
        case .began:
            let warning = "No input from \(recordingMicrophoneName ?? "the microphone") for 30 s. Check the selected microphone."
            microphoneSilenceWarning = warning
            silenceEpisodeCount += 1
            if silenceMonitor.shouldNotify(at: uptimeNanoseconds) {
                silenceNotificationCount += 1
                MeetingNotifications.post(title: "Microphone has no input", body: warning + " Recording continues.", folder: nil)
            }
        case .ended:
            microphoneSilenceWarning = nil
        }
    }

    /// The saving panel promises a notification, so outcomes reached with the panel closed post one.
    private func notifyIfPanelClosed(title: String, body: String) {
        guard !isPanelOpen else { return }
        MeetingNotifications.post(title: title, body: body, folder: nil)
    }

    /// Late export callbacks are ignored once saving has moved past mixing.
    private func reportMixProgress(_ fraction: Double) {
        guard case .saving(_, .mixingAudio) = phase else { return }
        savingProgress.fraction = fraction
    }

    private func setSavingStep(_ step: SavingStep) {
        guard case let .saving(duration, _) = phase else { return }
        phase = .saving(duration: duration, step: step)
    }

    private func stopRecording(failure initialFailure: String? = nil) {
        let stoppedAt = Date()
        let recordingStartedAt: Date? = if case let .recording(startedAt) = phase { startedAt } else { nil }
        if let recordingStartedAt {
            phase = .saving(duration: max(0, stoppedAt.timeIntervalSince(recordingStartedAt)), step: .stoppingTracks)
        }
        resetMicrophoneSilence()
        recordingIncludesMicrophone = false
        savingProgress.fraction = nil
        Task {
            var failure = initialFailure ?? pendingCaptureFailure
            pendingCaptureFailure = nil
            do { try await capture.stop() }
            catch { failure = failure ?? error.localizedDescription }
            do { try await microphone.stopRecording() }
            catch { failure = failure ?? error.localizedDescription }

            guard let directory = currentDirectory, var manifest = currentManifest else {
                endRecordingSession()
                phase = failure.map(AppPhase.failed) ?? .idle
                isChangingRecording = false
                if let failure { notifyIfPanelClosed(title: "Recording needs attention", body: failure) }
                return
            }

            if let failure {
                manifest.status = .failed
                manifest.lastError = failure
                if let store = try? recordingStore() { try? store.write(manifest, to: directory) }
                currentDirectory = nil
                currentManifest = nil
                endRecordingSession()
                phase = .failed(failure)
                isChangingRecording = false
                refreshPendingStatus()
                schedulePreviewStart()
                notifyIfPanelClosed(title: "Recording needs attention",
                                    body: "The recording is saved locally. \(failure)")
                return
            }

            if let recordingStartedAt,
               !RecordingDurationPolicy.shouldProcess(startedAt: recordingStartedAt, stoppedAt: stoppedAt) {
                endRecordingSession()
                do {
                    try recordingStore().discardPendingSession(id: manifest.id)
                    currentDirectory = nil
                    currentManifest = nil
                    phase = .idle
                    notice = PanelNotice(message: "Recordings shorter than 10 seconds are discarded.")
                    notifyIfPanelClosed(title: "Recording discarded", body: "Recordings shorter than 10 seconds are discarded.")
                } catch {
                    phase = .failed(error.localizedDescription)
                    notifyIfPanelClosed(title: "Recording needs attention", body: error.localizedDescription)
                }
                isChangingRecording = false
                schedulePreviewStart()
                return
            }

            setSavingStep(.mixingAudio)
            savingProgress.fraction = nil
            do {
                _ = try await CapturePreparation.prepare(in: directory) { fraction in
                    Task { @MainActor in self.reportMixProgress(fraction) }
                }
                manifest.status = .captured
                let store = try recordingStore()
                try store.write(manifest, to: directory)
                setSavingStep(.handingOff)
                currentDirectory = nil
                currentManifest = nil
                endRecordingSession()
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
                endRecordingSession()
                phase = .failed(error.localizedDescription)
                isChangingRecording = false
                refreshPendingStatus()
                schedulePreviewStart()
                notifyIfPanelClosed(title: "Recording needs attention",
                                    body: "The recording is saved locally. \(error.localizedDescription)")
            }
        }
    }

    private func startPreviewMonitoring(generation: Int) async {
        guard generation == previewGeneration, isPanelOpen, !isCaptureBusy else { return }

        if microphoneEnabled, microphonePermission == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            microphonePermission = AVCaptureDevice.authorizationStatus(for: .audio)
        }
        guard generation == previewGeneration, isPanelOpen, !isCaptureBusy else { return }
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

        guard generation == previewGeneration, isPanelOpen, !isCaptureBusy, selectedSystemAudioIsAvailable else { return }
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
    }

    func importAudio(_ urls: [URL], date: Date, projectName: String?) async throws {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        let store = try recordingStore()
        let destination = try store.resolveProject(projectName)
        let (directory, manifest) = try await AudioImport.stage(
            urls, date: date, projectName: destination.name, store: store
        )
        waitingForProcessingCount += 1
        if providerReady {
            enqueue(ProcessingJob(directory: directory, manifest: manifest, store: store,
                                  baseURL: providerBaseURL, key: apiKey, model: selectedModelID,
                                  speech: speechTranscriber, summaries: summariesEnabled, projectName: manifest.projectName))
        }
    }

    private func resumePendingSessions() async {
        guard !archiveRootPath.isEmpty,
              !isRecording,
              !isChangingRecording,
              !isResumingPendingSessions
        else { return }
        isResumingPendingSessions = true
        defer { isResumingPendingSessions = false; refreshPendingStatus() }
        let store = ArchiveStore(root: URL(filePath: archiveRootPath, directoryHint: .isDirectory))
        guard let sessions = try? store.pendingSessions() else { return }
        var recoverable: [(URL, SessionManifest)] = []
        for (directory, originalManifest) in sessions {
            guard directory != currentDirectory, directory.path != currentProcessingPath,
                  !processingQueue.contains(where: { $0.directory == directory }) else { continue }
            var manifest = originalManifest
            guard let input = MediaProcessor.pendingInput(in: directory) else {
                manifest.status = .failed
                manifest.lastError = "No usable audio was found. Open the saved files to inspect this recording."
                try? store.write(manifest, to: directory)
                continue
            }
            let needsCapturePreparation: Bool
            switch input {
            case .raw: needsCapturePreparation = true
            case let .combined(url): needsCapturePreparation = url.lastPathComponent == "capture.mov"
            case .importedParts: needsCapturePreparation = false
            }
            if needsCapturePreparation {
                do {
                    _ = try await CapturePreparation.prepare(in: directory)
                    manifest.status = .captured
                    manifest.lastError = nil
                    try store.write(manifest, to: directory)
                } catch {
                    manifest.status = .failed
                    manifest.lastError = error.localizedDescription
                    try? store.write(manifest, to: directory)
                    continue
                }
            }
            recoverable.append((directory, manifest))
        }
        waitingForProcessingCount = recoverable.count
        guard providerReady else { return }
        for (directory, manifest) in recoverable {
            enqueue(ProcessingJob(
                directory: directory,
                manifest: manifest,
                store: store,
                baseURL: providerBaseURL,
                key: apiKey,
                model: selectedModelID,
                speech: speechTranscriber,
                summaries: summariesEnabled,
                projectName: manifest.projectName ?? selectedProjectName
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
            processingErrors[job.directory.path] = nil
            processingCount = processingQueue.count + 1
            refreshPendingStatus()
            do {
                let destination = try await process(job)
                waitingForProcessingCount = max(0, waitingForProcessingCount - 1)
                refreshArchive()
                let title = recentMeetings.first { $0.url.standardizedFileURL == destination.standardizedFileURL }?.title
                MeetingNotifications.post(title: "Meeting ready", body: title ?? destination.lastPathComponent, folder: destination)
            } catch {
                if case ProviderError.authentication = error {
                    keySaved = false
                    configurationStatus = "AI provider: \(error.localizedDescription) Update it in Settings."
                }
                if case SpeechError.authentication = error {
                    configurationStatus = error.localizedDescription
                }
                processingErrors[job.directory.path] = error.localizedDescription
                MeetingNotifications.post(title: "Processing needs attention",
                                          body: "The recording is saved locally. \(error.localizedDescription)", folder: nil)
            }
            currentProcessingPath = nil
            processingProgress = nil
            refreshPendingStatus()
        }
        processingCount = 0
        refreshPendingStatus()
        processingTask = nil
    }

    private func process(_ job: ProcessingJob) async throws -> URL {
        let path = job.directory.path
        processingProgress = ProcessingProgress(stage: .prepare, detail: "Preparing")
        let processor = MeetingProcessor(
            store: job.store,
            client: job.summaries ? ProviderClient(baseURL: job.baseURL, apiKey: job.key, model: job.model) : nil,
            speech: job.speech
        ) { [weak self] progress in
            Task { @MainActor in
                // A late callback from a finished job must not overwrite the next job.
                guard let self, self.currentProcessingPath == path else { return }
                self.processingProgress = progress
            }
        }
        return try await processor.process(directory: job.directory, manifest: job.manifest, projectName: job.projectName)
    }

    private func recordingStore() throws -> ArchiveStore {
        guard !archiveRootPath.isEmpty else { throw AppConfigurationError.archiveRoot }
        return ArchiveStore(root: URL(filePath: archiveRootPath, directoryHint: .isDirectory))
    }

    private func saveProviderConfiguration() {
        UserDefaults.standard.set(providerBaseURL, forKey: "providerBaseURL")
        UserDefaults.standard.set(selectedModelID, forKey: "providerModel")
        UserDefaults.standard.set(apiKey, forKey: "providerAPIKey")
        keySaved = true
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
        guard !isRecording, !isChangingRecording, !isProcessing, !isImporting else {
            showError("Wait for recording and processing to finish before changing the archive.")
            return false
        }
        let store = ArchiveStore(root: URL(filePath: archiveRootPath, directoryHint: .isDirectory))
        guard (try? store.hasPendingSessions()) == false else {
            showError("Finish or discard pending meetings before changing the archive.")
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

    func refreshArchive() {
        guard let store = try? recordingStore() else {
            projects = []
            recentMeetings = []
            return
        }
        projects = (try? store.projects()) ?? []
        recentMeetings = (try? store.recentMeetings()) ?? []
        refreshPendingStatus()
    }

    private func refreshPendingStatus() {
        guard let store = try? recordingStore(), let sessions = try? store.pendingSessions() else { return }
        let pending = sessions.filter { $0.0 != currentDirectory }.map { directory, original in
            // Keep a failure visible even when the processor could not write it to the manifest.
            var manifest = original
            if manifest.status != .failed, let error = processingErrors[directory.path] {
                manifest.status = .failed
                manifest.lastError = error
            }
            return (directory, manifest)
        }
        waitingForProcessingCount = pending.count
        let queuedPaths = Set(processingQueue.map { $0.directory.path })
        let busyPaths = queuedPaths.union([currentProcessingPath].compactMap { $0 })
        let failures = pending.filter { $0.1.status == .failed && !busyPaths.contains($0.0.path) }
        processingFailureCount = failures.count
        pendingFailureText = failures.first?.1.lastError
        pendingItems = PendingMeetingItem.sorted(pending.map { directory, manifest in
            PendingMeetingItem(directory: directory, manifest: manifest, state: PendingMeetingItem.state(
                for: manifest, path: directory.path, processingPath: currentProcessingPath,
                queuedPaths: queuedPaths, providerReady: providerReady))
        })
        processingErrors = processingErrors.filter { path, _ in pending.contains { $0.0.path == path } }
    }

    private var canManageArchive: Bool {
        guard !isRecording, !isChangingRecording, !isProcessing, !isImporting else {
            showError("Wait for recording and processing to finish.")
            return false
        }
        return true
    }

    /// The panel shows errors inline; standalone windows keep a standard alert.
    private func showError(_ message: String) {
        if isPanelOpen {
            notice = PanelNotice(message: message, isError: true)
            return
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
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
        .appending(path: "Documents/MeetingLog", directoryHint: .isDirectory)
}

private struct ProcessingJob {
    let directory: URL
    let manifest: SessionManifest
    let store: ArchiveStore
    let baseURL: String
    let key: String
    let model: String
    var speech: SpeechTranscriber? = nil
    /// Snapshotted at enqueue time like the other settings; false archives transcripts only.
    /// Required, so no enqueue path can fall back to sending transcripts to a provider.
    let summaries: Bool
    let projectName: String?
}

enum AppConfigurationError: LocalizedError {
    case archiveRoot
    case apiKey

    var errorDescription: String? {
        switch self {
        case .archiveRoot: "Choose an archive folder first."
        case .apiKey: "Save an API provider configuration first."
        }
    }
}

struct PanelNotice: Identifiable {
    let id = UUID()
    let message: String
    var isError = false
    var undo: (() -> Void)? = nil
}

struct MissingProjectRetry: Equatable {
    let count: Int
    let projectName: String
    let displayPath: String
}

/// Completion replaces the former automatic Finder reveal; clicking a notification reveals the meeting.
@MainActor
enum MeetingNotifications {
    private static let delegate = Delegate()

    static func post(title: String, body: String, folder: URL?) {
        // Unbundled check executables have no notification identity.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let folder { content.userInfo = ["folder": folder.path] }
        Task {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
            -> UNNotificationPresentationOptions { [.banner, .sound] }

        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
            guard let path = response.notification.request.content.userInfo["folder"] as? String else { return }
            await MainActor.run {
                if FileManager.default.fileExists(atPath: path) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
                }
            }
        }
    }
}

struct MeetingMove: Equatable {
    let source: URL
    let destination: URL
}

#if DEBUG
/// Debug renderer only: injects fixture state that normally comes from capture, processing and the archive.
extension AudioLevels {
    func debugSet(system: Float, microphone: Float) {
        self.system = system
        self.microphone = microphone
    }
}

extension AppModel {
    func debugSetPanelState(
        projects: [ProjectFolder],
        recentMeetings: [ArchivedMeeting],
        pendingItems: [PendingMeetingItem] = [],
        processingProgress: ProcessingProgress? = nil,
        recordingDestinationPath: String? = nil,
        recordingMicrophoneName: String? = nil,
        microphoneSilenceWarning: String? = nil
    ) {
        self.projects = projects
        self.recentMeetings = recentMeetings
        self.pendingItems = pendingItems
        self.processingProgress = processingProgress
        self.processingCount = processingProgress == nil ? 0 : 1
        self.recordingDestinationPath = recordingDestinationPath
        self.recordingIncludesMicrophone = recordingMicrophoneName != nil
        self.recordingMicrophoneName = recordingMicrophoneName
        self.microphoneSilenceWarning = microphoneSilenceWarning
    }
}
#endif
