import AppKit
import SwiftUI

/// The menu bar panel: ready (sources, destination, Recent), recording, or saving.
struct ControlPanel: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            switch model.phase {
            case let .recording(startedAt):
                RecordingStatusView(model: model, startedAt: startedAt, showSettings: showSettings)
                feedback
            case let .saving(duration, step):
                SavingStatusView(model: model, duration: duration, step: step, showSettings: showSettings)
                feedback
            case .idle, .failed:
                ready
            }
        }
        .foregroundStyle(.primary)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: 400)
        .animation(.snappy(duration: 0.25), value: phaseKind)
        .onAppear { model.panelDidOpen() }
        .onDisappear { model.panelDidClose() }
    }

    /// Animates between layouts without animating every saving-step change.
    private var phaseKind: Int {
        switch model.phase {
        case .idle, .failed: 0
        case .recording: 1
        case .saving: 2
        }
    }

    private var ready: some View {
        VStack(spacing: 0) {
            header
            SourcesCard(model: model)

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("SAVE TO").padding(.leading, PanelMetrics.textLeading - PanelMetrics.cardInset)
                ProjectChooser(projects: model.projects, selection: Binding(
                    get: { model.selectedProjectName ?? ArchiveStore.inboxName },
                    set: { model.selectProject($0) }
                ), refresh: model.refreshArchive)
                .frame(maxWidth: .infinity)
                .disabled(!model.canSelectRecordingProject)
                .help(model.canSelectRecordingProject ? "Choose where to save the next recording" : "This recording's destination is fixed until recording stops")
            }
            .padding(.horizontal, PanelMetrics.cardInset)
            .padding(.top, 14)

            Button { model.toggleRecording() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "record.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.red, .white)
                    Text("Start recording")
                }
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            .disabled(model.isChangingRecording || !model.canStartRecording)
            .help(model.canStartRecording ? "Start recording to the selected project" : model.statusText)
            .padding(.horizontal, PanelMetrics.cardInset)
            .padding(.top, 12)
            .padding(.bottom, 12)

            feedback
            Divider()
            RecentList(model: model, openSummaries: openSummaries, showSettings: showSettings)
        }
    }

    private var isFailed: Bool {
        if case .failed = model.phase { true } else { false }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Group {
                if isFailed {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.orange)
                } else {
                    MeetingMark().fill(.tint).frame(width: 28, height: 22)
                }
            }
            .frame(width: 30)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("MeetingLog").font(.headline)
                Text(model.phase == .idle && model.canStartRecording ? "Ready to record" : model.statusText)
                    .font(.caption)
                    .foregroundStyle(isFailed ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)

            Button {
                openWindow(id: "import-audio")
                NSApplication.shared.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .frame(width: PanelMetrics.iconButton, height: PanelMetrics.iconButton)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Import a recording from your iPhone or Mac")
            .accessibilityLabel("Import audio")

            PanelMoreMenu(showSettings: showSettings)
        }
        .padding(.leading, PanelMetrics.textLeading)
        .padding(.trailing, 12)
        .padding(.vertical, 14)
    }

    @ViewBuilder private var feedback: some View {
        if let notice = model.notice {
            noticeBanner(notice)
        }
        if let retry = model.missingProjectRetry {
            missingProjectPrompt(retry)
        }
    }

    private func noticeBanner(_ notice: PanelNotice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: notice.isError ? "exclamationmark.triangle" : "checkmark.circle")
                .foregroundStyle(notice.isError ? .orange : .secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(notice.message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let undo = notice.undo {
                Button("Undo", action: undo).controlSize(.small)
            }
            Button { model.dismissNotice() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .task(id: notice.id) {
            guard !notice.isError else { return }
            try? await Task.sleep(for: .seconds(8))
            if model.notice?.id == notice.id { model.dismissNotice() }
        }
    }

    private func missingProjectPrompt(_ retry: MissingProjectRetry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(retry.count) pending \(retry.count == 1 ? "meeting refers" : "meetings refer") to a missing project. Retry in \(retry.displayPath)? Audio and completed transcripts are kept.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { model.cancelMissingProjectRetry() }
                Button("Use this project") { model.confirmMissingProjectRetry() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canRetryProcessing)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    /// Opens Meeting summaries, preselecting `url` through the shared open request.
    /// Without a URL any earlier request is dropped, so the window opens on its default selection.
    private func openSummaries(_ url: URL?) {
        model.summaryOpenRequest = url.map { SummaryOpenRequest(url: $0) }
        openWindow(id: "meeting-summaries")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func showSettings() {
        openSettings()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
