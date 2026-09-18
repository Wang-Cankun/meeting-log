// Appended to AppModel.swift by check.sh so the check exercises private queue state
// without adding test hooks to the shipping app.
extension AppModel {
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
                                baseURL: "https://example.invalid", key: "", model: "test", projectName: nil)
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
