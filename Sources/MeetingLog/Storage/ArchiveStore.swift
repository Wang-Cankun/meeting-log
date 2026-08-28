import Foundation

struct ArchiveStore {
    static let rootDefaultsKey = "archiveRoot"
    static let inboxName = "Inbox"

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

    func projects() throws -> [ProjectFolder] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).compactMap { directory in
            let values = try? directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { return nil }
            return ProjectFolder(name: directory.lastPathComponent, url: directory)
        }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func createProject(named value: String) throws -> ProjectFolder {
        let name = try Self.projectName(value)
        if let existing = try projects().first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            try fileManager.createDirectory(at: existing.url.appending(path: "meetings", directoryHint: .isDirectory), withIntermediateDirectories: true)
            let context = existing.url.appending(path: "context.md")
            if !fileManager.fileExists(atPath: context.path) {
                try "# \(existing.name)\n".write(to: context, atomically: true, encoding: .utf8)
            }
            return existing
        }
        let directory = root.appending(path: name, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory.appending(path: "meetings", directoryHint: .isDirectory), withIntermediateDirectories: true)
        try "# \(name)\n".write(to: directory.appending(path: "context.md"), atomically: true, encoding: .utf8)
        return ProjectFolder(name: name, url: directory)
    }

    func projectContexts() throws -> [ProjectContext] {
        try projects().map { project in
            let contextURL = project.url.appending(path: "context.md")
            let markdown = (try? String(contentsOf: contextURL, encoding: .utf8)) ?? ""
            return ProjectContext(name: project.name, markdown: markdown)
        }
    }

    func globalContext() throws -> String {
        let url = root.appending(path: "context.md")
        if !fileManager.fileExists(atPath: url.path) {
            try "# Meeting context\n\nAdd frequent names, projects, and jargon here.\n".write(to: url, atomically: true, encoding: .utf8)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func finalDirectory(projectName: String, title: String, startedAt: Date) throws -> URL {
        guard let projectDirectory = try projects().first(where: { $0.name == projectName })?.url else {
            throw ArchiveError.projectMissing
        }
        let meetingsDirectory = projectDirectory.appending(path: "meetings", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: meetingsDirectory, withIntermediateDirectories: true)
        let stamp = Self.timestamp.string(from: startedAt)
        let safeTitle = Self.meetingTitle(title)
        var destination = meetingsDirectory.appending(path: "\(stamp)\(safeTitle)", directoryHint: .isDirectory)
        var suffix = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = meetingsDirectory.appending(path: "\(stamp)\(safeTitle)-\(suffix)", directoryHint: .isDirectory)
            suffix += 1
        }
        return destination
    }

    func recentMeetings(limit: Int = 3) throws -> [ArchivedMeeting] {
        let meetings = try projects().flatMap { project in
            let directory = project.url.appending(path: "meetings", directoryHint: .isDirectory)
            guard fileManager.fileExists(atPath: directory.path) else { return [ArchivedMeeting]() }
            return try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
                options: [.skipsHiddenFiles]
            ).compactMap { meeting in
                let values = try? meeting.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey])
                let name = meeting.lastPathComponent
                guard values?.isDirectory == true,
                      name.count > 8,
                      fileManager.fileExists(atPath: meeting.appending(path: "transcript.md").path),
                      fileManager.fileExists(atPath: meeting.appending(path: "summary.md").path)
                else { return nil }
                let dateText = String(name.prefix(8))
                guard let date = Self.timestamp.date(from: dateText) else { return nil }
                let createdAt = values?.creationDate ?? date
                return ArchivedMeeting(
                    title: String(name.dropFirst(8)),
                    projectName: project.name,
                    dateText: dateText,
                    date: date,
                    createdAt: createdAt,
                    url: meeting
                )
            }
        }
        return Array(meetings.sorted {
            $0.date == $1.date ? $0.createdAt > $1.createdAt : $0.date > $1.date
        }.prefix(limit))
    }

    func moveCompletedSession(from pending: URL, to destination: URL) throws {
        try fileManager.moveItem(at: pending, to: destination)
    }

    static func meetingTitle(_ value: String) -> String {
        let replaced = value.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) || scalar == "/" || scalar == ":" ? " " : String(scalar)
        }.joined()
        let compact = replaced.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return compact.isEmpty ? "Meeting" : String(compact.prefix(60))
    }

    static func projectName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              !name.hasPrefix("."),
              !name.hasSuffix("."),
              name.count <= 60,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0 == "/" || $0 == ":" })
        else { throw ArchiveError.invalidProjectName }
        return name
    }

    static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMddyyyy"
        formatter.isLenient = false
        return formatter
    }()

}

enum ArchiveError: LocalizedError {
    case invalidProjectName
    case projectMissing

    var errorDescription: String? {
        switch self {
        case .invalidProjectName: "Use 1–60 characters without /, :, control characters, or leading or trailing periods."
        case .projectMissing: "The selected project folder no longer exists."
        }
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
