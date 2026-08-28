import AppKit
import SwiftUI

struct ControlPanel: View {
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
            Divider()
            audioSources
            Divider()
            screenRow
            if showsProcessingStatus {
                Divider()
                processingStatus
            }
            Divider()
            recentMeetings
            Divider()
            recordingControl
            footer
        }
        .foregroundStyle(.primary)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: 360)
        .onAppear { model.panelDidOpen() }
        .onDisappear { model.panelDidClose() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: model.isRecording ? "record.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(model.isRecording ? Color.red : Color.secondary.opacity(0.5))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                if case let .recording(startedAt) = model.phase {
                    Text(startedAt, style: .timer)
                        .font(.title2.weight(.semibold).monospacedDigit())
                } else {
                    Text("00:00")
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(model.statusText)
                    .font(.caption)
                    .foregroundStyle(model.isRecording ? .red : .secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
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
                .frame(maxWidth: 128, alignment: .trailing)
        }
        .menuStyle(.borderlessButton)
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
                if model.microphoneEnabled {
                    Menu {
                        Button("System default") { model.selectMicrophone(nil) }
                        ForEach(model.microphones, id: \.uniqueID) { device in
                            Button(device.localizedName) { model.selectMicrophone(device.uniqueID) }
                        }
                    } label: {
                        Text(selectedMicrophoneName)
                            .lineLimit(1)
                            .frame(maxWidth: 104, alignment: .trailing)
                    }
                    .menuStyle(.borderlessButton)
                    .disabled(model.isRecording || model.isChangingRecording)
                    .accessibilityLabel("Microphone device")
                }
                Toggle("Include microphone", isOn: Binding(
                    get: { model.microphoneEnabled },
                    set: { model.setMicrophoneEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(model.isRecording || model.isChangingRecording)
            }
            LevelMeter(
                source: "Microphone",
                state: model.microphoneStateText,
                level: audioLevels.microphone,
                enabled: model.microphoneEnabled
                    && model.microphonePermission == .authorized
                    && !model.microphones.isEmpty
            )
            .padding(.leading, 34)
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
                Text("Record screen").font(.body.weight(.medium))
                Text(model.videoEnabled ? model.selectedScreenSource ?? "Choose a source" : "Not included")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if model.videoEnabled {
                Button(model.hasScreenSource ? "Change…" : "Choose…") { model.chooseScreen() }
                    .controlSize(.small)
                    .disabled(model.isRecording || model.isChangingRecording)
            }
            Toggle("Record screen", isOn: Binding(
                get: { model.videoEnabled },
                set: { model.setVideoEnabled($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(model.isRecording || model.isChangingRecording)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
                    .disabled(model.isRecording || model.isChangingRecording)
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
        if !model.keySaved { return "Add an OpenRouter key to process \(model.waitingForProcessingCount) \(noun)." }
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
                model.isRecording ? "Stop recording" : "Record",
                systemImage: model.isRecording ? "stop.circle.fill" : "record.circle"
            )
            .font(.body.weight(.semibold))
            .frame(minWidth: 140)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .controlSize(.large)
        .disabled(model.isChangingRecording || (!model.isRecording && !model.canStartRecording))
        .padding(.vertical, 12)
    }

    private var recentMeetings: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Recent meetings")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Show All in Finder") { model.showArchiveInFinder() }
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
                                    .lineLimit(1)
                                Text("\(meeting.projectName) · \(meeting.dateText)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Show \(meeting.title) in Finder")

                        Button(role: .destructive) { model.deleteMeeting(meeting) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.isRecording || model.isChangingRecording || model.isProcessing)
                        .accessibilityLabel("Delete \(meeting.title)")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Settings") { showSettings() }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
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
