import SwiftUI

/// Panel while capturing: elapsed timer, fixed destination, per-track meters and Stop.
struct RecordingStatusView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var audioLevels: AudioLevels
    let startedAt: Date
    let showSettings: () -> Void
    @ScaledMetric(relativeTo: .largeTitle) private var timerSize: CGFloat = 44

    init(model: AppModel, startedAt: Date, showSettings: @escaping () -> Void) {
        self.model = model
        self.startedAt = startedAt
        self.showSettings = showSettings
        _audioLevels = ObservedObject(wrappedValue: model.audioLevels)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text("RECORDING")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                    Spacer()
                    PanelMoreMenu(showSettings: showSettings)
                }
                Text(startedAt, style: .timer)
                    .font(.system(size: timerSize, weight: .semibold).monospacedDigit())
                    .accessibilityLabel("Elapsed time")
                    .accessibilityValue(Text(startedAt, style: .timer))
                Label("Saving to \(model.recordingDestinationPath ?? ArchiveStore.inboxName)", systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.recordingDestinationPath ?? ArchiveStore.inboxName)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, PanelMetrics.textLeading)
            .padding(.trailing, 12)
            .padding(.top, 10)
            .padding(.bottom, 14)

            tracks
                .padding(.horizontal, PanelMetrics.cardInset)

            Button { model.toggleRecording() } label: {
                Label("Stop recording", systemImage: "stop.fill")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.extraLarge)
            .disabled(model.isChangingRecording)
            .padding(.horizontal, PanelMetrics.cardInset)
            .padding(.top, 14)

            Text("Sources are locked until this recording stops.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
    }

    private var tracks: some View {
        PanelCard {
            VStack(spacing: 0) {
                TrackRow(
                    icon: "speaker.wave.2.fill",
                    name: "Mac audio",
                    caption: "\(model.selectedSystemAudioBundleID == nil ? "All Mac audio" : model.selectedSystemAudioName) · \(AudioLevelState(level: audioLevels.system).label)",
                    level: audioLevels.system
                )
                Divider().padding(.leading, PanelMetrics.contentLeading)
                microphoneTrack
                if model.videoEnabled {
                    Divider().padding(.leading, PanelMetrics.contentLeading)
                    screenTrack
                }
            }
        }
    }

    @ViewBuilder private var microphoneTrack: some View {
        if model.recordingIncludesMicrophone {
            let name = model.recordingMicrophoneName ?? "Microphone"
            VStack(alignment: .leading, spacing: 0) {
                TrackRow(
                    icon: "mic.fill",
                    name: "Me",
                    caption: model.microphoneSilenceWarning == nil
                        ? "\(name) · \(AudioLevelState(level: audioLevels.microphone).label)" : "No input",
                    captionColor: model.microphoneSilenceWarning == nil ? .secondary : .orange,
                    level: audioLevels.microphone
                )
                if let warning = model.microphoneSilenceWarning {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        // Keep "30 s" on one line.
                        Text(warning.replacingOccurrences(of: " s.", with: "\u{00A0}s."))
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(9)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.leading, PanelMetrics.contentLeading)
                    .padding(.trailing, PanelMetrics.rowInset)
                    .padding(.bottom, 12)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Warning: \(warning)")
                }
            }
            .animation(.snappy(duration: 0.2), value: model.microphoneSilenceWarning)
        } else if model.microphoneEnabled {
            // The user asked for the microphone but this recording could not include it.
            TrackRow(icon: "mic.slash", name: "Microphone", caption: "Not included", level: nil)
                .opacity(0.6)
        } else {
            TrackRow(icon: "mic.slash", name: "Microphone", caption: "Off", level: nil)
                .opacity(0.6)
        }
    }

    private var screenTrack: some View {
        HStack(spacing: PanelMetrics.columnSpacing) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: PanelMetrics.iconColumn)
                .accessibilityHidden(true)
            Text("Screen").font(.body.weight(.medium))
            Text(model.selectedScreenSource ?? "Screen video")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.selectedScreenSource ?? "Screen video")
            Spacer(minLength: 4)
            Circle().fill(.red).frame(width: 6, height: 6).accessibilityHidden(true)
        }
        .padding(.horizontal, PanelMetrics.rowInset)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityValue("Recording")
    }
}

private struct TrackRow: View {
    let icon: String
    let name: String
    let caption: String
    var captionColor: Color = .secondary
    /// nil for a track that is not being recorded.
    let level: Float?

    var body: some View {
        HStack(alignment: .top, spacing: PanelMetrics.columnSpacing) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: PanelMetrics.iconColumn, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(name).font(.body.weight(.medium)).layoutPriority(1)
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(captionColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(caption)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 20)
                if let level {
                    LevelMeter(source: name, state: caption, level: level, enabled: true, height: 6)
                }
            }
        }
        .padding(.horizontal, PanelMetrics.rowInset)
        .padding(.vertical, 12)
    }
}
