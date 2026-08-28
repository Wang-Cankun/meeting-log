import Foundation

struct ArchiveStore {
    static let rootDefaultsKey = "archiveRoot"

    let root: URL
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    func createPendingSession(videoEnabled: Bool, microphoneID: String?) throws -> (URL, SessionManifest) {
        let manifest = SessionManifest(
            id: UUID(),
            startedAt: Date(),
            status: .recording,
            videoEnabled: videoEnabled,
            microphoneID: microphoneID,
            lastError: nil
        )
        let directory = root.appending(path: ".pending/\(manifest.id.uuidString.lowercased())", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try write(manifest, to: directory)
        return (directory, manifest)
    }

    func write(_ manifest: SessionManifest, to directory: URL) throws {
        try encoder.encode(manifest).write(to: directory.appending(path: "session.json"), options: .atomic)
    }

    func discardPendingSession(id: UUID) throws {
        let directory = root.appending(path: ".pending/\(id.uuidString.lowercased())", directoryHint: .isDirectory)
        try fileManager.removeItem(at: directory)
    }

    func pendingSessions() throws -> [(URL, SessionManifest)] {
        let pending = root.appending(path: ".pending", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: pending.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: pending,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).compactMap { directory in
            let data = try? Data(contentsOf: directory.appending(path: "session.json"))
            guard let data, let manifest = try? JSONDecoder.iso8601.decode(SessionManifest.self, from: data) else {
                return nil
            }
            return (directory, manifest)
        }
    }

    func projectContexts() throws -> [ProjectContext] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).compactMap { directory in
            let values = try? directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { return nil }
            let contextURL = directory.appending(path: "context.md")
            let markdown = (try? String(contentsOf: contextURL, encoding: .utf8)) ?? ""
            return ProjectContext(slug: directory.lastPathComponent, markdown: markdown)
        }
    }

    func globalContext() throws -> String {
        let url = root.appending(path: "context.md")
        if !fileManager.fileExists(atPath: url.path) {
            try "# Meeting context\n\nAdd frequent names, projects, and jargon here.\n".write(to: url, atomically: true, encoding: .utf8)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func finalDirectory(for analysis: MeetingAnalysis, startedAt: Date) throws -> URL {
        let project = Self.slug(analysis.projectSlug.isEmpty ? analysis.projectName : analysis.projectSlug)
        let title = Self.slug(analysis.title)
        let projectDirectory = root.appending(path: project, directoryHint: .isDirectory)
        let meetingsDirectory = projectDirectory.appending(path: "meetings", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: meetingsDirectory, withIntermediateDirectories: true)

        let context = projectDirectory.appending(path: "context.md")
        if !fileManager.fileExists(atPath: context.path) {
            try "# \(analysis.projectName)\n".write(to: context, atomically: true, encoding: .utf8)
        }

        let stamp = Self.timestamp.string(from: startedAt)
        var destination = meetingsDirectory.appending(path: "\(stamp)-\(title)", directoryHint: .isDirectory)
        var suffix = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = meetingsDirectory.appending(path: "\(stamp)-\(title)-\(suffix)", directoryHint: .isDirectory)
            suffix += 1
        }
        return destination
    }

    func moveCompletedSession(from pending: URL, to destination: URL) throws {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: pending, to: destination)
    }

    static func slug(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let ascii = folded.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripCombiningMarks, reverse: false) ?? folded
        let lowered = ascii.lowercased()
        let parts = lowered.split { !$0.isASCII || !$0.isLetter && !$0.isNumber }
        let slug = parts.joined(separator: "-")
        return slug.isEmpty ? "meeting" : String(slug.prefix(80))
    }

    static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter
    }()
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
