import AVFoundation
import SwiftUI

/// Shows the evidence transcript beside a summary. L numbers match the file's lines, and
/// timestamps seek the archived playback audio.
struct TranscriptPane: View {
    let meetingURL: URL
    let evidenceFile: String
    @Binding var highlightedLine: Int?
    @State private var readable = false
    @State private var lines: [TranscriptLine] = []
    @State private var error: String?
    @StateObject private var player = TranscriptPlayer()

    private var fileName: String { readable ? "transcript.md" : evidenceFile }
    private var hasReadableCopy: Bool {
        evidenceFile != "transcript.md" && FileManager.default.fileExists(atPath: meetingURL.appending(path: "transcript.md").path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Transcript").font(.headline)
                    Spacer()
                    if hasReadableCopy {
                        Picker("Transcript version", selection: $readable) {
                            Text("Source").tag(false)
                            Text("Readable").tag(true)
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        .help("Source is the evidence file that L numbers refer to. Readable is the cleaned copy.")
                    }
                }
                if player.isAvailable { playerBar }
            }
            .padding(12)
            Divider()
            if let error {
                Text(error).foregroundStyle(.red).padding(12)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(lines) { line in
                            row(line).id(line.number)
                        }
                    }
                    .padding(12)
                    .textSelection(.enabled)
                }
                .onChange(of: highlightedLine) { _, line in reveal(line, proxy: proxy) }
                .onChange(of: lines.count) { _, _ in reveal(highlightedLine, proxy: proxy) }
            }
        }
        .task(id: "\(meetingURL.path)|\(fileName)") { load() }
        .onChange(of: highlightedLine) { _, line in if line != nil { readable = false } }
        .onAppear { player.load(meetingURL.appending(path: "audio.m4a")) }
        .onChange(of: meetingURL) { _, url in player.load(url.appending(path: "audio.m4a")) }
        .onDisappear { player.pause() }
    }

    private var playerBar: some View {
        HStack(spacing: 10) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 16)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Slider(value: Binding(get: { player.currentTime }, set: { player.seek(to: $0, play: player.isPlaying) }),
                   in: 0...max(player.duration, 1))
                .controlSize(.small)
                .accessibilityLabel("Playback position")
            Text("\(clock(player.currentTime)) / \(clock(player.duration))")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func row(_ line: TranscriptLine) -> some View {
        let highlighted = !readable && line.number == highlightedLine
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if !readable {
                Text("L\(line.number)")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                    .frame(width: 38, alignment: .trailing)
            }
            if line.text.hasPrefix("#") {
                Text(line.text.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))
                    .font(.callout.weight(.semibold)).padding(.top, 6)
            } else if let seconds = line.seconds, player.isAvailable {
                Text(timestamped(line.text))
                    .font(.callout)
                    .onTapGesture { player.seek(to: seconds, play: true) }
                    .help("Play from \(clock(seconds))")
            } else {
                Text(line.text).font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2).padding(.horizontal, 4)
        .background(highlighted ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 4))
    }

    private func timestamped(_ text: String) -> AttributedString {
        var stamp = AttributedString(text.prefix(while: { $0 != "]" }) + "]")
        stamp.foregroundColor = .accentColor
        return stamp + AttributedString(String(text.drop(while: { $0 != "]" }).dropFirst()))
    }

    private func load() {
        do {
            let text = try String(contentsOf: meetingURL.appending(path: fileName), encoding: .utf8)
            lines = TranscriptLine.parse(text)
            error = nil
        } catch {
            lines = []
            self.error = error.localizedDescription
        }
    }

    private func reveal(_ number: Int?, proxy: ScrollViewProxy) {
        guard let number, !readable, lines.contains(where: { $0.number == number }) else { return }
        withAnimation { proxy.scrollTo(number, anchor: .center) }
        // Cue the referenced turn, or the nearest earlier timestamp, without starting playback.
        if let seconds = lines.last(where: { $0.number <= number && $0.seconds != nil })?.seconds {
            player.seek(to: seconds, play: false)
        }
    }

    private func clock(_ seconds: Double) -> String {
        let value = seconds.isFinite ? Int(seconds) : 0
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

struct TranscriptLine: Identifiable, Equatable {
    var id: Int { number }
    let number: Int
    let text: String
    let seconds: Double?

    /// Numbers match `TranscriptEvidence.annotated`, which counts every newline-separated line.
    static func parse(_ text: String) -> [TranscriptLine] {
        text.components(separatedBy: .newlines).enumerated().compactMap { index, line in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return TranscriptLine(number: index + 1, text: line, seconds: timestamp(line))
        }
    }

    private static func timestamp(_ line: String) -> Double? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let parts = line[line.index(after: line.startIndex)..<close].split(separator: ":")
        guard parts.count == 2, let minutes = Int(parts[0]), let seconds = Int(parts[1]) else { return nil }
        return Double(minutes * 60 + seconds)
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

    func load(_ url: URL) {
        guard url != self.url else { return }
        pause()
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        self.url = url
        currentTime = 0
        duration = 0
        guard FileManager.default.fileExists(atPath: url.path) else { player = nil; return }
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
