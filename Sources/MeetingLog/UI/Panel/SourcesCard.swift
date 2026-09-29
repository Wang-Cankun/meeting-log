import SwiftUI

/// Mac audio, microphone and screen video settings; collapses to one line of per-source meters.
struct SourcesCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var audioLevels: AudioLevels
    @AppStorage("sourcesExpanded") private var sourcesExpanded = false

    init(model: AppModel) {
        self.model = model
        _audioLevels = ObservedObject(wrappedValue: model.audioLevels)
    }

    var body: some View {
        PanelCard {
            if showsDetails { expanded } else { collapsed }
        }
        .padding(.horizontal, PanelMetrics.cardInset)
        .animation(.snappy(duration: 0.2), value: showsDetails)
    }

    /// Source settings rarely change between meetings, so they collapse unless something needs attention.
    private var sourcesNeedAttention: Bool {
        model.systemAudioError != nil
            || !model.selectedSystemAudioIsAvailable
            || (model.videoEnabled && !model.hasScreenSource)
            || (model.microphoneEnabled && (model.microphones.isEmpty
                || model.microphonePermission == .denied || model.microphonePermission == .restricted))
    }

    private var showsDetails: Bool { sourcesExpanded || sourcesNeedAttention }

    private var locked: Bool { model.isCaptureBusy || model.isChangingRecording }

    private var systemAudioLabel: String {
        model.selectedSystemAudioBundleID == nil ? "All apps" : model.selectedSystemAudioName
    }

    private var microphoneBlocked: Bool {
        model.microphonePermission == .denied || model.microphonePermission == .restricted
    }

    private var sourceSummaryText: String {
        var parts = [systemAudioLabel]
        parts.append(model.microphoneEnabled ? model.selectedMicrophoneLabel : "No mic")
        parts.append(model.videoEnabled ? model.selectedScreenSource ?? "Screen" : "No video")
        return parts.joined(separator: " · ")
    }

    // MARK: Expanded

    private var expanded: some View {
        VStack(spacing: 0) {
            HStack {
                SectionLabel("SOURCES")
                Spacer()
                if !sourcesNeedAttention {
                    Button { sourcesExpanded = false } label: {
                        Image(systemName: "chevron.up")
                            .font(.caption.weight(.semibold))
                            .frame(width: 20, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Collapse sources")
                    .accessibilityLabel("Collapse sources")
                }
            }
            .padding(.leading, PanelMetrics.rowInset)
            .padding(.trailing, 10)
            .padding(.top, 10)

            systemAudioRow
            Divider().padding(.leading, PanelMetrics.contentLeading)
            microphoneRow
            Divider().padding(.leading, PanelMetrics.contentLeading)
            screenRow
        }
    }

    private var systemAudioRow: some View {
        SourceRow(icon: "speaker.wave.2.fill", name: "Mac audio", status: model.systemAudioStateText,
                  statusColor: model.systemAudioError != nil || !model.selectedSystemAudioIsAvailable ? .orange : .secondary) {
            Text("Always")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Mac audio is always recorded")
        } details: {
            Menu {
                Button { model.selectSystemAudio(nil) } label: {
                    if model.selectedSystemAudioBundleID == nil {
                        Label("All apps", systemImage: "checkmark")
                    } else {
                        Text("All apps")
                    }
                }
                if !model.selectedSystemAudioIsAvailable {
                    Divider()
                    Label("\(model.selectedSystemAudioName) (unavailable)", systemImage: "checkmark")
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
                SourcePickerLabel(text: systemAudioLabel)
            }
            .sourcePickerStyle()
            .disabled(locked)
            .accessibilityLabel("Mac audio source")
            .accessibilityValue(systemAudioLabel)

            LevelMeter(
                source: "Mac audio",
                state: model.systemAudioStateText,
                level: audioLevels.system,
                enabled: model.systemAudioError == nil && model.selectedSystemAudioIsAvailable
            )
            if model.systemAudioError != nil {
                Button("Open System Settings") { model.openSystemAudioPrivacy() }
                    .controlSize(.small)
                    .help("Allow MeetingLog to record system audio")
            }
        }
    }

    private var microphoneRow: some View {
        SourceRow(icon: model.microphoneEnabled ? "mic.fill" : "mic.slash", name: "Microphone",
                  status: model.microphoneStateText,
                  statusColor: model.microphoneEnabled && (microphoneBlocked || model.microphones.isEmpty) ? .orange : .secondary) {
            Toggle("Include microphone", isOn: Binding(
                get: { model.microphoneEnabled },
                set: { model.setMicrophoneEnabled($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(locked)
            .help(model.microphoneEnabled ? "Microphone is included" : "Microphone is not included")
        } details: {
            Menu {
                Button { model.selectMicrophone(nil) } label: {
                    if model.selectedMicrophoneID == nil {
                        Label("System default", systemImage: "checkmark")
                    } else {
                        Text("System default")
                    }
                }
                if !model.microphones.isEmpty {
                    Divider()
                    ForEach(model.microphones, id: \.uniqueID) { device in
                        Button { model.selectMicrophone(device.uniqueID) } label: {
                            if model.selectedMicrophoneID == device.uniqueID {
                                Label(device.localizedName, systemImage: "checkmark")
                            } else {
                                Text(device.localizedName)
                            }
                        }
                    }
                }
            } label: {
                SourcePickerLabel(text: model.selectedMicrophoneLabel, placeholder: !model.microphoneEnabled)
            }
            .sourcePickerStyle()
            .disabled(locked || !model.microphoneEnabled)
            .accessibilityLabel("Microphone device")
            .accessibilityValue(model.selectedMicrophoneLabel)

            // Kept while the microphone is off so the card does not jump when it is toggled.
            LevelMeter(
                source: "Microphone",
                state: model.microphoneStateText,
                level: audioLevels.microphone,
                enabled: model.microphoneEnabled
                    && model.microphonePermission == .authorized
                    && !model.microphones.isEmpty
            )
            if model.microphoneEnabled, microphoneBlocked {
                Button("Open System Settings") { model.openMicrophonePrivacy() }
                    .controlSize(.small)
                    .help("Allow MeetingLog to use the microphone")
            }
        }
    }

    private var screenStatus: (String, Color) {
        guard model.videoEnabled else { return ("Off", .secondary) }
        return model.hasScreenSource ? ("On", .secondary) : ("Choose a source", .orange)
    }

    private var screenRow: some View {
        SourceRow(icon: "rectangle.on.rectangle", name: "Screen video",
                  status: screenStatus.0, statusColor: screenStatus.1) {
            Toggle("Record screen", isOn: Binding(
                get: { model.videoEnabled },
                set: { model.setVideoEnabled($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(locked)
            .help(model.videoEnabled ? "Screen video is recorded" : "Screen video is off")
        } details: {
            // Clicking opens the system content picker directly; the menu offers the same action.
            Menu {
                Button("Choose display, window or app…") { model.chooseScreen() }
            } label: {
                SourcePickerLabel(
                    text: model.videoEnabled ? model.selectedScreenSource ?? "Choose display, window or app…" : "Display, window or app",
                    placeholder: !model.videoEnabled || !model.hasScreenSource
                )
            } primaryAction: {
                model.chooseScreen()
            }
            .sourcePickerStyle()
            .disabled(locked || !model.videoEnabled)
            .accessibilityLabel("Screen source")
            .accessibilityValue(model.selectedScreenSource ?? "None")
        }
    }

    // MARK: Collapsed

    private var collapsed: some View {
        Button { sourcesExpanded = true } label: {
            HStack(spacing: 12) {
                // Equal priority and a minimum name width, so no source, video included, truncates away.
                MiniSource(icon: "speaker.wave.2.fill", name: systemAudioLabel, level: systemAudioLevel)
                MiniSource(icon: model.microphoneEnabled ? "mic.fill" : "mic.slash",
                           name: model.microphoneEnabled ? model.selectedMicrophoneLabel : "No mic",
                           level: model.microphoneEnabled ? audioLevels.microphone : nil)
                MiniSource(icon: model.videoEnabled ? "rectangle.on.rectangle" : "rectangle.on.rectangle.slash",
                           name: model.videoEnabled ? model.selectedScreenSource ?? "Screen" : "No video",
                           level: nil, showsMeter: false)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, PanelMetrics.rowInset)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show audio and screen sources")
        .accessibilityLabel("Sources: \(sourceSummaryText)")
        .accessibilityValue(levelSummaryText)
        .accessibilityHint("Shows source settings")
    }

    private var systemAudioLevel: Float? {
        model.systemAudioError == nil && model.selectedSystemAudioIsAvailable ? audioLevels.system : nil
    }

    /// The collapsed row replaces its children for VoiceOver, so it speaks each meter's state here.
    private var levelSummaryText: String {
        let system = systemAudioLevel.map { AudioLevelState(level: $0).label } ?? "Unavailable"
        let microphone = model.microphoneEnabled ? AudioLevelState(level: audioLevels.microphone).label : "Off"
        return "Mac audio: \(system). Microphone: \(microphone)."
    }
}

private extension View {
    /// Identical full-width look for the Mac audio, microphone and screen pickers.
    /// Standard menu button styles size to their title, so a custom style keeps the label's full width.
    func sourcePickerStyle() -> some View {
        menuStyle(.button)
            .buttonStyle(SourcePickerButtonStyle())
            .menuIndicator(.hidden)
            .focusEffectDisabled()
            .frame(maxWidth: .infinity)
    }
}
