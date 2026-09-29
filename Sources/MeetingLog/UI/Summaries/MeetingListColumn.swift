import SwiftUI

/// Date-grouped meetings in the selected scope, with a time, duration and summary snippet per row.
/// Rows are drawn here rather than by `List`, so the selection is a soft tint that keeps the text readable.
struct MeetingListColumn: View {
    struct EmptyState {
        let title: String
        let systemImage: String
        let description: String
    }

    let title: String
    let sections: [(title: String, meetings: [ArchivedMeeting])]
    let count: Int
    @Binding var selection: URL?
    @ObservedObject var index: MeetingIndex
    let now: Date
    let emptyState: EmptyState?
    let refresh: () -> Void
    @FocusState private var focused: Bool

    private var ordered: [URL] { sections.flatMap { $0.meetings.map(\.url) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(sections.enumerated()), id: \.element.title) { position, section in
                            Text(section.title)
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 10).padding(.top, position == 0 ? 4 : 12).padding(.bottom, 4)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(section.meetings) { meeting in
                                MeetingRow(meeting: meeting, digest: index.digests[meeting.url],
                                           duration: index.durations[meeting.url], now: now,
                                           selected: meeting.url == selection) { selection = meeting.url; focused = true }
                                    .id(meeting.url)
                            }
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 12)
                }
                .focusable()
                .focused($focused)
                .focusEffectDisabled()
                .onKeyPress(.upArrow) { move(-1, proxy) }
                .onKeyPress(.downArrow) { move(1, proxy) }
                .onChange(of: selection) { _, url in
                    guard let url else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(url) }
                }
            }
            .overlay {
                if let emptyState {
                    ContentUnavailableView(emptyState.title, systemImage: emptyState.systemImage,
                                           description: Text(emptyState.description))
                }
            }
        }
    }

    /// Scope name and count on one baseline; the name truncates before the count wraps.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .lineLimit(1).truncationMode(.tail)
                .help(title)
            Text(count == 1 ? "1 meeting" : "\(count) meetings")
                .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                .lineLimit(1).fixedSize()
            Spacer(minLength: 4)
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Refresh meetings")
            .accessibilityLabel("Refresh meetings")
        }
        .padding(.leading, 18).padding(.trailing, 14).padding(.top, 8).padding(.bottom, 8)
    }

    private func move(_ step: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        let urls = ordered
        guard !urls.isEmpty else { return .ignored }
        let current = selection.flatMap { urls.firstIndex(of: $0) }
        let next = current.map { min(max($0 + step, 0), urls.count - 1) } ?? 0
        selection = urls[next]
        return .handled
    }
}

private struct MeetingRow: View {
    let meeting: ArchivedMeeting
    let digest: MeetingDigest?
    let duration: Double?
    let now: Date
    let selected: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        let subtitle = [MeetingLibrary.rowDate(start: digest?.start ?? meeting.date, hasTime: digest?.start != nil, now: now),
                        duration.flatMap(MeetingLibrary.duration)].compactMap { $0 }.joined(separator: " · ")
        Button(action: select) {
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .lineSpacing(1)
                HStack(spacing: 6) {
                    if !subtitle.isEmpty { Text(subtitle).monospacedDigit() }
                    if meeting.captureWarning != nil {
                        Text("Partial audio")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                            .help(meeting.captureWarning ?? "")
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                if let snippet = digest?.snippet {
                    Text(snippet)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineLimit(2).lineSpacing(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 9).padding(.horizontal, 10)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? AnyShapeStyle(Color.accentColor.opacity(0.14))
                          : hovering ? AnyShapeStyle(Color(nsColor: .quaternarySystemFill)) : AnyShapeStyle(Color.clear))
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(meeting.title)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
