import AppKit
import SwiftUI

/// Pending sessions (processing, queued, failed, waiting) followed by the three latest completed meetings.
struct RecentList: View {
    @ObservedObject var model: AppModel
    let openSummaries: (URL?) -> Void
    let showSettings: () -> Void

    private static let pendingLimit = 3
    /// Rows and cards sit this far in; row text adds its own 10 pt to reach the panel's text edge.
    static let listInset = PanelMetrics.textLeading - 10

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel("RECENT")
                Spacer()
                Button("All meetings") { openSummaries(nil) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("Open Meeting summaries")
            }
            .padding(.horizontal, PanelMetrics.textLeading - Self.listInset)

            if model.pendingItems.isEmpty && model.recentMeetings.isEmpty {
                Text("Completed meetings will appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }

            ForEach(model.pendingItems.prefix(Self.pendingLimit)) { item in
                PendingItemCard(model: model, item: item, showSettings: showSettings)
                    .padding(.bottom, 2)
            }
            if model.pendingItems.count > Self.pendingLimit {
                let extra = model.pendingItems.count - Self.pendingLimit
                HStack {
                    Text("\(extra) more saved locally")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show files") { model.showPendingMeetingsInFinder() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                .padding(.horizontal, 10)
            }

            ForEach(model.recentMeetings) { meeting in
                RecentMeetingRow(model: model, meeting: meeting, openSummaries: openSummaries)
            }
        }
        .padding(.horizontal, Self.listInset)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
}

private struct PendingItemCard: View {
    @ObservedObject var model: AppModel
    let item: PendingMeetingItem
    let showSettings: () -> Void

    private var heading: String { "\(item.title) · \(PanelDate.relative(item.startedAt, time: true))" }
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
            PanelCard(tint: .orange) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .frame(width: 16)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            titleBlock
                            Text(Self.sentence(message) + " The recording is saved locally.")
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                    actions(retry: true, settings: !model.providerReady)
                        .padding(.leading, 26)
                }
                .padding(12)
            }
        case .waitingForProvider:
            noticeCard(symbol: "tray.full", text: "Configure an AI provider to process this recording.",
                       retry: false, settings: true)
        case .needsRetry:
            noticeCard(symbol: "tray.full", text: "Saved locally, not processed yet.",
                       retry: true, settings: false)
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(heading)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(heading)
            Text(project)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func progressCard(badge: String, stage: ProcessingStage?, detail: String) -> some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    titleBlock
                    Spacer(minLength: 8)
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(stage == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(stage == nil ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.accentColor.opacity(0.14)), in: Capsule())
                        .fixedSize()
                }
                .accessibilityElement(children: .combine)
                StageBar(stage: stage)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
        }
    }

    private func noticeCard(symbol: String, text: String, retry: Bool, settings: Bool) -> some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: symbol)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        titleBlock
                        Text(text)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
                actions(retry: retry, settings: settings)
                    .padding(.leading, 26)
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
                    .help("Configure an AI provider")
            }
        }
        .controlSize(.small)
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

    private var meta: String {
        "\(model.projectDisplayName(meeting.projectName)) · \(PanelDate.relative(meeting.date))"
    }

    var body: some View {
        HStack(spacing: 4) {
            Button { openSummaries(meeting.url) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(meta)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let warning = meeting.captureWarning {
                        Label("Partial audio recovery", systemImage: "exclamationmark.triangle")
                            .font(.caption)
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

            Menu { actions } label: {
                Image(systemName: "ellipsis").frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Meeting actions")
            .accessibilityLabel("Actions for \(meeting.title)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(hovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovered = $0 }
        .contextMenu { actions }
    }

    @ViewBuilder private var actions: some View {
        Button("Regenerate summary…", systemImage: "arrow.clockwise") { openSummaries(meeting.url) }
        Button("Move to project…", systemImage: "folder.badge.arrowshape.forward") {
            model.meetingToMove = meeting
            openWindow(id: "move-meeting")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        .disabled(!model.canMoveMeeting(meeting))
        Button("Show in Finder", systemImage: "folder") { model.showInFinder(meeting.url) }
        Divider()
        Button("Move to Trash", systemImage: "trash", role: .destructive) { model.deleteMeeting(meeting) }
            .disabled(model.isCaptureBusy || model.isChangingRecording || model.isProcessing)
    }
}
