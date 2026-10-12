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

    func hasPendingSessions() throws -> Bool {
        try !pendingSessions().isEmpty
    }

    func projects() throws -> [ProjectFolder] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        var result: [ProjectFolder] = []
        func visit(_ parent: URL, prefix: String, container: Bool) throws {
            let entries = try fileManager.contentsOfDirectory(at: parent,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            for directory in entries {
                guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { continue }
                guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                let leaf = directory.lastPathComponent
                guard prefix.isEmpty || leaf != "meetings" else { continue }
                let name = prefix.isEmpty ? leaf : prefix + "/" + leaf
                if ["projects", "studies"].contains(leaf) {
                    // A structural container may also own general meetings.
                    if fileManager.fileExists(atPath: directory.appending(path: "meeting_context.md").path)
                        || fileManager.fileExists(atPath: directory.appending(path: "meetings").path) {
                        result.append(ProjectFolder(name: name, url: directory))
                    }
                    try? visit(directory, prefix: name, container: true)
                } else if container || fileManager.fileExists(atPath: directory.appending(path: "meeting_context.md").path)
                    || fileManager.fileExists(atPath: directory.appending(path: "meetings").path) {
                    result.append(ProjectFolder(name: name, url: directory))
                    try? visit(directory, prefix: name, container: false)
                }
            }
        }
        try visit(root, prefix: "", container: true)
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func resolveProject(_ requested: String?) throws -> ProjectFolder {
        let name = requested ?? Self.inboxName
        if let project = try projects().first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            return project
        }
        if name == Self.inboxName { return try createProject(named: name) }
        throw ArchiveError.projectMissing
    }

    func meetingContext(for name: String) throws -> String {
        let project = try resolveProject(name)
        var directory = root
        var contexts: [String] = []
        for segment in project.name.split(separator: "/") {
            directory.append(path: String(segment))
            let file = directory.appending(path: "meeting_context.md")
            if fileManager.fileExists(atPath: file.path) {
                let content = try String(contentsOf: file, encoding: .utf8)
                guard content.components(separatedBy: .newlines).contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }) else { continue }
                contexts.append("Context from \(directory.lastPathComponent):\n\(content)")
            }
        }
        return contexts.isEmpty ? "" : "More-specific context takes precedence over general preferences.\n\n" + contexts.joined(separator: "\n\n")
    }

    func createProject(named value: String) throws -> ProjectFolder {
        let name = try Self.projectName(value)
        if let existing = try projects().first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            try fileManager.createDirectory(at: existing.url.appending(path: "meetings", directoryHint: .isDirectory), withIntermediateDirectories: true)
            let context = existing.url.appending(path: "meeting_context.md")
            if !fileManager.fileExists(atPath: context.path) {
                try "# \(existing.name)\n".write(to: context, atomically: true, encoding: .utf8)
            }
            return existing
        }
        let directory = root.appending(path: name, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory.appending(path: "meetings", directoryHint: .isDirectory), withIntermediateDirectories: true)
        let context = directory.appending(path: "meeting_context.md")
        if !fileManager.fileExists(atPath: context.path) {
            try "# \(name)\n".write(to: context, atomically: true, encoding: .utf8)
        }
        return ProjectFolder(name: name, url: directory)
    }

    func projectContexts() throws -> [ProjectContext] {
        try projects().map { ProjectContext(name: $0.name, markdown: try meetingContext(for: $0.name)) }
    }

    func globalContext() throws -> String {
        let url = root.appending(path: "meeting_context.md")
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
        let fullTitle = Self.meetingTitle(title)
        // Leave room for the date and collision suffix within the filesystem byte limit.
        var safeTitle = ""
        for character in fullTitle {
            guard safeTitle.count < 32, (safeTitle + String(character)).utf8.count <= 96 else { break }
            safeTitle.append(character)
        }
        if safeTitle.count < fullTitle.count,
           let boundary = safeTitle.lastIndex(where: { $0.isWhitespace }),
           safeTitle.distance(from: safeTitle.startIndex, to: boundary) > safeTitle.count / 2 {
            safeTitle = String(safeTitle[..<boundary])
        }
        var destination = meetingsDirectory.appending(path: "\(stamp)-\(safeTitle)", directoryHint: .isDirectory)
        var suffix = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = meetingsDirectory.appending(path: "\(stamp)-\(safeTitle)-\(suffix)", directoryHint: .isDirectory)
            suffix += 1
        }
        return destination
    }

    /// Move the archive as a unit; generation history remains a record of its original context.
    func moveMeeting(_ meeting: ArchivedMeeting, to projectName: String) throws -> ArchivedMeeting {
        let sourceProject = try resolveProject(meeting.projectName)
        let destinationProject = try resolveProject(projectName)
        let source = meeting.url.standardizedFileURL
        guard source.deletingLastPathComponent().path == sourceProject.url.appending(path: "meetings").standardizedFileURL.path,
              try source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              fileManager.fileExists(atPath: source.appending(path: "transcript.md").path) else {
            throw ArchiveError.invalidMeeting
        }
        if sourceProject.name == destinationProject.name { return meeting }
        let parent = destinationProject.url.appending(path: "meetings", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        guard parent.resolvingSymlinksInPath().standardizedFileURL.path == parent.standardizedFileURL.path else {
            throw ArchiveError.invalidMeeting
        }
        var destination = parent.appending(path: source.lastPathComponent, directoryHint: .isDirectory)
        var suffix = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = parent.appending(path: "\(source.lastPathComponent)-\(suffix)", directoryHint: .isDirectory)
            suffix += 1
        }
        var originals: [String: Data] = [:]
        var replacements: [String: Data] = [:]
        // Transcript-only meetings have no summary metadata to update.
        let summaryNames = ["summary.md", "summary_cn.md"]
        let hasSummaryFiles = summaryNames.contains { fileManager.fileExists(atPath: source.appending(path: $0).path) }
        for name in hasSummaryFiles ? summaryNames : [] {
            let file = source.appending(path: name)
            if name == "summary_cn.md", !fileManager.fileExists(atPath: file.path) { continue }
            guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw ArchiveError.invalidMeeting
            }
            let data = try Data(contentsOf: file)
            guard let text = String(data: data, encoding: .utf8) else { throw ArchiveError.invalidMeeting }
            var preamble = true
            var found = false
            let updated = text.components(separatedBy: "\n").map { line -> String in
                if line.hasPrefix("## ") { preamble = false }
                if preamble && !found && line.hasPrefix("- Project: ") {
                    found = true
                    return "- Project: \(destinationProject.name)"
                }
                return line
            }.joined(separator: "\n")
            guard found else { throw ArchiveError.invalidMeeting }
            originals[name] = data
            replacements[name] = Data(updated.utf8)
        }
        try fileManager.moveItem(at: source, to: destination)
        var changed: [String] = []
        do {
            for name in replacements.keys.sorted() {
                try replacements[name]!.write(to: destination.appending(path: name), options: .atomic)
                changed.append(name)
            }
        } catch {
            let failure = error
            do {
                for name in changed.reversed() {
                    try originals[name]!.write(to: destination.appending(path: name), options: .atomic)
                }
                try fileManager.moveItem(at: destination, to: source)
            } catch {
                throw NSError(domain: "MeetingLog", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "The move could not be rolled back. The complete meeting folder is at \(destination.path). \(error.localizedDescription)"])
            }
            throw failure
        }
        return ArchivedMeeting(title: meeting.title, projectName: destinationProject.name, dateText: meeting.dateText,
                               date: meeting.date, createdAt: meeting.createdAt, url: destination,
                               captureWarning: meeting.captureWarning, hasSummary: meeting.hasSummary)
    }

    func recentMeetings(limit: Int = 3) throws -> [ArchivedMeeting] {
        let meetings = try projects().flatMap { project in
            let directory = project.url.appending(path: "meetings", directoryHint: .isDirectory)
            guard fileManager.fileExists(atPath: directory.path) else { return [ArchivedMeeting]() }
            let entries = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            return entries.compactMap { meeting in
                let values = try? meeting.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey])
                let name = meeting.lastPathComponent
                guard values?.isDirectory == true,
                      name.count > 8,
                      fileManager.fileExists(atPath: meeting.appending(path: "transcript.md").path)
                else { return nil }
                let dateText = String(name.prefix(8))
                guard let date = Self.timestamp.date(from: dateText) else { return nil }
                let createdAt = values?.creationDate ?? date
                return ArchivedMeeting(
                    title: (try? String(contentsOf: meeting.appending(path: "summary.md"), encoding: .utf8))?
                        .components(separatedBy: .newlines).first(where: { $0.hasPrefix("# ") }).map { String($0.dropFirst(2)) }
                        ?? String(name.dropFirst(8)).trimmingCharacters(in: CharacterSet(charactersIn: "-")),
                    projectName: project.name,
                    dateText: dateText,
                    date: date,
                    createdAt: createdAt,
                    url: meeting,
                    captureWarning: (try? CapturePreparation.load(in: meeting))?.warning,
                    // Meetings processed with AI summaries off keep their folder name as the title.
                    hasSummary: fileManager.fileExists(atPath: meeting.appending(path: "summary.md").path)
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

    /// Without a summary model there is no generated title: imports keep their file name, recordings their start time.
    static func transcriptOnlyTitle(for manifest: SessionManifest, timeZone: TimeZone = .current) -> String {
        if let name = manifest.importedParts?.first?.originalName ?? manifest.importedFileName {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
            // NSString reads ".m4a" as a hidden name without an extension; it is only an extension here.
            let stem = trimmed.hasPrefix(".") && trimmed.pathExtension.isEmpty ? "" : trimmed.deletingPathExtension
            if !stem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return stem }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HHmm"
        return "会议 " + formatter.string(from: manifest.startedAt)
    }

    static func meetingTitle(_ value: String) -> String {
        let replaced = value.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) || scalar == "/" || scalar == ":" ? " " : String(scalar)
        }.joined()
        let compact = replaced.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        // Titles are also displayed in Markdown; never truncate the actual meeting title.
        return compact.isEmpty ? "Meeting" : compact
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
    case invalidMeeting
    case projectMissing

    var errorDescription: String? {
        switch self {
        case .invalidMeeting: "The meeting files or project metadata are missing or invalid. Refresh the archive before moving this meeting."
        case .invalidProjectName: "Use 1–60 characters without /, :, control characters, or leading or trailing periods."
        case .projectMissing: "The selected project folder is missing. Choose its new location before recording or importing."
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
