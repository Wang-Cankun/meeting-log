// Appended to AppModel.swift by check.sh so the check exercises private queue state
// without adding test hooks to the shipping app.
extension AppModel {
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
        model.retryFailedProcessing()
        precondition(model.processingFailureCount == 0, "Idle retry must remain available")
        print("AppModel retry passed: queued, active, recovery, import, and idle states")
    }
}
