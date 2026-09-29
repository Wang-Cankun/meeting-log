import AVFoundation
import SwiftUI

/// Evidence navigation shared by summary chips, their popovers and the transcript inspector.
/// It owns the selected meeting's evidence transcript and playback so a chip can play or reveal a line
/// whether or not the inspector is open.
@MainActor
final class TranscriptNavigator: ObservableObject {
    @Published var showsInspector = false
    @Published private(set) var highlightedLine: Int?
    /// Increments on every reveal, so revealing the same line again still scrolls to it.
    @Published private(set) var revealRequest = 0
    @Published private(set) var meetingURL: URL?
    @Published private(set) var source: TranscriptDocument?
    @Published private(set) var sourceFile = SummaryEvidence.Source.raw.rawValue
    @Published private(set) var hasReadableCopy = false
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    let player = TranscriptPlayer()
    private var loadTask: Task<Void, Never>?

    func open(_ url: URL?) {
        guard url != meetingURL else { return }
        meetingURL = url
        highlightedLine = nil
        source = nil
        error = nil
        hasReadableCopy = false
        loadTask?.cancel()
        player.load(url?.appending(path: "audio.m4a"))
        guard let url else { loading = false; return }
        loading = true
        loadTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { Self.read(url) }.value
            guard let self, !Task.isCancelled, self.meetingURL == url else { return }
            self.loading = false
            self.sourceFile = loaded.file
            self.hasReadableCopy = loaded.hasReadableCopy
            self.source = loaded.document
            self.error = loaded.error
        }
    }

    /// Highlights and scrolls to a line in the source transcript, cueing audio without starting it.
    func show(line: Int) {
        showsInspector = true
        highlightedLine = line
        revealRequest += 1
        if let seconds = source?.cueSeconds(for: line) { player.seek(to: seconds, play: false) }
    }

    func play(line: Int) {
        show(line: line)
        if let seconds = source?.cueSeconds(for: line) { player.seek(to: seconds, play: true) }
    }

    private struct Loaded: Sendable {
        let file: String
        let hasReadableCopy: Bool
        let document: TranscriptDocument?
        let error: String?
    }

    nonisolated private static func read(_ directory: URL) -> Loaded {
        let source = TranscriptDocument.evidenceSource(in: directory)
        let readable = source == .raw
            && FileManager.default.fileExists(atPath: directory.appending(path: SummaryEvidence.Source.legacy.rawValue).path)
        do {
            let text = try String(contentsOf: directory.appending(path: source.rawValue), encoding: .utf8)
            return Loaded(file: source.rawValue, hasReadableCopy: readable, document: TranscriptDocument(text), error: nil)
        } catch {
            return Loaded(file: source.rawValue, hasReadableCopy: readable, document: nil, error: error.localizedDescription)
        }
    }
}

@MainActor
final class TranscriptPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    private var player: AVPlayer?
    private var observer: Any?
    private var url: URL?

    var isAvailable: Bool { player != nil }

    func load(_ url: URL?) {
        guard url != self.url else { return }
        pause()
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        self.url = url
        currentTime = 0
        duration = 0
        guard let url, FileManager.default.fileExists(atPath: url.path) else { player = nil; return }
        let player = AVPlayer(url: url)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds
                self.isPlaying = (self.player?.rate ?? 0) > 0
            }
        }
        self.player = player
        Task { [weak self] in
            let seconds = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
            if self?.url == url { self?.duration = seconds.isFinite ? seconds : 0 }
        }
    }

    func seek(to seconds: Double, play: Bool) {
        guard let player else { return }
        currentTime = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if play { player.play(); isPlaying = true }
    }

    func toggle() {
        guard let player else { return }
        if player.rate > 0 { pause() } else { player.play(); isPlaying = true }
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }
}
