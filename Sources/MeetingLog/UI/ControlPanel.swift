import SwiftUI

struct ControlPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            audioSection
            Divider()
            screenSection
            if model.isProcessing || model.processingFailureCount > 0 {
                Divider()
                processingStatus
            }
            Divider()
            recordingControl
            footer
        }
        .foregroundStyle(.primary)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: 400)
        .preferredColorScheme(.light)
        .onAppear { model.panelDidOpen() }
        .onDisappear { model.panelDidClose() }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("MeetingLog")
                    .font(.headline)
                Text(model.statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            if case let .recording(startedAt) = model.phase {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Label(elapsed(from: startedAt, to: context.date), systemImage: "record.circle.fill")
                        .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Audio sources")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 5)

            systemAudioRow
                .padding(.vertical, 9)
            Divider().padding(.leading, 34)
            microphoneRow
                .padding(.vertical, 9)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var systemAudioRow: some View {
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("System audio").font(.body.weight(.medium))
                    Label(
                        model.systemAudioStateText,
                        systemImage: stateSymbol(
                            for: model.systemAudioLevel,
                            ready: model.systemAudioError == nil && model.selectedSystemAudioIsAvailable
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                systemAudioMenu
            }
            LevelMeter(
                source: "System audio",
                state: model.systemAudioStateText,
                level: model.systemAudioLevel,
                enabled: model.systemAudioError == nil && model.selectedSystemAudioIsAvailable
            )
            .padding(.leading, 34)
        }
    }

    private var systemAudioMenu: some View {
        Menu {
            Button {
                model.selectSystemAudio(nil)
            } label: {
                if model.selectedSystemAudioBundleID == nil {
                    Label("All Mac audio", systemImage: "checkmark")
                } else {
                    Text("All Mac audio")
                }
            }
            if !model.applications.isEmpty {
                Divider()
                ForEach(model.applications) { application in
                    Button {
                        model.selectSystemAudio(application)
                    } label: {
                        if model.selectedSystemAudioBundleID == application.bundleIdentifier {
                            Label(application.name, systemImage: "checkmark")
                        } else {
                            Text(application.name)
                        }
                    }
                }
            }
        } label: {
            Text(model.selectedSystemAudioName)
                .lineLimit(1)
                .frame(maxWidth: 150, alignment: .trailing)
        }
        .menuStyle(.borderlessButton)
        .frame(minHeight: 40)
        .disabled(model.isRecording)
        .accessibilityLabel("System audio source")
    }

    private var microphoneRow: some View {
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                Image(systemName: model.microphoneEnabled ? "mic.fill" : "mic.slash")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Microphone").font(.body.weight(.medium))
                    Label(
                        model.microphoneStateText,
                        systemImage: model.microphoneEnabled
                            ? stateSymbol(for: model.microphoneLevel, ready: model.microphonePermission == .authorized && !model.microphones.isEmpty)
                            : "mic.slash"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("Include", isOn: Binding(
                    get: { model.microphoneEnabled },
                    set: { model.setMicrophoneEnabled($0) }
                ))
                .toggleStyle(.switch)
                .disabled(model.isRecording)
            }
            HStack(spacing: 6) {
                Menu {
                    Button("System default") { model.selectMicrophone(nil) }
                    ForEach(model.microphones, id: \.uniqueID) { device in
                        Button(device.localizedName) { model.selectMicrophone(device.uniqueID) }
                    }
                } label: {
                    Text(selectedMicrophoneName)
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                Button(model.isTestingMicrophone ? "Testing…" : "Test") { model.testMicrophone() }
                    .frame(minHeight: 40)
            }
            .padding(.leading, 34)
            .disabled(!model.microphoneEnabled || model.isRecording || model.isTestingMicrophone)
            LevelMeter(
                source: "Microphone",
                state: model.microphoneStateText,
                level: model.microphoneLevel,
                enabled: model.microphoneEnabled && model.microphonePermission == .authorized && !model.microphones.isEmpty
            )
            .padding(.leading, 34)
        }
    }

    private var screenSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Video")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Image(systemName: "rectangle.on.rectangle")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Record screen").font(.body.weight(.medium))
                    Text(model.videoEnabled
                        ? model.selectedScreenSource ?? "Choose a window, application, or display"
                        : "Audio only")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Toggle("Record screen", isOn: Binding(
                    get: { model.videoEnabled },
                    set: { model.setVideoEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(model.isRecording)
            }
            if model.videoEnabled {
                HStack {
                    Spacer()
                    Button(model.hasScreenSource ? "Change…" : "Choose Screen…") {
                        model.chooseScreen()
                    }
                    .disabled(model.isRecording)
                    .frame(minHeight: 40)
                }
                .padding(.leading, 34)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var processingStatus: some View {
        HStack(spacing: 10) {
            Image(systemName: model.processingFailureCount > 0 ? "exclamationmark.triangle" : "clock.arrow.2.circlepath")
                .foregroundStyle(model.processingFailureCount > 0 ? .orange : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.processingFailureCount > 0
                    ? "\(model.processingFailureCount) meeting needs attention"
                    : "Processing \(model.processingCount) meeting")
                    .font(.callout.weight(.medium))
                if let text = model.processingText {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if model.processingFailureCount > 0 {
                Button("Retry") { model.retryFailedProcessing() }
                    .frame(minHeight: 40)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var recordingControl: some View {
        VStack(spacing: 8) {
            if !model.keySaved {
                HStack(spacing: 6) {
                    Label("OpenRouter setup required", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SettingsLink {
                        Text("Open Settings…")
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            Button { model.toggleRecording() } label: {
                Label(
                    model.isRecording ? "Stop recording" : "Start recording",
                    systemImage: model.isRecording ? "stop.circle.fill" : "record.circle"
                )
                .font(.body.weight(.semibold))
                .foregroundStyle(.red)
                .frame(minWidth: 168, minHeight: 40)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(!model.isRecording && !model.canStartRecording)
        }
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            SettingsLink {
                Text("Settings…")
            }
            Button("Open archive") { model.openArchive() }
                .disabled(model.archiveRootPath.isEmpty)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.bottom, 13)
    }

    private var selectedMicrophoneName: String {
        model.microphones.first { $0.uniqueID == model.selectedMicrophoneID }?.localizedName ?? "System default"
    }

    private var appIcon: NSImage {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let image = NSImage(contentsOf: url)
        else { return NSApplication.shared.applicationIconImage }
        return image
    }

    private var statusColor: Color {
        if case .failed = model.phase { return .orange }
        return model.isRecording ? .red : .secondary
    }

    private func stateSymbol(for level: Float, ready: Bool) -> String {
        if !ready { return "exclamationmark.circle" }
        return level < 0.03 ? "minus.circle" : "waveform"
    }

    private func elapsed(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
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
        .frame(height: 6)
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
