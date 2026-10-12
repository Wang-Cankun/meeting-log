// Appended to AppModel.swift by check.sh so the check exercises private queue state
// without adding test hooks to the shipping app.
extension AppModel {
    @MainActor static func checkSettingsConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "settings-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        let saved = defaults.persistentDomain(forName: domain) ?? [:]
        defer {
            defaults.setPersistentDomain(saved, forName: domain)
            defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        }
        for (key, value) in [
            ArchiveStore.rootDefaultsKey: root.path, "providerAPIKey": "", "providerModel": "",
            "speechEndpoint": "", "speechAPIKey": ""
        ] { defaults.set(value, forKey: key) }
        let model = AppModel(startsServices: false)
        precondition(!model.providerReady)
        let restoreSessions = SettingsFixture.interceptDefaultSessions()
        defer { restoreSessions() }
        SettingsFixture.state.withLock { $0 = .init(rejectSpeech: true) }

        await model.testProcessingConfiguration(baseURL: "https://settings.invalid/v1", modelID: "text-only", key: "fixture",
                                                useSpeech: true, speechEndpoint: "https://settings.invalid", speechKey: "fixture")
        precondition(!model.providerReady && model.apiKey.isEmpty && model.speechTranscriber == nil,
                     "A failed speech test must not partially save or enable the text provider")
        precondition(model.configurationStatus?.contains("Azure Speech") == true, model.configurationStatus ?? "Missing status")
        precondition(SettingsFixture.state.withLock { $0.requests } == ["text", "speech"])

        SettingsFixture.state.withLock { $0.rejectSpeech = false }
        await model.testProcessingConfiguration(baseURL: " https://settings.invalid/v1 ", modelID: " text-only ", key: " fixture ",
                                                useSpeech: true, speechEndpoint: " https://settings.invalid ", speechKey: " fixture ")
        precondition(model.providerReady && model.speechTranscriber != nil && model.configurationStatus == "Connected")
        precondition(defaults.string(forKey: "providerModel") == "text-only" && defaults.string(forKey: "speechAPIKey") == "fixture",
                     "Both saved services must survive reloading")
        let reloaded = AppModel(startsServices: false)
        precondition(reloaded.selectedModelID == "text-only" && reloaded.speechTranscriber?.apiKey == "fixture",
                     "A new app instance must load both saved services")

        let store = ArchiveStore(root: root)
        let (directory, manifest) = try store.createPendingSession(videoEnabled: false, microphoneID: nil)
        let silence = root.appending(path: "silence.flac")
        try MediaProcessor.encodeSilence(seconds: 2, destination: silence)
        try MediaProcessor.encodeSpeech(source: silence, destination: directory.appending(path: "original.m4a"))
        SettingsFixture.state.withLock { $0.rejectSpeech = true }
        await model.resumePendingSessions()
        await model.processingTask?.value
        precondition(model.keySaved && model.providerReady, "Speech authentication must not invalidate the summary provider")
        precondition(model.configurationStatus?.contains("Azure Speech") == true, model.configurationStatus ?? "Missing status")
        precondition(FileManager.default.fileExists(atPath: directory.appending(path: "original.m4a").path))
        let failed = try store.pendingSessions()
        precondition(failed.first?.1.id == manifest.id && failed.first?.1.status == .failed)

        SettingsFixture.state.withLock { $0.rejectSpeech = false }
        await model.testProcessingConfiguration(baseURL: model.providerBaseURL, modelID: model.selectedModelID, key: model.apiKey,
                                                useSpeech: true, speechEndpoint: model.speechEndpoint, speechKey: "repaired")
        await model.processingTask?.value
        let remaining = try store.pendingSessions()
        let completed = try store.recentMeetings()
        precondition(remaining.isEmpty && completed.count == 1, "Saving a repaired service must resume the failed recording: \(model.pendingFailureText ?? "")")
        precondition(FileManager.default.fileExists(atPath: completed[0].url.appending(path: "summary_cn.md").path))
        precondition(!SettingsFixture.state.withLock { $0.requests.contains("audio") }, "MAI mode must never upload audio to the text provider")

