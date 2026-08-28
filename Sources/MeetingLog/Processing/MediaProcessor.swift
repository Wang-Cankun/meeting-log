import AVFoundation
import Foundation

struct AudioChunk {
    let url: URL
    let startSeconds: Double
    let endSeconds: Double
}

enum PendingCaptureInput: Equatable {
    case combined(URL)
    case raw(systemAudio: URL, microphone: URL?)
}

struct MediaProcessor {
    static let blockSeconds = 300.0
    static let overlapSeconds = 10.0

    static func pendingInput(in directory: URL) -> PendingCaptureInput? {
        let fileManager = FileManager.default
        let combined = directory.appending(path: "capture.mov")
        if let size = try? combined.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
            return .combined(combined)
        }
        let systemAudio = directory.appending(path: "system-audio.caf")
        guard fileManager.fileExists(atPath: systemAudio.path) else { return nil }
        let microphone = directory.appending(path: "microphone.m4a")
        return .raw(
            systemAudio: systemAudio,
            microphone: fileManager.fileExists(atPath: microphone.path) ? microphone : nil
        )
    }

    func makeCaptureMovie(systemAudio: URL, microphone: URL?, destination: URL) async throws {
        let composition = AVMutableComposition()
        var parameters: [AVMutableAudioMixInputParameters] = []
        try await addAudio(systemAudio, to: composition, parameters: &parameters)
        if let microphone {
            try await addAudio(microphone, to: composition, parameters: &parameters)
        }

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw MediaError.exportUnavailable
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        exporter.audioMix = mix
        let fileManager = FileManager.default
        let temporary = destination.deletingLastPathComponent()
            .appending(path: ".capture-\(UUID().uuidString).mov")
        defer { try? fileManager.removeItem(at: temporary) }
        try await exporter.export(to: temporary, as: .mov)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

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

    private func addAudio(
        _ source: URL,
        to composition: AVMutableComposition,
        parameters: inout [AVMutableAudioMixInputParameters]
    ) async throws {
        let asset = AVURLAsset(url: source)
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first,
              let targetTrack = composition.addMutableTrack(
                  withMediaType: .audio,
                  preferredTrackID: kCMPersistentTrackID_Invalid
              )
        else { throw MediaError.emptyRecording }
        let duration = try await asset.load(.duration)
        guard duration.isValid, duration.seconds > 0 else { throw MediaError.emptyRecording }
        try targetTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: sourceTrack,
            at: .zero
        )
        let input = AVMutableAudioMixInputParameters(track: targetTrack)
        input.setVolume(1, at: .zero)
        parameters.append(input)
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
