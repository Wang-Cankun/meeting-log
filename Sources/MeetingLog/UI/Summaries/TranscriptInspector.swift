import SwiftUI

/// The evidence transcript beside a summary. L numbers match the source file's lines, timestamps seek the
/// archived playback audio, and the scrubber marks where the shown summary's evidence lines are.
struct TranscriptInspector: View {
    @ObservedObject var navigator: TranscriptNavigator
    @ObservedObject var player: TranscriptPlayer
    /// Lines referenced by the summary currently shown, for the scrubber's evidence ticks.
    let evidenceLines: [Int]
    @State private var readable = false
    @State private var readableDocument: TranscriptDocument?
    @State private var readableError: String?

    private var document: TranscriptDocument? { readable ? readableDocument : navigator.source }
    private var error: String? { readable ? readableError : navigator.error }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transcript").font(.system(size: 13, weight: .semibold))
                Spacer()
                if navigator.hasReadableCopy {
                    Picker("Transcript version", selection: $readable) {
                        Text("Source").tag(false)
                        Text("Readable").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
                    .help("Source is the evidence file that L numbers refer to. Readable is the cleaned copy.")
                }
            }
            .padding(.leading, 18).padding(.trailing, 14).padding(.top, 8).padding(.bottom, 6)
            lines
            Divider()
            playerBar
        }
        .task(id: readable ? navigator.meetingURL : nil) { await loadReadable() }
        .onChange(of: navigator.meetingURL) { _, _ in
            readable = false
            readableDocument = nil
            readableError = nil
        }
        .onChange(of: navigator.revealRequest) { _, _ in readable = false }
        .onDisappear { player.pause() }
    }

    @ViewBuilder
    private var lines: some View {
        if navigator.meetingURL == nil {
            ContentUnavailableView("No meeting selected", systemImage: "text.quote")
        } else if let error {
            Text(error).foregroundStyle(.red).textSelection(.enabled).padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if let document {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // The file's own title repeats the inspector's heading.
                        ForEach(document.lines.filter { !Self.isTitle($0, in: document) }) { line in row(line).id(line.number) }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 8)
                    .textSelection(.enabled)
                }
                .onChange(of: navigator.revealRequest) { _, _ in reveal(proxy) }
                .onChange(of: navigator.loading) { _, _ in reveal(proxy) }
                .onChange(of: readable) { _, _ in reveal(proxy) }
                .onAppear { reveal(proxy) }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func row(_ line: TranscriptLine) -> some View {
        let highlighted = !readable && line.number == navigator.highlightedLine
        switch line.kind {
        case let .heading(title):
            Text(title)
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.leading, readable ? 10 : 46).padding(.top, 10).padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
        case let .turn(speaker, stamp, text):
            let color = SpeakerStyle.color(for: speaker, in: navigator.source ?? document)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                gutter(line, highlighted: highlighted)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
                        Text(speaker).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(color)
                        if let seconds = line.seconds { stampButton(stamp, seconds: seconds) }
                    }
                    Text(text).font(.system(size: 12.5)).lineSpacing(2.5).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 7).padding(.horizontal, 10)
            .background(highlighted ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 7))
        case .text:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                gutter(line, highlighted: highlighted)
                // Older transcripts put the timestamp on its own line, or omit the speaker; it still seeks.
                if let seconds = line.seconds, let close = line.text.firstIndex(of: "]") {
                    stampButton(String(line.text[line.text.index(after: line.text.startIndex)..<close]), seconds: seconds)
                    let rest = line.text[line.text.index(after: close)...].trimmingCharacters(in: .whitespaces)
                    if !rest.isEmpty {
                        Text(rest).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(line.text).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4).padding(.horizontal, 10)
            .background(highlighted ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private static func isTitle(_ line: TranscriptLine, in document: TranscriptDocument) -> Bool {
        guard case .heading = line.kind else { return false }
        return line.number == document.lines.first?.number && line.text.hasPrefix("# ")
    }

    private func stampButton(_ stamp: String, seconds: Double) -> some View {
        Button(stamp) { player.seek(to: seconds, play: true) }
            .buttonStyle(.plain)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(player.isAvailable ? Color.accentColor : Color.secondary)
            .disabled(!player.isAvailable)
            .help("Play from \(stamp)")
            .accessibilityLabel("Play from \(stamp)")
    }

    @ViewBuilder
    private func gutter(_ line: TranscriptLine, highlighted: Bool) -> some View {
        if !readable {
            Text(verbatim: "L\(line.number)")
                .font(.system(size: 10.5, design: .monospaced))
                .fontWeight(highlighted ? .semibold : .regular)
                .foregroundStyle(highlighted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: 30, alignment: .trailing)
        }
    }

    private var playerBar: some View {
        Group {
            if player.isAvailable {
                HStack(spacing: 12) {
                    Button { player.toggle() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.accentColor, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help(player.isPlaying ? "Pause" : "Play")
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                    VStack(spacing: 6) {
                        Scrubber(time: player.currentTime, duration: player.duration, ticks: ticks) {
                            player.seek(to: $0, play: player.isPlaying)
                        }
                        HStack {
                            Text(Self.clock(player.currentTime))
                            Spacer()
                            Text(Self.clock(player.duration))
                        }
                        .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
            } else if navigator.meetingURL != nil {
                Text("No playback audio for this meeting.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var ticks: [Double] {
        guard player.duration > 0, let source = navigator.source else { return [] }
        let all = Set(evidenceLines.filter { source.line($0) != nil }.compactMap { source.cueSeconds(for: $0) })
            .filter { $0 <= player.duration }.sorted()
        // Marks closer than about a pixel apart merge, so dense evidence stays legible.
        let gap = player.duration / 250
        return all.reduce(into: [Double]()) { kept, value in
            if let last = kept.last, value - last < gap { return }
            kept.append(value)
        }
    }

    private func reveal(_ proxy: ScrollViewProxy) {
        guard !readable, let line = navigator.highlightedLine, navigator.source?.line(line) != nil else { return }
        // Let a newly shown inspector lay out before scrolling.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            withAnimation { proxy.scrollTo(line, anchor: .center) }
        }
    }

    private func loadReadable() async {
        guard readable, let url = navigator.meetingURL, readableDocument == nil else { return }
        let file = url.appending(path: SummaryEvidence.Source.legacy.rawValue)
        let result = await Task.detached(priority: .userInitiated) { () -> (TranscriptDocument?, String?) in
            do { return (TranscriptDocument(try String(contentsOf: file, encoding: .utf8)), nil) }
            catch { return (nil, error.localizedDescription) }
        }.value
        guard navigator.meetingURL == url else { return }
        readableDocument = result.0
        readableError = result.1
    }

    static func clock(_ seconds: Double) -> String {
        let value = seconds.isFinite ? Int(seconds) : 0
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

/// Playback position with marks at the timestamps of the summary's evidence lines.
private struct Scrubber: View {
    let time: Double
    let duration: Double
    let ticks: [Double]
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fraction = duration > 0 ? min(max(time / duration, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color(nsColor: .quaternaryLabelColor)).frame(height: 4)
                Capsule().fill(Color.accentColor).frame(width: max(4, width * fraction), height: 4)
                ForEach(ticks, id: \.self) { value in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.secondary.opacity(0.6))
                        .frame(width: 2, height: 12)
                        .offset(x: width * value / max(duration, 1) - 1)
                }
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                    .overlay(Circle().strokeBorder(.black.opacity(0.12)))
                    .frame(width: 12, height: 12)
                    .offset(x: width * fraction - 6)
            }
            .frame(height: 12)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard duration > 0, width > 0 else { return }
                seek(min(max(value.location.x / width, 0), 1) * duration)
            })
        }
        .frame(height: 12)
        .accessibilityRepresentation {
            Slider(value: Binding(get: { time }, set: seek), in: 0...max(duration, 1)) { Text("Playback position") }
        }
    }
}
