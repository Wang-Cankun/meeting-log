import AppKit
import SwiftUI

/// Shared column widths so every source row lines up on one grid.
/// Text outside cards starts at `textLeading`; content inside a card starts at `cardInset + rowInset`.
enum PanelMetrics {
    static let textLeading: CGFloat = 16
    static let cardInset: CGFloat = 12
    static let rowInset: CGFloat = 14
    static let iconButton: CGFloat = 28
    static let iconColumn: CGFloat = 20
    static let columnSpacing: CGFloat = 12
    static let trailingColumn: CGFloat = 44
    /// Leading edge of a row's content column, used for divider and footer indents.
    static let contentLeading: CGFloat = rowInset + iconColumn + columnSpacing
}

/// Settings and Quit, reachable in every panel state.
struct PanelMoreMenu: View {
    let showSettings: () -> Void

    var body: some View {
        Menu {
            Button("Settings…", action: showSettings)
                .keyboardShortcut(",")
            Divider()
            Button("Quit MeetingLog") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: PanelMetrics.iconButton, height: PanelMetrics.iconButton)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More")
    }
}

struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Rounded card used for the sources, tracks and pending-meeting groups.
struct PanelCard<Content: View>: View {
    var tint: Color? = nil
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(border))
    }

    private var background: AnyShapeStyle {
        if let tint { AnyShapeStyle(tint.opacity(0.1)) } else { AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) }
    }

    private var border: AnyShapeStyle {
        if let tint { AnyShapeStyle(tint.opacity(0.35)) } else { AnyShapeStyle(.quaternary) }
    }
}

struct LevelMeter: View {
    let source: String
    let state: String
    let level: Float
    let enabled: Bool
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(nsColor: .separatorColor).opacity(0.45))
                Capsule()
                    .fill(Self.color(for: level))
                    .frame(width: max(0, proxy.size.width * CGFloat(enabled ? min(level, 1) : 0)))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("\(source) level")
        .accessibilityValue(enabled ? "\(state), \(Int(level * 100)) percent" : state)
    }

    static func color(for level: Float) -> Color {
        switch AudioLevelState(level: level) {
        case .silence, .active: .green
        case .high: .orange
        case .clipping: .red
        }
    }
}

/// Compact source summary for the collapsed sources card: icon, name and its own meter.
struct MiniSource: View {
    let icon: String
    let name: String
    /// nil when the source is not included; the meter then stays empty.
    let level: Float?
    /// False for screen video, which has no level.
    var showsMeter = true

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 15)
            Text(name)
                .font(.caption.weight(.medium))
                .foregroundStyle(level == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 36, alignment: .leading)
                .help(name)
            if showsMeter {
                MiniMeter(level: level ?? 0)
                    .opacity(level == nil ? 0.5 : 1)
            }
        }
        .layoutPriority(1)
    }
}

struct MiniMeter: View {
    let level: Float

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color(nsColor: .separatorColor).opacity(0.45))
            Capsule()
                .fill(LevelMeter.color(for: level))
                .frame(width: 34 * CGFloat(min(max(level, 0), 1)))
        }
        .frame(width: 34, height: 4)
        .accessibilityHidden(true)
    }
}

/// Label for the full-width source pickers; all three share it so they render identically.
struct SourcePickerLabel: View {
    let text: String
    var placeholder = false

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(placeholder ? .secondary : .primary)
            Spacer(minLength: 4)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(text)
    }
}

/// Filled field look matching the bordered project chooser, at full width.
struct SourcePickerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FieldBody(configuration: configuration)
    }

    private struct FieldBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(.body)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(configuration.isPressed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quaternary), in: RoundedRectangle(cornerRadius: 7))
                // Full Keyboard Access: the filled field has no system ring of its own.
                .overlay {
                    if isFocused {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 2)
                    }
                }
                .opacity(isEnabled ? 1 : 0.55)
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
    }
}

/// One source in the expanded sources card: icon column | name and status | fixed trailing control,
/// with the picker, meter and any recovery action spanning the content column below.
struct SourceRow<Trailing: View, Details: View>: View {
    let icon: String
    let name: String
    let status: String
    var statusColor: Color = .secondary
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let details: Details
    @ScaledMetric(relativeTo: .caption) private var trailingColumn = PanelMetrics.trailingColumn

    var body: some View {
        HStack(alignment: .top, spacing: PanelMetrics.columnSpacing) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: PanelMetrics.iconColumn, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(status)
                    Spacer(minLength: 4)
                    // A minimum, not a fixed width: larger text grows the column instead of clipping it.
                    trailing
                        .fixedSize()
                        .frame(minWidth: trailingColumn, alignment: .trailing)
                }
                .frame(minHeight: 20)
                details
            }
        }
        .padding(.horizontal, PanelMetrics.rowInset)
        .padding(.vertical, 12)
    }
}

/// Six-segment processing bar: finished stages full, the current one highlighted and partly filled.
struct StageBar: View {
    /// nil draws an empty bar, for queued meetings.
    let stage: ProcessingStage?

    var body: some View {
        let current = stage?.segment ?? -1
        HStack(alignment: .top, spacing: 3) {
            ForEach(Array(ProcessingStage.segmentTitles.enumerated()), id: \.offset) { index, title in
                VStack(spacing: 4) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(index == current ? AnyShapeStyle(Color.accentColor.opacity(0.25)) : AnyShapeStyle(.quaternary))
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: proxy.size.width * fill(index, current: current))
                        }
                    }
                    .frame(height: 4)
                    Text(title)
                        .font(.caption2.weight(index == current ? .semibold : .regular))
                        .foregroundStyle(index == current ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Processing progress")
        .accessibilityValue(accessibilityValue(current: current))
    }

    private func fill(_ index: Int, current: Int) -> CGFloat {
        if index < current { return 1 }
        if index == current, let stage { return CGFloat(stage.segmentFraction) }
        return 0
    }

    private func accessibilityValue(current: Int) -> String {
        guard let stage else { return "Not started" }
        guard current < ProcessingStage.segmentTitles.count else { return "Complete" }
        let title = ProcessingStage.segmentTitles[current] == "中文" ? "Chinese" : ProcessingStage.segmentTitles[current]
        if case let .transcribe(completed, total) = stage, total > 0 {
            return "Step \(current + 1) of 6, \(title), \(completed) of \(total)"
        }
        return "Step \(current + 1) of 6, \(title)"
    }
}

enum PanelDate {
    /// "Today", "Yesterday", or "Sep 26" (with the year when it differs), optionally with the time.
    static func relative(_ date: Date, time: Bool = false, now: Date = .now) -> String {
        let calendar = Calendar.current
        let day: String
        if calendar.isDateInToday(date) {
            day = "Today"
        } else if calendar.isDateInYesterday(date) {
            day = "Yesterday"
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            day = date.formatted(.dateTime.month(.abbreviated).day())
        } else {
            day = date.formatted(.dateTime.month(.abbreviated).day().year())
        }
        return time ? "\(day), \(date.formatted(date: .omitted, time: .shortened))" : day
    }
}

extension AppModel {
    /// The chosen input device, or the system default label.
    var selectedMicrophoneLabel: String {
        microphones.first { $0.uniqueID == selectedMicrophoneID }?.localizedName ?? "System default"
    }

    /// Readable project name for a stored relative project path.
    func projectDisplayName(_ name: String?) -> String {
        guard let name, name != ArchiveStore.inboxName else { return "Inbox" }
        return projects.first { $0.name == name }?.displayName
            ?? name.split(separator: "/").last.map(String.init) ?? name
    }
}
