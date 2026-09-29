import AppKit
import SwiftUI

/// Shared column widths so every source row lines up on one grid.
/// Text outside cards starts at `textLeading`; cards and buttons sit `cardInset` from the panel edge,
/// and content inside a card starts at `cardInset + rowInset`.
enum PanelMetrics {
    static let textLeading: CGFloat = 20
    static let cardInset: CGFloat = 12
    static let rowInset: CGFloat = 14
    static let iconButton: CGFloat = 30
    static let iconColumn: CGFloat = 20
    static let columnSpacing: CGFloat = 10
    static let trailingColumn: CGFloat = 36
    static let cardRadius: CGFloat = 12
    /// Leading edge of a row's content column, used for divider and footer indents.
    static let contentLeading: CGFloat = rowInset + iconColumn + columnSpacing
}

/// A light grey panel behind white cards in light mode; in dark mode cards sit slightly lighter than the panel.
enum PanelColors {
    static let background = Color(nsColor: NSColor(name: nil) { appearance in
        resolve(.windowBackgroundColor, in: appearance) { dark, base in
            dark ? base : base.blended(withFraction: 0.035, of: .black) ?? base
        }
    })
    static let card = Color(nsColor: NSColor(name: nil) { appearance in
        resolve(.controlBackgroundColor, in: appearance) { dark, base in
            dark ? base.blended(withFraction: 0.07, of: .white) ?? base : base
        }
    })
    static let border = Color(nsColor: .separatorColor)
    static let hover = Color.primary.opacity(0.06)
    /// Unfilled part of a level meter or progress bar.
    static let track = Color(nsColor: .quaternaryLabelColor)

    private static func resolve(_ color: NSColor, in appearance: NSAppearance,
                                _ adjust: (Bool, NSColor) -> NSColor) -> NSColor {
        var result = color
        appearance.performAsCurrentDrawingAppearance {
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            result = adjust(dark, color.usingColorSpace(.sRGB) ?? color)
        }
        return result
    }
}

/// Same size, weight and colour for every header icon button, plain or menu.
struct PanelIconLabel: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: PanelMetrics.iconButton, height: PanelMetrics.iconButton)
            .contentShape(Rectangle())
    }
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
            PanelIconLabel(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
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
            .font(.subheadline.weight(.semibold))
            .tracking(0.2)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Rounded card used for the sources, tracks and pending-meeting groups: a card fill with a hairline border.
struct PanelCard<Content: View>: View {
    var tint: Color? = nil
    var radius: CGFloat = PanelMetrics.cardRadius
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius).fill(PanelColors.card)
                if let tint { RoundedRectangle(cornerRadius: radius).fill(tint.opacity(0.09)) }
            }
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(tint.map { $0.opacity(0.35) } ?? PanelColors.border))
    }
}

/// Full-width primary action (Start, Stop, Saving…) at the mockup's 44 pt height.
struct PanelActionLabel: View {
    let title: String
    var systemImage: String? = nil
    var iconStyle: AnyShapeStyle? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(iconStyle ?? AnyShapeStyle(.white), .white)
                    .accessibilityHidden(true)
            }
            Text(title)
        }
        .font(.system(size: 14, weight: .semibold))
        .frame(maxWidth: .infinity, minHeight: 32)
    }
}

extension View {
    /// Large rounded-rectangle shape shared by the panel's primary actions.
    func panelActionStyle() -> some View {
        controlSize(.large)
            .buttonBorderShape(.roundedRectangle(radius: 11))
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
                Capsule().fill(PanelColors.track)
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

/// Compact source summary for the collapsed sources card: icon, short name and its own meter.
struct MiniSource: View {
    let icon: String
    let name: String
    /// nil when the source is not included; the meter is then left out.
    let level: Float?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(name)
                .font(.callout.weight(.medium))
                .foregroundStyle(level == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(name)
            if let level {
                MiniMeter(level: level)
                    .padding(.leading, 2)
            }
        }
    }
}

struct MiniMeter: View {
    static let width: CGFloat = 34
    let level: Float

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(PanelColors.track)
            Capsule()
                .fill(LevelMeter.color(for: level))
                .frame(width: Self.width * CGFloat(min(max(level, 0), 1)))
        }
        .frame(width: Self.width, height: 4)
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

/// Bordered field look matching the project chooser, at full width.
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
                .font(.callout)
                .padding(.leading, 10)
                .padding(.trailing, 8)
                .frame(minHeight: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(isEnabled ? PanelColors.card : PanelColors.background))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(configuration.isPressed ? PanelColors.hover : .clear)
                }
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .tertiaryLabelColor).opacity(0.45)))
                // Full Keyboard Access: the filled field has no system ring of its own.
                .overlay {
                    if isFocused {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 2)
                    }
                }
                .opacity(isEnabled ? 1 : 0.6)
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
                HStack(spacing: 8) {
                    Text(name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text(status)
                        .font(.subheadline)
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
        .padding(.top, 12)
        .padding(.bottom, 14)
    }
}

/// Six-segment processing bar: finished stages full, the current one highlighted and partly filled.
struct StageBar: View {
    /// nil draws an empty bar, for queued meetings.
    let stage: ProcessingStage?

    var body: some View {
        let current = stage?.segment ?? -1
        HStack(alignment: .top, spacing: 4) {
            ForEach(Array(ProcessingStage.segmentTitles.enumerated()), id: \.offset) { index, title in
                VStack(spacing: 4) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(index == current ? AnyShapeStyle(Color.accentColor.opacity(0.22)) : AnyShapeStyle(PanelColors.track))
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: proxy.size.width * fill(index, current: current))
                        }
                    }
                    .frame(height: 4)
                    Text(title)
                        .font(.system(size: 10.5, weight: index == current ? .semibold : .regular))
                        .foregroundStyle(index == current ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
    /// The chosen input device's name; nil for the system default.
    var selectedMicrophoneName: String? {
        microphones.first { $0.uniqueID == selectedMicrophoneID }?.localizedName
    }

    /// The chosen input device, or the system default label.
    var selectedMicrophoneLabel: String { selectedMicrophoneName ?? "System default" }

    /// Readable project name for a stored relative project path, with underscores shown as spaces.
    func projectDisplayName(_ name: String?) -> String {
        guard let name, name != ArchiveStore.inboxName else { return "Inbox" }
        return MeetingLibrary.displayName(projects.first { $0.name == name }?.displayName
            ?? name.split(separator: "/").last.map(String.init) ?? name)
    }
}
