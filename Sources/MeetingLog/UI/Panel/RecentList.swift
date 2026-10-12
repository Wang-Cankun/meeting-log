import AppKit
import SwiftUI

/// Pending sessions (processing, queued, failed, waiting) followed by the three latest completed meetings.
struct RecentList: View {
    @ObservedObject var model: AppModel
    let openSummaries: (URL?) -> Void
    let showSettings: () -> Void

    private static let pendingLimit = 3
    /// Completed rows sit this far in; their text adds `rowTextInset` to reach the panel's text edge.
    static let rowInset: CGFloat = 8
    static let rowTextInset = PanelMetrics.textLeading - rowInset

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel("RECENT")
                Spacer()
                Button("All meetings") { openSummaries(nil) }
                    .buttonStyle(.link)
                    .foregroundStyle(.tint)
                    .font(.callout.weight(.medium))
                    .help("Open Meeting summaries")
            }
            .padding(.leading, PanelMetrics.textLeading)
            .padding(.trailing, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)

            if model.pendingItems.isEmpty && model.recentMeetings.isEmpty {
                Text("Completed meetings will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, PanelMetrics.textLeading)
                    .padding(.vertical, 6)
            }

            if !model.pendingItems.isEmpty {
                VStack(spacing: 8) {
                    ForEach(model.pendingItems.prefix(Self.pendingLimit)) { item in
                        PendingItemCard(model: model, item: item, showSettings: showSettings)
                    }
                    if model.pendingItems.count > Self.pendingLimit {
                        let extra = model.pendingItems.count - Self.pendingLimit
                        HStack {
                            Text("\(extra) more saved locally")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Show files") { model.showPendingMeetingsInFinder() }
                                .buttonStyle(.link)
                                .font(.subheadline)
                        }
                        .padding(.horizontal, PanelMetrics.textLeading - PanelMetrics.cardInset)
                    }
                }
                .padding(.horizontal, PanelMetrics.cardInset)
                .padding(.top, 2)
                .padding(.bottom, model.recentMeetings.isEmpty ? 0 : 6)
            }

            VStack(spacing: 2) {
                ForEach(model.recentMeetings) { meeting in
                    RecentMeetingRow(model: model, meeting: meeting, openSummaries: openSummaries)
                }
            }
            .padding(.horizontal, Self.rowInset)
        }
        .padding(.bottom, 12)
    }
}

private struct PendingItemCard: View {
    @ObservedObject var model: AppModel
    let item: PendingMeetingItem
    let showSettings: () -> Void

    private var heading: String { "\(item.title) · \(PanelDate.relative(item.startedAt, time: true))" }
    private static let cardRadius: CGFloat = 10
    private var project: String { model.projectDisplayName(item.projectName) }

    private static let retryHelp = "Retries all saved recordings once recording, import and processing finish."

    var body: some View {
        switch item.state {
        case .processing:
            progressCard(badge: "Processing", stage: model.processingProgress?.stage ?? .prepare,
                         detail: model.processingProgress?.detail ?? "Preparing")
        case .queued:
            progressCard(badge: "Queued", stage: nil, detail: "Waiting for the current meeting to finish.")
        case let .failed(message):
            PanelCard(tint: .orange, radius: Self.cardRadius) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.orange)
                            .frame(width: 16, height: 17)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            titleBlock
                            Text(Self.sentence(message) + " The recording is saved locally.")
                                .font(.callout)
                                .lineSpacing(1.5)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                    actions(retry: true, settings: !model.providerReady)
                        .padding(.leading, 25)
                }
                .padding(12)
            }
        case .waitingForProvider:
            noticeCard(symbol: "tray.full", text: "Set up processing in Settings to process this recording.",
                       retry: false, settings: true)
        case .needsRetry:
            noticeCard(symbol: "tray.full", text: "Saved locally, not processed yet.",
                       retry: true, settings: false)
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(heading)
                .font(.body.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(heading)
            Text(project)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func progressCard(badge: String, stage: ProcessingStage?, detail: String) -> some View {
        PanelCard(radius: Self.cardRadius) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    titleBlock
                    Spacer(minLength: 8)
                    Text(badge)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(stage == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(stage == nil ? AnyShapeStyle(PanelColors.hover) : AnyShapeStyle(Color.accentColor.opacity(0.12)),
                                    in: RoundedRectangle(cornerRadius: 5))
                        .fixedSize()
                }
                .accessibilityElement(children: .combine)
                StageBar(stage: stage)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
        }
    }

    private func noticeCard(symbol: String, text: String, retry: Bool, settings: Bool) -> some View {
        PanelCard(radius: Self.cardRadius) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 17)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        titleBlock
                        Text(text)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
                actions(retry: retry, settings: settings)
                    .padding(.leading, 25)
            }
            .padding(12)
        }
    }

    private func actions(retry: Bool, settings: Bool) -> some View {
        HStack(spacing: 8) {
            if retry {
                Button("Retry") { model.retryFailedProcessing() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canRetryProcessing)
                    .help(Self.retryHelp)
            }
            Button("Show files") { model.showInFinder(item.id) }
                .help("Show this recording's saved files in Finder")
            if settings {
                Button("Settings", action: showSettings)
                    .help("Set up processing in Settings")
            }
        }
        .controlSize(.regular)
    }

    private static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "Processing stopped before completion." }
        return ".!?。！？".contains(last) ? trimmed : trimmed + "."
    }
}

