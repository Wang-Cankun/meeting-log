import AVFoundation
import Foundation

struct AudioImport {
    static let supportedExtensions = ["m4a", "mp3", "wav", "aiff", "aif", "caf"]

    static func inspect(_ url: URL) async throws -> TimeInterval {
        guard url.isFileURL, supportedExtensions.contains(url.pathExtension.lowercased()) else {
            throw ImportError.unsupported
        }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration).seconds
        guard !tracks.isEmpty, duration.isFinite, duration > 0 else { throw MediaError.emptyRecording }
        return duration
    }

    @MainActor
    static func stage(_ source: URL, date: Date, projectName: String, store: ArchiveStore) async throws -> (URL, SessionManifest) {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        _ = try await inspect(source)
        let manifest = SessionManifest(id: UUID(), startedAt: date, status: .captured,
            videoEnabled: false, microphoneID: nil, lastError: nil,
            projectName: projectName, importedFileName: source.lastPathComponent)
        let staging = store.root.appending(path: ".pending/.import-\(manifest.id.uuidString)")
        let destination = store.root.appending(path: ".pending/\(manifest.id.uuidString.lowercased())")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let copy = staging.appending(path: "original.\(source.pathExtension.lowercased())")
        try await Task.detached {
            try FileManager.default.copyItem(at: source, to: copy)
        }.value
        _ = try await inspect(copy)
        try store.write(manifest, to: staging)
        try FileManager.default.moveItem(at: staging, to: destination)
        return (destination, manifest)
    }
    @MainActor
    static func stage(_ sources: [URL], date: Date, projectName: String, store: ArchiveStore) async throws -> (URL, SessionManifest) {
        guard !sources.isEmpty else { throw MediaError.emptyRecording }
        guard Set(sources.map { $0.resolvingSymlinksInPath().standardizedFileURL }).count == sources.count else {
            throw ImportError.duplicate
        }
        if sources.count == 1 { return try await stage(sources[0], date: date, projectName: projectName, store: store) }
        let id = UUID()
        let staging = store.root.appending(path: ".pending/.import-\(id.uuidString)")
        let destination = store.root.appending(path: ".pending/\(id.uuidString.lowercased())")
        try FileManager.default.createDirectory(at: staging.appending(path: "originals"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        var parts: [ImportedAudioPart] = []
        for (index, source) in sources.enumerated() {
            let accessed = source.startAccessingSecurityScopedResource()
            defer { if accessed { source.stopAccessingSecurityScopedResource() } }
            _ = try await inspect(source)
            let fileName = String(format: "%04d", index + 1) + "." + source.pathExtension.lowercased()
            let copy = staging.appending(path: "originals/\(fileName)")
            try await Task.detached { try FileManager.default.copyItem(at: source, to: copy) }.value
            let duration = try await inspect(copy)
            parts.append(ImportedAudioPart(fileName: fileName, originalName: source.lastPathComponent, duration: duration))
        }
        let manifest = SessionManifest(id: id, startedAt: date, status: .captured,
            videoEnabled: false, microphoneID: nil, lastError: nil, projectName: projectName,
            importedParts: parts)
        try JSONEncoder().encode(parts).write(to: staging.appending(path: "sources.json"), options: .atomic)
        try store.write(manifest, to: staging)
        try FileManager.default.moveItem(at: staging, to: destination)
        return (destination, manifest)
    }

}

enum ImportError: LocalizedError {
    case unsupported
    case duplicate
    var errorDescription: String? {
        switch self {
        case .unsupported: "Choose an M4A, MP3, WAV, AIFF, or CAF audio file."
        case .duplicate: "The same audio file was added twice. Remove the duplicate before importing."
        }
    }
}