        await model.testProcessingConfiguration(baseURL: model.providerBaseURL, modelID: "text-only", key: model.apiKey,
                                                useSpeech: false, speechEndpoint: "", speechKey: "")
        precondition(model.configurationStatus?.contains("Audio input test failed") == true)
        precondition(model.speechTranscriber?.apiKey == "repaired" && defaults.string(forKey: "speechAPIKey") == "repaired",
                     "An unsupported audio model must preserve the working configuration")
        let (longDirectory, _) = try store.createPendingSession(videoEnabled: false, microphoneID: nil)
        try MediaProcessor.encodeSilence(seconds: 601, destination: silence)
        try MediaProcessor.encodeSpeech(source: silence, destination: longDirectory.appending(path: "original.m4a"))
        SettingsFixture.state.withLock { $0.rejectSpeech = true }
        await model.resumePendingSessions()
        await model.processingTask?.value
        SettingsFixture.state.withLock { $0.rejectSpeech = false }
        await model.testProcessingConfiguration(baseURL: model.providerBaseURL, modelID: "audio-model", key: model.apiKey,
                                                useSpeech: false, speechEndpoint: "", speechKey: "")
        await model.processingTask?.value
        let switchedPending = try store.pendingSessions()
        let switchedMeetings = try store.recentMeetings()
        precondition(switchedPending.isEmpty && switchedMeetings.count == 2,
                     "Switching from a whole-file speech request to audio windows must recover without deleting files: \(model.pendingFailureText ?? "")")
        precondition(model.configurationStatus == "Connected" && model.providerReady && model.speechTranscriber == nil)
        precondition(defaults.string(forKey: "speechAPIKey") == "")
        model.removeProviderConfiguration()
        precondition(!model.providerReady && model.speechTranscriber == nil && defaults.string(forKey: "providerAPIKey") == nil)
        print("Settings passed: all-or-nothing save, reload, MAI routing, authentication recovery, audio capability, switch and removal")
    }

    @MainActor static func checkTranscriptOnlySettings() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "transcript-only-settings-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        let saved = defaults.persistentDomain(forName: domain) ?? [:]
        defer {
            defaults.setPersistentDomain(saved, forName: domain)
            defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        }
        for (key, value) in [
            ArchiveStore.rootDefaultsKey: root.path, "providerAPIKey": "", "providerModel": "",
            "speechEndpoint": "", "speechAPIKey": ""
        ] { defaults.set(value, forKey: key) }
        // Pending recordings without a project fall back to the selected one, which may be left over from another check.
        for key in ["summariesEnabled", "selectedProjectName"] { defaults.removeObject(forKey: key) }
        let model = AppModel(startsServices: false)
        precondition(model.summariesEnabled && !model.providerReady, "AI summaries stay on by default")
        let restoreSessions = SettingsFixture.interceptDefaultSessions()
        defer { restoreSessions() }
        func requests() -> [String] { SettingsFixture.state.withLock { $0.requests } }

        // A failed speech test changes nothing, including the switch. A stale `useSpeech: false` still means Azure Speech.
        SettingsFixture.state.withLock { $0 = .init(rejectSpeech: true) }
        await model.testProcessingConfiguration(baseURL: "", modelID: "", key: "", useSpeech: false,
                                                speechEndpoint: "https://settings.invalid", speechKey: "fixture", summaries: false)
        precondition(model.summariesEnabled && !model.providerReady && model.speechTranscriber == nil)
        precondition(model.configurationStatus?.contains("Azure Speech") == true, model.configurationStatus ?? "Missing status")
        precondition(requests() == ["speech"], "\(requests())")

        SettingsFixture.state.withLock { $0 = .init() }
        await model.testProcessingConfiguration(baseURL: "", modelID: "", key: "", useSpeech: false,
                                                speechEndpoint: " https://settings.invalid ", speechKey: " fixture ", summaries: false)
        precondition(model.configurationStatus == "Connected" && model.providerReady && !model.summariesEnabled,
                     model.configurationStatus ?? "Missing status")
        precondition(requests() == ["speech"], "Transcript-only setup must not contact an AI provider: \(requests())")
        precondition(!model.canGenerateSummaries)
        let reloaded = AppModel(startsServices: false)
        precondition(!reloaded.summariesEnabled && reloaded.providerReady && reloaded.speechTranscriber?.apiKey == "fixture",
                     "The switch and Azure Speech must survive reloading")

        let store = ArchiveStore(root: root)
        let (directory, manifest) = try store.createPendingSession(videoEnabled: false, microphoneID: nil)
        let silence = root.appending(path: "silence.flac")
        try MediaProcessor.encodeSilence(seconds: 2, destination: silence)
        try MediaProcessor.encodeSpeech(source: silence, destination: directory.appending(path: "original.m4a"))
        final class ProgressLog { var values: [ProcessingProgress] = [] }
        let progressLog = ProgressLog()
        let progressWatch = model.$processingProgress.sink { if let value = $0 { progressLog.values.append(value) } }
        await model.resumePendingSessions()
        await model.processingTask?.value
        progressWatch.cancel()
        precondition(!progressLog.values.isEmpty && progressLog.values.allSatisfy { !$0.summaries },
                     "The panel must draw a transcript-only job's bar without summary stages")
        let pending = try store.pendingSessions()
        let meetings = try store.recentMeetings()
        precondition(pending.isEmpty && meetings.count == 1, model.pendingFailureText ?? "Missing meeting")
        let expected = "\(ArchiveStore.timestamp.string(from: manifest.startedAt))-\(ArchiveStore.transcriptOnlyTitle(for: manifest))"
        precondition(!meetings[0].hasSummary && meetings[0].url.lastPathComponent == expected, meetings[0].url.lastPathComponent)
        for name in ["audio.m4a", "transcript_raw.md", "transcript.md"] {
            precondition(FileManager.default.fileExists(atPath: meetings[0].url.appending(path: name).path), "Missing \(name)")
        }
        precondition(!FileManager.default.fileExists(atPath: meetings[0].url.appending(path: "summary.md").path))
        precondition(requests().allSatisfy { $0 == "speech" }, "Transcript-only processing must not contact an AI provider: \(requests())")

        // Turning summaries back on tests and saves the provider as before.
        SettingsFixture.state.withLock { $0 = .init() }
        await model.testProcessingConfiguration(baseURL: "https://settings.invalid/v1", modelID: "text-only", key: "fixture",
                                                useSpeech: true, speechEndpoint: model.speechEndpoint, speechKey: model.speechKey)
        precondition(model.summariesEnabled && model.providerReady && model.canGenerateSummaries && requests() == ["text", "speech"])

        // Turning them off again ignores leftover provider fields and keeps the saved provider.
        SettingsFixture.state.withLock { $0 = .init() }
        await model.testProcessingConfiguration(baseURL: "https://other.invalid/v1", modelID: "ignored-model", key: "other",
                                                useSpeech: true, speechEndpoint: model.speechEndpoint, speechKey: model.speechKey,
                                                summaries: false)
        precondition(!model.summariesEnabled && requests() == ["speech"], "\(requests())")
        precondition(model.selectedModelID == "text-only" && defaults.string(forKey: "providerModel") == "text-only"
                     && model.apiKey == "fixture", "Hidden provider fields must not replace the saved provider")
        precondition(!model.canGenerateSummaries, "A saved key must not enable summaries while they are off")

        // An import processed while a provider key is still saved must not reach that provider either.
        SettingsFixture.state.withLock { $0 = .init() }
        let source = root.appending(path: "Team sync.m4a")
        try MediaProcessor.encodeSpeech(source: silence, destination: source)
        try await model.importAudio([source], date: manifest.startedAt, projectName: nil)
        await model.processingTask?.value
        let imported = try store.recentMeetings().first { $0.url.lastPathComponent.hasSuffix("-Team sync") }
        precondition(imported.map { !$0.hasSummary } == true, model.pendingFailureText ?? "Missing imported meeting")
        precondition(requests().allSatisfy { $0 == "speech" } && !requests().isEmpty,
                     "Imports must not contact a saved provider while summaries are off: \(requests())")

        model.removeProviderConfiguration()
        precondition(model.summariesEnabled && defaults.object(forKey: "summariesEnabled") == nil && !model.providerReady)
        print("Transcript-only settings passed: speech-only save, stale fields ignored, no AI requests, reload, switch back, removal")
    }

    @MainActor static func checkCaptureRecoveryPresentation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "capture-state-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        UserDefaults.standard.setVolatileDomain([
            ArchiveStore.rootDefaultsKey: root.path, "providerAPIKey": ""
        ], forName: UserDefaults.argumentDomain)
        let model = AppModel()
        let store = ArchiveStore(root: root)
        _ = try store.createProject(named: "A")
        _ = try store.createProject(named: "B")
        model.selectProject("A")
        model.selectedSystemAudioBundleID = "invalid.meetinglog.missing-application"
        model.selectedSystemAudioName = "Missing meeting app"
        model.refreshApplications()
        precondition(model.selectedSystemAudioBundleID != nil && model.selectedSystemAudioName == "Missing meeting app")
        precondition(!model.canStartRecording, "Missing application must never become global audio")

        let (directory, manifest) = try store.createPendingSession(videoEnabled: false, microphoneID: nil)
        try Data("preserve incomplete audio".utf8).write(to: directory.appending(path: "system-audio.caf"))
        model.currentDirectory = directory
        model.currentManifest = manifest
        model.phase = .recording(startedAt: Date())
        model.selectProject("B")
        model.selectSystemAudio(nil)
        precondition(model.selectedProjectName == "A" && model.selectedSystemAudioBundleID != nil)
        model.isChangingRecording = true
        model.stopRecording(failure: "Injected capture write failure")
        while model.isChangingRecording { await Task.yield() }
        precondition(model.processingFailureCount == 1 && model.waitingForProcessingCount == 1)
        precondition(model.pendingFailureText == "Injected capture write failure" && model.canRetryProcessing)
        precondition(FileManager.default.fileExists(atPath: directory.appending(path: "system-audio.caf").path))
        let failed = try store.pendingSessions()
        precondition(failed[0].1.status == .failed)
        model.refreshArchive()
        precondition(model.processingFailureCount == 1, "Panel refresh must retain Retry for persisted failure")

        // A disk/permission failure can also prevent updating the manifest's failure status.
        try store.write(manifest, to: directory)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        model.currentDirectory = directory
        model.currentManifest = manifest
        model.phase = .recording(startedAt: Date())
        model.isChangingRecording = true
        model.stopRecording(failure: "Capture and manifest writes failed")
        while model.isChangingRecording { await Task.yield() }
        let unwritten = try store.pendingSessions()
        precondition(unwritten[0].1.status == .recording)
        precondition(model.showsRecoveryActions && model.canRetryProcessing,
                     "Failed manifest writes must not hide recovery actions")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        model.phase = .idle
        model.isChangingRecording = true
        model.selectProject("B")
        precondition(model.selectedProjectName == "A", "Start/stop transitions must lock project selection")
        model.isChangingRecording = false
        model.selectProject("B")
        precondition(model.selectedProjectName == "B")
        // A direct start request must also reject an unavailable source before creating a new session.
        model.toggleRecording()
        while model.isChangingRecording { await Task.yield() }
        precondition(!model.isRecording && model.selectedSystemAudioBundleID != nil)
        let remaining = try store.pendingSessions()
        precondition(remaining.count == 1)
        print("Capture state passed: unavailable source, locked project, immediate recovery actions and retained files")
    }

    @MainActor static func checkSavingPhase() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "saving-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        UserDefaults.standard.setVolatileDomain([
            ArchiveStore.rootDefaultsKey: root.path, "providerAPIKey": ""
        ], forName: UserDefaults.argumentDomain)
        let model = AppModel()
        let store = ArchiveStore(root: root)

        // Stop enters saving synchronously: frozen duration, no recording symbol, no second toggle.
        let (short, shortManifest) = try store.createPendingSession(videoEnabled: false, microphoneID: nil)
        try Data("unreadable fixture".utf8).write(to: short.appending(path: "system-audio.caf"))
        model.currentDirectory = short
        model.currentManifest = shortManifest
        model.recordingDestinationPath = "Inbox"
        model.phase = .recording(startedAt: Date())
        model.toggleRecording()
        guard case let .saving(shortDuration, .stoppingTracks) = model.phase, shortDuration < 10 else {
            preconditionFailure("Stop must enter saving immediately: \(model.phase)")
        }
        model.toggleRecording()
        precondition(model.phase == .saving(duration: shortDuration, step: .stoppingTracks), "Saving ignores toggles")
        precondition(model.isSaving && model.isCaptureBusy && !model.isRecording && model.statusText == "Saving recording")
        precondition(StatusItemPresentation(phase: model.phase).systemImage != "record.circle.fill")
        precondition(model.recordingDestinationPath == "Inbox", "Saving keeps showing the destination")
        while model.isChangingRecording { await Task.yield() }
        precondition(model.phase == .idle && !FileManager.default.fileExists(atPath: short.path),
                     "Recordings under 10 seconds are still discarded")
        precondition(model.notice?.isError == false && model.recordingDestinationPath == nil)

        // A failed mix leaves the session and its raw track in place for Retry.
        let (long, longManifest) = try store.createPendingSession(videoEnabled: false, microphoneID: nil)
        let longTrack = long.appending(path: "system-audio.caf")
        try Data("unreadable fixture".utf8).write(to: longTrack)
        model.currentDirectory = long
        model.currentManifest = longManifest
        model.recordingDestinationPath = "Inbox"
        model.phase = .recording(startedAt: Date().addingTimeInterval(-20))
        model.toggleRecording()
        var steps: [SavingStep] = []
        while model.isChangingRecording {
            if case let .saving(duration, step) = model.phase {
                precondition(duration >= 20, "The saving timer is frozen at the final duration")
                if steps.last != step { steps.append(step) }
            }
            await Task.yield()
        }
        precondition(steps == [.stoppingTracks, .mixingAudio], "\(steps)")
        guard case .failed = model.phase else { preconditionFailure("Failed mix must fail: \(model.phase)") }
        precondition(FileManager.default.fileExists(atPath: longTrack.path), "Raw media survives a failed save")
        precondition(model.savingProgress.fraction == nil && model.recordingDestinationPath == nil)
        precondition(model.pendingItems.count == 1 && model.pendingItems[0].id.standardizedFileURL.path == long.standardizedFileURL.path, "\(model.pendingItems) \(long)")
        guard case .failed = model.pendingItems[0].state else { preconditionFailure("\(model.pendingItems)") }

        // A late export fraction after mixing never reaches the saving card.
        model.phase = .saving(duration: 30, step: .handingOff)
        model.reportMixProgress(0.5)
        precondition(model.savingProgress.fraction == nil, "Late mix progress after hand-off is ignored")
        model.phase = .saving(duration: 30, step: .mixingAudio)
        model.reportMixProgress(0.25)
        precondition(model.savingProgress.fraction == 0.25)
        model.savingProgress.fraction = nil

        // Previews stay off while saving, even when the panel opens or closes.
        model.phase = .saving(duration: 30, step: .mixingAudio)
        model.isPanelOpen = true
        let errorBefore = model.systemAudioError
        await model.startPreviewMonitoring(generation: model.previewGeneration)
        precondition(model.phase == .saving(duration: 30, step: .mixingAudio) && model.systemAudioError == errorBefore,
                     "Preview must not start while saving")
        model.panelDidClose()
        model.phase = .idle
        print("Saving phase passed: frozen timer, locked toggle, static symbol, discard, retained media, previews off")
    }

    @MainActor static func checkMicrophoneSilence() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "silence-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        UserDefaults.standard.setVolatileDomain([
            ArchiveStore.rootDefaultsKey: root.path, "providerAPIKey": ""
        ], forName: UserDefaults.argumentDomain)
        let model = AppModel()
        let second: UInt64 = 1_000_000_000
        let start = 10 * second
        model.phase = .recording(startedAt: Date())
        model.recordingIncludesMicrophone = true
        model.recordingMicrophoneName = "Test Mic"
        model.observeMicrophoneSignal(-120, at: start)
        model.observeMicrophoneSignal(-120, at: start + 29_900_000_000)
        precondition(model.microphoneSilenceWarning == nil)
        model.observeMicrophoneSignal(-120, at: start + 30 * second)
        let warning = model.microphoneSilenceWarning ?? ""
        precondition(warning.contains("Test Mic") && warning.contains("30 s") && !warning.contains("muted"), warning)
        precondition(model.silenceEpisodeCount == 1 && model.silenceNotificationCount == 1)
        model.observeMicrophoneSignal(-120, at: start + 60 * second)
        precondition(model.silenceEpisodeCount == 1, "One warning per episode")
        model.observeMicrophoneSignal(-40, at: start + 61 * second)
        model.observeMicrophoneSignal(-120, at: start + 61 * second + second / 10)
        precondition(model.microphoneSilenceWarning != nil, "A blip does not clear the warning")
        model.observeMicrophoneSignal(-50, at: start + 62 * second)
        model.observeMicrophoneSignal(-50, at: start + 64 * second)
        precondition(model.microphoneSilenceWarning == nil, "Sustained input clears the warning")
        model.observeMicrophoneSignal(-120, at: start + 65 * second)
        model.observeMicrophoneSignal(-120, at: start + 95 * second)
        precondition(model.silenceEpisodeCount == 2 && model.microphoneSilenceWarning != nil)
        precondition(model.silenceNotificationCount == 1, "Notifications are spaced within a recording")
        model.observeMicrophoneSignal(-75, at: start + 96 * second)
        model.observeMicrophoneSignal(-75, at: start + 400 * second)
        precondition(model.microphoneSilenceWarning == nil && model.silenceEpisodeCount == 2, "A quiet room never warns")

        model.recordingIncludesMicrophone = false
        model.observeMicrophoneSignal(-120, at: start + 500 * second)
        model.observeMicrophoneSignal(-120, at: start + 600 * second)
        precondition(model.silenceEpisodeCount == 2, "An excluded microphone never warns")
        model.recordingIncludesMicrophone = true
        model.observeMicrophoneSignal(-120, at: start + 700 * second)
        model.observeMicrophoneSignal(-120, at: start + 730 * second)
        precondition(model.silenceEpisodeCount == 3 && model.microphoneSilenceWarning != nil)
        precondition(model.silenceNotificationCount == 2, "A later episode notifies again")

        model.isChangingRecording = true
        model.stopRecording()
        precondition(model.microphoneSilenceWarning == nil && !model.recordingIncludesMicrophone, "Stop clears the warning")
        while model.isChangingRecording { await Task.yield() }
        precondition(model.phase == .idle && model.recordingMicrophoneName == nil)
        model.observeMicrophoneSignal(-120, at: start + 800 * second)
        model.observeMicrophoneSignal(-120, at: start + 900 * second)
        precondition(model.microphoneSilenceWarning == nil && model.silenceEpisodeCount == 3, "Idle readings are ignored")
        print("Microphone silence passed: 30 s floor, blip hysteresis, spaced notifications, quiet room, excluded mic, stop and idle")
    }

    @MainActor static func checkRetryWhileBusy() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "retry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        UserDefaults.standard.setVolatileDomain([
            ArchiveStore.rootDefaultsKey: root.path,
            "providerAPIKey": ""
        ], forName: UserDefaults.argumentDomain)
        let model = AppModel()
        let store = ArchiveStore(root: root)
        let (directory, manifest) = try store.createPendingSession(videoEnabled: false, microphoneID: nil)
        let original = try Data(contentsOf: directory.appending(path: "session.json"))
        let job = ProcessingJob(directory: directory, manifest: manifest, store: store,
                                baseURL: "https://example.invalid", key: "", model: "test", summaries: true, projectName: nil)
        func expectBlocked(_ label: String) throws {
            model.processingFailureCount = 7
            model.retryFailedProcessing()
            precondition(model.processingFailureCount == 7, "Retry must wait for \(label)")
            let actual = try Data(contentsOf: directory.appending(path: "session.json"))
            precondition(actual == original, "Busy retry changed a manifest")
        }
        model.processingQueue = [job]
        try expectBlocked("queued work")
        model.processingQueue = []
        model.currentProcessingPath = directory.path
        try expectBlocked("active work")
        model.currentProcessingPath = nil
        model.isResumingPendingSessions = true
        try expectBlocked("recovery")
        model.isResumingPendingSessions = false
        model.isImporting = true
        try expectBlocked("import")
        model.isImporting = false
        let meeting = ArchivedMeeting(title: "Fixture", projectName: "Inbox", dateText: "", date: Date(), createdAt: Date(), url: directory)
        precondition(model.canMoveMeeting(meeting))
        model.summaryLockedURLs.insert(directory)
        precondition(!model.canMoveMeeting(meeting), "Unsaved summary must block moving")
        do { _ = try model.moveMeeting(meeting, to: "Inbox"); preconditionFailure("Locked move accepted") } catch {}
        model.summaryLockedURLs.remove(directory)
        model.isImporting = true
        precondition(!model.canMoveMeeting(meeting))
        model.isImporting = false
        model.retryFailedProcessing()
        precondition(model.processingFailureCount == 0, "Idle retry must remain available")
        print("AppModel retry passed: queued, active, recovery, import, and idle states")
    }
}
