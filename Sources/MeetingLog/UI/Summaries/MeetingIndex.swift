import AVFoundation
import Foundation

struct MeetingDigest: Equatable, Sendable {
    /// Original and Chinese summary text, searched together.
    let searchText: String
    let snippet: String?
    /// From the summary's `- Date:` line; nil when the line has no time.
    let start: Date?
}

/// Summary text, snippets and audio durations for the meeting list, read off the main actor and cached
/// by file modification date so refreshing the list only rereads what changed.
@MainActor
final class MeetingIndex: ObservableObject {
    @Published private(set) var digests: [URL: MeetingDigest] = [:]
    @Published private(set) var durations: [URL: Double] = [:]
    private var stamps: [URL: Stamp] = [:]
    private var task: Task<Void, Never>?

    private struct Stamp: Equatable, Sendable {
        var summary: Date?
        var chinese: Date?
        var audio: Date?
    }

    private struct Entry: Sendable {
        let url: URL
        let stamp: Stamp
        /// nil when the summaries did not change since the previous stamp.
        let digest: MeetingDigest?
        let audioChanged: Bool
        let duration: Double?
    }

    func refresh(_ urls: [URL]) {
        task?.cancel()
        let wanted = Set(urls)
        stamps = stamps.filter { wanted.contains($0.key) }
        let known = stamps
        digests = digests.filter { wanted.contains($0.key) }
        durations = durations.filter { wanted.contains($0.key) }
        task = Task { [weak self] in
            var start = 0
            while start < urls.count {
                let chunk = Array(urls[start..<min(start + 12, urls.count)])
                start += chunk.count
                let entries = await Task.detached(priority: .utility) {
                    var entries: [Entry] = []
                    for url in chunk { entries.append(await Self.load(url, previous: known[url])) }
                    return entries
                }.value
                guard let self, !Task.isCancelled else { return }
                self.apply(entries)
            }
        }
    }

    /// Forces the next refresh to reread this meeting, for example after saving a regenerated summary.
    func invalidate(_ url: URL) {
        stamps[url] = nil
    }

    private func apply(_ entries: [Entry]) {
        for entry in entries {
            stamps[entry.url] = entry.stamp
            if let digest = entry.digest { digests[entry.url] = digest }
            if entry.audioChanged { durations[entry.url] = entry.duration }
        }
    }

    nonisolated private static func load(_ url: URL, previous: Stamp?) async -> Entry {
        func modified(_ name: String) -> Date? {
            try? url.appending(path: name).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        let stamp = Stamp(summary: modified("summary.md"), chinese: modified("summary_cn.md"), audio: modified("audio.m4a"))
        var digest: MeetingDigest?
        if previous == nil || previous?.summary != stamp.summary || previous?.chinese != stamp.chinese {
            let original = (try? String(contentsOf: url.appending(path: "summary.md"), encoding: .utf8)) ?? ""
            let chinese = (try? String(contentsOf: url.appending(path: "summary_cn.md"), encoding: .utf8)) ?? ""
            let document = SummaryDocument.parse(original)
            digest = MeetingDigest(searchText: original + "\n" + chinese, snippet: document.snippet,
                                   start: SummaryDocument.startDate(document.date))
        }
        let audioChanged = previous == nil || previous?.audio != stamp.audio
        var duration: Double?
        if audioChanged, stamp.audio != nil {
            let seconds = try? await AVURLAsset(url: url.appending(path: "audio.m4a")).load(.duration).seconds
            duration = seconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        }
        return Entry(url: url, stamp: stamp, digest: digest, audioChanged: audioChanged, duration: duration)
    }
}
