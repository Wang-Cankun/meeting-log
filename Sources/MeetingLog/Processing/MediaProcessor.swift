import AVFoundation
import Foundation

struct AudioChunk: Sendable {
    let url: URL
    let startSeconds: Double
    let endSeconds: Double
}

enum PendingCaptureInput: Equatable {
    case combined(URL)
    case importedParts([ImportedAudioPart])
    case raw(systemAudio: URL, microphone: URL?)
}

struct MediaProcessor {
    // AVAudioConverter invokes its input block synchronously on the conversion thread.
    private final class ConversionInput: @unchecked Sendable {
        let file: AVAudioFile
        let buffer: AVAudioPCMBuffer
        var error: Error?
        init(file: AVAudioFile, buffer: AVAudioPCMBuffer) { self.file = file; self.buffer = buffer }
    }
    static let blockSeconds = 600.0
    static let overlapSeconds = 10.0

    static func pendingInput(in directory: URL) -> PendingCaptureInput? {
        let fileManager = FileManager.default
        let metadata = directory.appending(path: "sources.json")
        if fileManager.fileExists(atPath: metadata.path) {
            guard let data = try? Data(contentsOf: metadata),
                  let parts = try? JSONDecoder().decode([ImportedAudioPart].self, from: data),
                  !parts.isEmpty,
                  parts.allSatisfy({ part in
                      part.fileName == URL(filePath: part.fileName).lastPathComponent
                          && !part.fileName.hasPrefix(".")
                          && part.duration.isFinite && part.duration > 0
                          && fileManager.fileExists(atPath: directory.appending(path: "originals/\(part.fileName)").path)
                  }) else { return nil }
            return .importedParts(parts)
        }
        for ext in AudioImport.supportedExtensions {
            let imported = directory.appending(path: "original.\(ext)")
            if let size = try? imported.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
                return .combined(imported)
            }
        }
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

    func prepareAudio(from capture: URL, in directory: URL, durationLimit: TimeInterval? = nil) async throws -> (audio: URL, chunks: [AudioChunk]) {
        let audio = directory.appending(path: "audio.m4a")
        if !FileManager.default.fileExists(atPath: audio.path) {
            try await export(source: capture, destination: audio, range: nil)
        }

        let asset = AVURLAsset(url: audio)
        let exportedDuration = try await asset.load(.duration).seconds
        let duration = min(exportedDuration, durationLimit ?? exportedDuration)
        guard duration.isFinite, duration > 0 else { throw MediaError.emptyRecording }

        let chunkDirectory = directory.appending(path: "chunks", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: chunkDirectory, withIntermediateDirectories: true)
        let blockDuration = try Self.chunkDuration(in: chunkDirectory)
        var result: [AudioChunk] = []
        var start = 0.0
        var index = 0
        while start < duration {
            let end = min(start + blockDuration, duration)
            let url = chunkDirectory.appending(path: String(format: "%04d.m4a", index))
            if !FileManager.default.fileExists(atPath: url.path) {
                let range = CMTimeRange(
                    start: CMTime(seconds: start, preferredTimescale: 600),
                    end: CMTime(seconds: end, preferredTimescale: 600)
                )
                try await export(source: audio, destination: url, range: range, speech: true)
            }
            result.append(AudioChunk(url: url, startSeconds: start, endSeconds: end))
            if end == duration { break }
            start = end - Self.overlapSeconds
            index += 1
        }
        return (audio, result)
    }

    // Keep cached audio and transcript checkpoints aligned when resuming older sessions.
    static func chunkDuration(in directory: URL) throws -> Double {
        let settings = directory.appending(path: "duration.json")
        if FileManager.default.fileExists(atPath: settings.path) {
            let duration = try JSONDecoder().decode(Double.self, from: Data(contentsOf: settings))
            guard duration.isFinite, duration > overlapSeconds else { throw MediaError.emptyRecording }
            return duration
        }
        let existing = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let duration = existing.contains { $0.pathExtension == "m4a" } ? 300.0 : blockSeconds
        try JSONEncoder().encode(duration).write(to: settings, options: .atomic)
        return duration
    }

    func prepareImportedAudio(parts: [ImportedAudioPart], in directory: URL) async throws -> (audio: URL, chunks: [AudioChunk]) {
        let audio = directory.appending(path: "audio.m4a")
        if !FileManager.default.fileExists(atPath: audio.path) {
            let composition = AVMutableComposition()
            guard let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw MediaError.exportUnavailable
            }
            var cursor = CMTime.zero
            for part in parts {
                let asset = AVURLAsset(url: directory.appending(path: "originals/\(part.fileName)"))
                guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw MediaError.emptyRecording }
                let duration = try await asset.load(.duration)
                try target.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: cursor)
                cursor = cursor + duration
            }
            guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
                throw MediaError.exportUnavailable
            }
            let temporary = directory.appending(path: ".joined-\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try await exporter.export(to: temporary, as: .m4a)
            try FileManager.default.moveItem(at: temporary, to: audio)
        }
        var chunks: [AudioChunk] = []
        var offset = 0.0
        for (index, part) in parts.enumerated() {
            let preparedDirectory = directory.appending(path: "parts/\(index)")
            try FileManager.default.createDirectory(at: preparedDirectory, withIntermediateDirectories: true)
            let prepared = try await prepareAudio(
                from: directory.appending(path: "originals/\(part.fileName)"), in: preparedDirectory, durationLimit: part.duration)
            chunks += prepared.chunks.map {
                AudioChunk(url: $0.url, startSeconds: offset + $0.startSeconds,
                           endSeconds: offset + min($0.endSeconds, part.duration))
            }
            offset += part.duration
        }
        return (audio, chunks)
    }

    private func export(source: URL, destination: URL, range: CMTimeRange?, speech: Bool = false) async throws {
        let asset = AVURLAsset(url: source)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw MediaError.exportUnavailable
        }
        if let range { exporter.timeRange = range }
        let temporary = destination.deletingLastPathComponent().appending(path: ".export-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await exporter.export(to: temporary, as: .m4a)
        if speech {
            try await Task.detached { try Self.encodeSpeech(source: temporary, destination: destination) }.value
            return
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    /// Upload-only encoding; the listening copy keeps the normal archive export quality.
    static func encodeSpeech(source: URL, destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1),
              let converter = AVAudioConverter(from: input.processingFormat, to: format),
              let sourceBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8192),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
            throw MediaError.exportUnavailable
        }
        let temporary = destination.deletingLastPathComponent().appending(path: ".speech-\(UUID()).m4a")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            let output = try AVAudioFile(forWriting: temporary, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24_000,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000
            ])
            let source = ConversionInput(file: input, buffer: sourceBuffer)
            while true {
                try Task.checkCancellation()
                var error: NSError?
                let status = converter.convert(to: outputBuffer, error: &error) { requested, state in
                    guard source.file.framePosition < source.file.length else {
                        state.pointee = .endOfStream; return nil
                    }
                    do {
                        try source.file.read(into: source.buffer, frameCount: min(requested, source.buffer.frameCapacity))
                        state.pointee = source.buffer.frameLength == 0 ? .endOfStream : .haveData
                        return source.buffer.frameLength == 0 ? nil : source.buffer
                    } catch {
                        source.error = error; state.pointee = .endOfStream; return nil
                    }
                }
                if let readError = source.error { throw readError }
                if let error { throw error }
                if outputBuffer.frameLength > 0 { try output.write(from: outputBuffer) }
                if status == .endOfStream { break }
                if status == .error { throw MediaError.exportUnavailable }
            }
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
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
