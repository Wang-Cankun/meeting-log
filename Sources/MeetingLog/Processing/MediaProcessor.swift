import AVFoundation
import Foundation

struct AudioChunk: Sendable {
    let url: URL
    let startSeconds: Double
    let endSeconds: Double
    var track: TranscriptTrack? = nil
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
        let endFrame: AVAudioFramePosition
        var error: Error?
        init(file: AVAudioFile, buffer: AVAudioPCMBuffer, endFrame: AVAudioFramePosition) {
            self.file = file; self.buffer = buffer; self.endFrame = endFrame
        }
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

    /// A readable track with zero frames means nothing played, unlike an unreadable or damaged file.
    static func holdsNoAudio(_ url: URL) -> Bool {
        (try? AVAudioFile(forReading: url).length) == 0
    }

    func makeCaptureMovie(systemAudio: URL?, microphone: URL?, destination: URL) async throws {
        guard systemAudio != nil || microphone != nil else { throw MediaError.emptyRecording }
        let composition = AVMutableComposition()
        var parameters: [AVMutableAudioMixInputParameters] = []
        if let systemAudio {
            try await addAudio(systemAudio, to: composition, parameters: &parameters)
        }
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
        let (audio, chunkDirectory, windows) = try await preparePlayback(from: capture, in: directory, durationLimit: durationLimit)
        var result: [AudioChunk] = []
        for (index, window) in windows.enumerated() {
            let url = chunkDirectory.appending(path: String(format: "%04d.m4a", index))
            try await exportChunk(from: audio, to: url, start: window.start, end: window.end)
            result.append(AudioChunk(url: url, startSeconds: window.start, endSeconds: window.end))
        }
        return (audio, result)
    }

    /// Chunks each raw track on the playback windows, so per-track turns merge on one timeline.
    /// A window past the end of a shorter track has no block for that track.
    func prepareTrackAudio(from capture: URL, tracks: [(TranscriptTrack, URL)], in directory: URL) async throws -> (audio: URL, chunks: [AudioChunk]) {
        let (audio, chunkDirectory, windows) = try await preparePlayback(from: capture, in: directory, durationLimit: nil)
        var result: [AudioChunk] = []
        for (track, source) in tracks {
            let trackDirectory = chunkDirectory.appending(path: track.rawValue, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: trackDirectory, withIntermediateDirectories: true)
            let trackDuration = try await AVURLAsset(url: source).load(.duration).seconds
            guard trackDuration.isFinite, trackDuration > 0 else { throw MediaError.emptyRecording }
            for (index, window) in windows.enumerated() where window.start < trackDuration - 1 {
                let url = trackDirectory.appending(path: String(format: "%04d.m4a", index))
                try await exportChunk(from: source, to: url, start: window.start, end: min(window.end, trackDuration))
                result.append(AudioChunk(url: url, startSeconds: window.start, endSeconds: window.end, track: track))
            }
        }
        return (audio, result.sorted { ($0.startSeconds, $0.track == .system ? 0 : 1) < ($1.startSeconds, $1.track == .system ? 0 : 1) })
    }

    private func preparePlayback(from capture: URL, in directory: URL, durationLimit: TimeInterval?) async throws
        -> (audio: URL, chunkDirectory: URL, windows: [(start: Double, end: Double)]) {
        let (audio, exportedDuration) = try await playbackAudio(from: capture, in: directory)
        let duration = min(exportedDuration, durationLimit ?? exportedDuration)
        guard duration.isFinite, duration > 0 else { throw MediaError.emptyRecording }

        let chunkDirectory = directory.appending(path: "chunks", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: chunkDirectory, withIntermediateDirectories: true)
        let blockDuration = try Self.chunkDuration(in: chunkDirectory)
        return (audio, chunkDirectory, Self.windows(from: 0, to: duration, blockDuration: blockDuration))
    }

    /// Exports the archived listening copy once and reports its duration.
    func playbackAudio(from capture: URL, in directory: URL) async throws -> (audio: URL, duration: Double) {
        let audio = directory.appending(path: "audio.m4a")
        if !FileManager.default.fileExists(atPath: audio.path) {
            try await export(source: capture, destination: audio, range: nil)
        }
        let duration = try await AVURLAsset(url: audio).load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw MediaError.emptyRecording }
        return (audio, duration)
    }

    static func windows(from start: Double, to end: Double, blockDuration: Double = blockSeconds) -> [(start: Double, end: Double)] {
        var windows: [(start: Double, end: Double)] = []
        var cursor = start
        while cursor < end {
            let windowEnd = min(cursor + blockDuration, end)
            windows.append((cursor, windowEnd))
            if windowEnd == end { break }
            cursor = windowEnd - overlapSeconds
        }
        return windows
    }

    private func exportChunk(from source: URL, to url: URL, start: Double, end: Double) async throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let range = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )
        try await export(source: source, destination: url, range: range, speech: true)
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
        let audio = try await joinImportedAudio(parts: parts, in: directory)
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

    /// Joins imported files in playback order into the archived listening copy.
    func joinImportedAudio(parts: [ImportedAudioPart], in directory: URL) async throws -> URL {
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
        return audio
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
        try encode(source: source, destination: destination, sampleRate: 24_000, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVEncoderBitRateKey: 48_000
        ])
    }

    /// Lossless 16 kHz mono upload for speech services; a 70-minute meeting stays near 50 MB.
    static func encodeFLAC(source: URL, destination: URL, range: (start: Double, end: Double)? = nil) throws {
        try encode(source: source, destination: destination, sampleRate: 16_000, settings: [
            AVFormatIDKey: kAudioFormatFLAC
        ], range: range)
    }

    static func encodeSilence(seconds: Double, destination: URL) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 16_000)) else {
            throw MediaError.exportUnavailable
        }
        buffer.frameLength = buffer.frameCapacity
        let output = try AVAudioFile(forWriting: destination, settings: [
            AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1
        ])
        try output.write(from: buffer)
    }

    private static func encode(source: URL, destination: URL, sampleRate: Double, settings: [String: Any],
                               range: (start: Double, end: Double)? = nil) throws {
        let input = try AVAudioFile(forReading: source)
        let inputRate = input.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(max(0, range?.start ?? 0) * inputRate)
        let endFrame = range.map { min(input.length, AVAudioFramePosition($0.end * inputRate)) } ?? input.length
        guard startFrame < endFrame else { throw MediaError.emptyRecording }
        input.framePosition = startFrame
        // 16-bit samples: encoders such as FLAC take their bit depth from the written format, not from settings.
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input.processingFormat, to: format),
              let sourceBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8192),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
            throw MediaError.exportUnavailable
        }
        let temporary = destination.deletingLastPathComponent().appending(path: ".speech-\(UUID()).\(destination.pathExtension)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            let output = try AVAudioFile(forWriting: temporary, settings: settings.merging([
                AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1
            ]) { current, _ in current }, commonFormat: .pcmFormatInt16, interleaved: true)
            let source = ConversionInput(file: input, buffer: sourceBuffer, endFrame: endFrame)
            while true {
                try Task.checkCancellation()
                var error: NSError?
                let status = converter.convert(to: outputBuffer, error: &error) { requested, state in
                    let remaining = source.endFrame - source.file.framePosition
                    guard remaining > 0 else {
                        state.pointee = .endOfStream; return nil
                    }
                    do {
                        try source.file.read(into: source.buffer,
                                             frameCount: min(requested, source.buffer.frameCapacity, AVAudioFrameCount(remaining)))
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
