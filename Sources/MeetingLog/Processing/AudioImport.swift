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
}

enum ImportError: LocalizedError {
    case unsupported
    var errorDescription: String? { "Choose an M4A, MP3, WAV, AIFF, or CAF audio file." }
}