private struct RecentMeetingRow: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: AppModel
    let meeting: ArchivedMeeting
    let openSummaries: (URL?) -> Void
    @State private var hovered = false
    #if DEBUG
    @Environment(\.debugHoveredMeeting) private var debugHovered
    #endif

    private var meta: String {
        "\(model.projectDisplayName(meeting.projectName)) · \(PanelDate.relative(meeting.date))"
    }

    private var showsActions: Bool {
        #if DEBUG
        if debugHovered == meeting.url { return true }
        #endif
        return hovered
    }

    var body: some View {
        HStack(spacing: 6) {
            Button { openSummaries(meeting.url) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title)
                        .font(.body.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(meta)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let warning = meeting.captureWarning {
                        Label("Partial audio recovery", systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                            .help(warning)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open in Meeting summaries")
            .accessibilityLabel("Open summary for \(meeting.title)")
            .accessibilityValue(meeting.captureWarning == nil ? meta : "\(meta), partial audio recovery")
            // The ellipsis menu appears only on hover; VoiceOver reaches the same actions here.
            .accessibilityActions { voiceOverActions }

            // Both states share one fixed frame so the title never reflows on hover.
            Group {
                if showsActions {
                    Menu { actions } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 28, height: 28)
                            .background(PanelColors.card, in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .help("Meeting actions")
                    .accessibilityHidden(true)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 28, height: 28)
        }
        .padding(.leading, RecentList.rowTextInset)
        .padding(.trailing, 6)
        .padding(.vertical, 7)
        .background(showsActions ? PanelColors.hover : .clear, in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovered = $0 }
        .contextMenu { actions }
    }

    private func moveToProject() {
        model.meetingToMove = meeting
        openWindow(id: "move-meeting")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private var canDelete: Bool { !(model.isCaptureBusy || model.isChangingRecording || model.isProcessing) }

    @ViewBuilder private var actions: some View {
        Button("Regenerate summary…", systemImage: "arrow.clockwise") { openSummaries(meeting.url) }
        Button("Move to project…", systemImage: "folder.badge.arrowshape.forward", action: moveToProject)
            .disabled(!model.canMoveMeeting(meeting))
        Button("Show in Finder", systemImage: "folder") { model.showInFinder(meeting.url) }
        Divider()
        Button("Move to Trash", systemImage: "trash", role: .destructive) { model.deleteMeeting(meeting) }
            .disabled(!canDelete)
    }

    /// The menu's actions for VoiceOver; unavailable ones are left out rather than disabled.
    @ViewBuilder private var voiceOverActions: some View {
        Button("Regenerate summary…") { openSummaries(meeting.url) }
        if model.canMoveMeeting(meeting) { Button("Move to project…", action: moveToProject) }
        Button("Show in Finder") { model.showInFinder(meeting.url) }
        if canDelete { Button("Move to Trash") { model.deleteMeeting(meeting) } }
    }
}
