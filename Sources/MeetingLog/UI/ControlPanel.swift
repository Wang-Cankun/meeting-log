import AppKit
import SwiftUI

struct ControlPanel: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var model: AppModel
    @ObservedObject private var audioLevels: AudioLevels

    init(model: AppModel) {
        self.model = model
        _audioLevels = ObservedObject(wrappedValue: model.audioLevels)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 0) {
                audioSources
                Divider().padding(.leading, 44)
                screenRow
                Divider().padding(.leading, 44)
                projectRow
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
            .padding(.horizontal, 16)

            HStack(spacing: 10) {
                recordingControl
                Button {
                    openWindow(id: "import-audio")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                } label: {
                    Label("Import audio", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .help("Import a recording from your iPhone or Mac")
            }
            .padding(16)

            if showsProcessingStatus {
                processingStatus
            }
            Divider()
            recentMeetings
            footer
        }
        .foregroundStyle(.primary)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: 400)
        .onAppear { model.panelDidOpen() }
        .onDisappear { model.panelDidClose() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Group {
                if model.phase == .idle {
                    MeetingMark().fill(.tint).frame(width: 30, height: 23)
                } else {
                    Image(systemName: headerSymbol).font(.title2)
                }
            }
                .foregroundStyle(headerSymbolColor)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                if case let .recording(startedAt) = model.phase {
                    Text(startedAt, style: .timer)
                        .font(.title2.weight(.semibold).monospacedDigit())
                } else {
                    Text("MeetingLog")
                        .font(.title3.weight(.semibold))
                }
                Text(model.phase == .idle && model.canStartRecording ? "Record a meeting or import audio" : model.statusText)
                    .font(.caption)
                    .foregroundStyle(headerStatusColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .accessibilityElement(children: .combine)
    }

    private var headerSymbol: String {
        if case .failed = model.phase { return "exclamationmark.triangle" }
        return model.isRecording ? "record.circle.fill" : "waveform"
    }

    private var headerSymbolColor: Color {
        if case .failed = model.phase { return .orange }
        return model.isRecording ? .red : .secondary
    }

    private var headerStatusColor: Color {
        if case .failed = model.phase { return .orange }
        return model.isRecording ? .red : .secondary
    }

    private var audioSources: some View {
        VStack(spacing: 0) {
            systemAudioRow.padding(.vertical, 10)
            Divider().padding(.leading, 34)
            microphoneRow.padding(.vertical, 10)
        }
        .padding(.horizontal, 16)
    }

    private var systemAudioRow: some View {
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Mac audio").font(.body.weight(.medium))
                    Text(model.systemAudioStateText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                systemAudioMenu
                    .frame(maxWidth: 150, alignment: .trailing)
            }
            LevelMeter(
                source: "Mac audio",
                state: model.systemAudioStateText,
                level: audioLevels.system,
                enabled: model.systemAudioError == nil && model.selectedSystemAudioIsAvailable
            )
            .padding(.leading, 34)
            if model.systemAudioError != nil {
                HStack {
                    Spacer()
                    Button("Open System Settings") { model.openSystemAudioPrivacy() }
                        .controlSize(.small)
                }
                .padding(.leading, 34)
            }
        }
    }

    private var systemAudioMenu: some View {
        Menu {
            Button { model.selectSystemAudio(nil) } label: {
                if model.selectedSystemAudioBundleID == nil {
                    Label("All apps", systemImage: "checkmark")
                } else {
                    Text("All apps")
                }
            }
            if !model.applications.isEmpty {
                Divider()
                ForEach(model.applications) { application in
                    Button { model.selectSystemAudio(application) } label: {
                        if model.selectedSystemAudioBundleID == application.bundleIdentifier {
                            Label(application.name, systemImage: "checkmark")
                        } else {
                            Text(application.name)
                        }
                    }
                }
            }
        } label: {
            Text(model.selectedSystemAudioBundleID == nil ? "All apps" : model.selectedSystemAudioName)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 130, alignment: .leading)
        }
        .menuStyle(.button)
        .controlSize(.small)
        .disabled(model.isRecording || model.isChangingRecording)
        .accessibilityLabel("Mac audio source")
    }

    private var microphoneRow: some View {
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                Image(systemName: model.microphoneEnabled ? "mic.fill" : "mic.slash")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Microphone").font(.body.weight(.medium))
                    Text(model.microphoneStateText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Toggle("Include microphone", isOn: Binding(
                    get: { model.microphoneEnabled },
                    set: { model.setMicrophoneEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(model.isRecording || model.isChangingRecording)
            }
            if model.microphoneEnabled {
                Menu {
                    Button("System default") { model.selectMicrophone(nil) }
                    ForEach(model.microphones, id: \.uniqueID) { device in
                        Button(device.localizedName) { model.selectMicrophone(device.uniqueID) }
                    }
                } label: {
                    Text(selectedMicrophoneName).lineLimit(1).truncationMode(.middle)
                }
                .menuStyle(.button)
                .controlSize(.small)
                .disabled(model.isRecording || model.isChangingRecording)
                .accessibilityLabel("Microphone device")
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 34)
                LevelMeter(
                    source: "Microphone",
                    state: model.microphoneStateText,
                    level: audioLevels.microphone,
                    enabled: model.microphoneEnabled
                        && model.microphonePermission == .authorized
                        && !model.microphones.isEmpty
                )
                .padding(.leading, 34)
            }
            if model.microphoneEnabled,
               model.microphonePermission == .denied || model.microphonePermission == .restricted {
                HStack {
                    Spacer()
                    Button("Open System Settings") { model.openMicrophonePrivacy() }
                        .controlSize(.small)
                }
                .padding(.leading, 34)
            }
        }
    }

    private var screenRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle")
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Screen video").font(.body.weight(.medium))
                Text(model.videoEnabled ? model.selectedScreenSource ?? "Choose a source" : "Optional")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            HStack(spacing: 10) {
                if model.videoEnabled {
                    Button(model.hasScreenSource ? "Change…" : "Choose…") { model.chooseScreen() }
                        .controlSize(.small)
                        .frame(width: 108, alignment: .trailing)
                        .disabled(model.isRecording || model.isChangingRecording)
                }
                Toggle("Record screen", isOn: Binding(
                    get: { model.videoEnabled },
                    set: { model.setVideoEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(model.isRecording || model.isChangingRecording)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var projectRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text("Project").font(.body.weight(.medium))
            Spacer(minLength: 12)
            projectMenu
                .frame(maxWidth: 220, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var projectMenu: some View {
        ProjectChooser(projects: model.projects, selection: Binding(
            get: { model.selectedProjectName ?? ArchiveStore.inboxName },
            set: { model.selectProject($0) }
        ), refresh: model.refreshArchive)
        .frame(maxWidth: 210)
    }

    private var showsProcessingStatus: Bool {
        model.isProcessing || model.processingFailureCount > 0 || model.waitingForProcessingCount > 0
    }

    private var processingStatus: some View {
        HStack(spacing: 10) {
            Image(systemName: processingSymbol)
                .foregroundStyle(model.processingFailureCount > 0 ? .orange : .secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(processingTitle).font(.callout.weight(.medium))
                if let detail = processingDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if model.processingFailureCount > 0 {
                Button("Retry") { model.retryFailedProcessing() }
                    .controlSize(.small)
                    .disabled(!model.canRetryProcessing)
                    .help("Retry is available when recording, import, and processing finish.")
            } else if !model.keySaved && model.waitingForProcessingCount > 0 {
                Button("Settings") { showSettings() }.controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var processingTitle: String {
        if model.processingFailureCount > 0 { return "Processing needs attention" }
        if model.isProcessing { return "Processing recording" }
        return "Saved locally"
    }

    private var processingDetail: String? {
        if let text = model.processingText { return text }
        guard model.waitingForProcessingCount > 0 else { return nil }
        let noun = model.waitingForProcessingCount == 1 ? "recording" : "recordings"
        if !model.keySaved { return "Configure an AI provider to process \(model.waitingForProcessingCount) \(noun)." }
        return "\(model.waitingForProcessingCount) \(noun) waiting."
    }

    private var processingSymbol: String {
        if model.processingFailureCount > 0 { return "exclamationmark.triangle" }
        if model.isProcessing { return "clock.arrow.2.circlepath" }
        return "tray.full"
    }

    private var recordingControl: some View {
        Button { model.toggleRecording() } label: {
            Label(
                model.isRecording ? "Stop recording" : "Start recording",
                systemImage: model.isRecording ? "stop.circle.fill" : "record.circle.fill"
            )
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(model.isRecording ? .red : .accentColor)
        .controlSize(.large)
        .disabled(model.isChangingRecording || (!model.isRecording && !model.canStartRecording))
    }

    private var recentMeetings: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Recent meetings")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("All meetings") {
                    openWindow(id: "meeting-summaries")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if model.recentMeetings.isEmpty {
                Text("Completed meetings will appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            } else {
                ForEach(model.recentMeetings) { meeting in
                    HStack(spacing: 8) {
                        Button { model.showInFinder(meeting.url) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(meeting.title)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Text("\(meeting.projectName) · \(meeting.date.formatted(.dateTime.month(.abbreviated).day().year()))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Show \(meeting.title) in Finder")

                        Menu {
                            Button("Regenerate summary…", systemImage: "arrow.clockwise") {
                                model.summaryOpenRequest = SummaryOpenRequest(url: meeting.url)
                                openWindow(id: "meeting-summaries")
                                NSApplication.shared.activate(ignoringOtherApps: true)
                            }
                            Button("Show in Finder", systemImage: "folder") { model.showInFinder(meeting.url) }
                            Divider()
                            Button("Move to Trash", systemImage: "trash", role: .destructive) { model.deleteMeeting(meeting) }
                                .disabled(model.isRecording || model.isChangingRecording || model.isProcessing)
                        } label: {
                            Image(systemName: "ellipsis").frame(width: 24, height: 24)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("Actions for \(meeting.title)")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { showSettings() } label: {
                Label("Settings", systemImage: "gearshape")
            }
            Spacer()
            Button(role: .destructive) { NSApplication.shared.terminate(nil) } label: {
                Text("Quit")
                    .padding(.vertical, 4)
            }
            .help("Quit MeetingLog")
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var selectedMicrophoneName: String {
        model.microphones.first { $0.uniqueID == model.selectedMicrophoneID }?.localizedName ?? "Default"
    }

    private func showSettings() {
        openSettings()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

}

private struct LevelMeter: View {
    let source: String
    let state: String
    let level: Float
    let enabled: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(nsColor: .separatorColor).opacity(0.45))
                Capsule()
                    .fill(meterColor)
                    .frame(width: max(0, proxy.size.width * CGFloat(enabled ? level : 0)))
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel("\(source) level")
        .accessibilityValue("\(state), \(Int(level * 100)) percent")
    }

    private var meterColor: Color {
        switch AudioLevelState(level: level) {
        case .silence, .active: .green
        case .high: .orange
        case .clipping: .red
        }
    }
}
