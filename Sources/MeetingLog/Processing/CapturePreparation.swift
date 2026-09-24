import Foundation

/// Records which raw tracks reached playback before any recoverable source is removed.
struct CapturePreparation: Codable, Equatable {
    enum State: String, Codable { case preparing, ready }
    /// `microphoneOnly` means the computer played nothing, as in an in-person meeting; no audio was lost.
    enum Mode: String, Codable { case complete, systemAudioOnly, microphoneOnly }

    var state: State
    let mode: Mode
    var reason: String? = nil

    static let fileName = "capture-preparation.json"
    var retainsRawTracks: Bool { mode == .systemAudioOnly }
    var warning: String? {
        guard retainsRawTracks else { return nil }
        return "Only system audio was recovered. Playback, transcript, and summary exclude the microphone. Original tracks are retained for manual recovery."
    }

    static func load(in directory: URL) throws -> Self? {
        let file = directory.appending(path: fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
    }

    func write(in directory: URL) throws {
        try JSONEncoder().encode(self).write(to: directory.appending(path: Self.fileName), options: .atomic)
    }

    func addingNotice(to markdown: String, chinese: Bool = false) -> String {
        guard retainsRawTracks else { return markdown }
        let notice = chinese
            ? "## 录音恢复说明\n\n仅恢复了系统音频；播放音频、转写和摘要均不包含麦克风内容。原始音轨 `microphone.m4a` 和 `system-audio.caf` 已保留，可用于人工恢复；保留文件不代表文件一定可读取。"
            : "## Recording recovery\n\nOnly system audio was recovered; playback, transcript, and summary exclude the microphone. Original tracks `microphone.m4a` and `system-audio.caf` are retained for manual recovery; retained files may still need repair."
        return markdown.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + notice + "\n"
    }

    /// A preparing receipt is deliberately not reusable, even if an older movie exists.
    /// Persist the selected mode before publishing media, so a crash cannot hide an omission.
    @MainActor
    static func prepare(
        in directory: URL,
        mix: (URL?, URL?, URL) async throws -> Void = { system, microphone, destination in
            try await MediaProcessor().makeCaptureMovie(systemAudio: system, microphone: microphone, destination: destination)
        }
    ) async throws -> Self {
        let fm = FileManager.default
        let capture = directory.appending(path: "capture.mov")
        let system = directory.appending(path: "system-audio.caf")
        let microphone = directory.appending(path: "microphone.m4a")
        let previous = try load(in: directory)
        let hasCapture = ((try? capture.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
        if let previous, previous.state == .ready, hasCapture { return previous }

        guard fm.fileExists(atPath: system.path) else {
            // Old sessions may contain only the completed combined recording.
            guard previous == nil, hasCapture else { throw MediaError.emptyRecording }
            let receipt = Self(state: .ready, mode: .complete)
            try receipt.write(in: directory)
            return receipt
        }
        let hasMicrophone = fm.fileExists(atPath: microphone.path)
        var receipt = hasMicrophone && MediaProcessor.holdsNoAudio(system)
            ? Self(state: .preparing, mode: .microphoneOnly)
            : Self(state: .preparing, mode: previous?.mode ?? .complete, reason: previous?.reason)
        try receipt.write(in: directory)
        // Rebuilding media invalidates every cached derivative, including old transcription blocks.
        // Raw tracks and the previous complete capture remain available if rebuilding fails.
        for name in ["audio.m4a", "chunks", "parts", "coverage.json", "transcript_raw.md", "transcript.md",
                     "summary.md", "summary_cn.md", "summary-provenance.json"] {
            let file = directory.appending(path: name)
            if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
        }
        switch receipt.mode {
        case .microphoneOnly:
            try await mix(nil, microphone, capture)
        case .systemAudioOnly:
            try await mix(system, nil, capture)
        case .complete:
            do {
                try await mix(system, hasMicrophone ? microphone : nil, capture)
            } catch {
                guard hasMicrophone else { throw error }
                try Task.checkCancellation()
                receipt = Self(state: .preparing, mode: .systemAudioOnly, reason: error.localizedDescription)
                try receipt.write(in: directory)
                try await mix(system, nil, capture)
            }
        }
        receipt.state = .ready
        try receipt.write(in: directory)
        return receipt
    }
}
