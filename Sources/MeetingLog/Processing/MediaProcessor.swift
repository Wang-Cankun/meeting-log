import AVFoundation
import Foundation

struct AudioChunk {
    let url: URL
    let startSeconds: Double
    let endSeconds: Double
}

struct MediaProcessor {
    static let blockSeconds = 300.0
    static let overlapSeconds = 10.0

    func prepareAudio(from capture: URL, in directory: URL) async throws -> (audio: URL, chunks: [AudioChunk]) {
        let audio = directory.appending(path: "audio.m4a")
        if !FileManager.default.fileExists(atPath: audio.path) {
            try await export(source: capture, destination: audio, range: nil)
        }

        let asset = AVURLAsset(url: audio)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw MediaError.emptyRecording }

        let chunkDirectory = directory.appending(path: "chunks", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: chunkDirectory, withIntermediateDirectories: true)
        var result: [AudioChunk] = []
        var start = 0.0
        var index = 0
        while start < duration {
            let end = min(start + Self.blockSeconds, duration)
            let url = chunkDirectory.appending(path: String(format: "%04d.m4a", index))
            if !FileManager.default.fileExists(atPath: url.path) {
                let range = CMTimeRange(
                    start: CMTime(seconds: start, preferredTimescale: 600),
                    end: CMTime(seconds: end, preferredTimescale: 600)
                )
                try await export(source: audio, destination: url, range: range)
            }
            result.append(AudioChunk(url: url, startSeconds: start, endSeconds: end))
            if end == duration { break }
            start = end - Self.overlapSeconds
            index += 1
        }
        return (audio, result)
    }

    private func export(source: URL, destination: URL, range: CMTimeRange?) async throws {
        let asset = AVURLAsset(url: source)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw MediaError.exportUnavailable
        }
        if let range { exporter.timeRange = range }
        try await exporter.export(to: destination, as: .m4a)
    }
}

enum MediaError: LocalizedError {
    case emptyRecording
    case exportUnavailable

    var errorDescription: String? {
        switch self {
        case .emptyRecording: "The recording contains no audio."
        case .exportUnavailable: "Audio export is unavailable."
        }
    }
}
