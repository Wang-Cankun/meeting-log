import SwiftUI

/// Panel between Stop and hand-off: frozen duration, the saving steps and real mixing progress.
struct SavingStatusView: View {
    @ObservedObject var model: AppModel
    let duration: TimeInterval
    let step: SavingStep
    let showSettings: () -> Void
    @ScaledMetric(relativeTo: .largeTitle) private var timerSize: CGFloat = 44

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("SAVING RECORDING")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                    Spacer()
                    PanelMoreMenu(showSettings: showSettings)
                }
                Text(Self.formatted(duration))
                    .font(.system(size: timerSize, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Recording length")
                    .accessibilityValue(Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide)))
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

            SavingStepsCard(progress: model.savingProgress, step: step)
                .padding(.horizontal, PanelMetrics.cardInset)

            Button {} label: {
                Text("Saving…")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.extraLarge)
            .disabled(true)
            .padding(.horizontal, PanelMetrics.cardInset)
            .padding(.top, 14)

            Text(model.providerReady
                 ? "You can close this panel. MeetingLog keeps saving and will notify you when the meeting is ready."
                 : "You can close this panel. The recording will wait in Recent until an AI provider is configured.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
    }

    static func formatted(_ duration: TimeInterval) -> String {
        Duration.seconds(duration.rounded(.down))
            .formatted(.time(pattern: duration >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}

/// Observes only the mix fraction, so frequent export updates redraw this card alone.
/// The current step carries the only spinner; the bar appears only while mixing, the one step with real progress.
private struct SavingStepsCard: View {
    @ObservedObject var progress: SavingProgress
    let step: SavingStep

    private var ordinal: String { "Step \(step.rawValue + 1) of \(SavingStep.allCases.count)" }

    var body: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(Self.headline(step)).font(.callout.weight(.medium))
                        Spacer()
                        Group {
                            if step == .mixingAudio, let fraction = progress.fraction {
                                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                            } else {
                                Text(ordinal)
                            }
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    if step == .mixingAudio {
                        if let fraction = progress.fraction {
                            ProgressView(value: fraction).progressViewStyle(.linear)
                        } else {
                            ProgressView().progressViewStyle(.linear)
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.headline(step))
                .accessibilityValue(accessibilityValue)

                VStack(alignment: .leading, spacing: 7) {
                    ForEach(SavingStep.allCases, id: \.self) { item in
                        HStack(spacing: 8) {
                            Group {
                                if item.rawValue < step.rawValue {
                                    Image(systemName: "checkmark").foregroundStyle(.green)
                                } else if item == step {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "circle").foregroundStyle(.tertiary)
                                }
                            }
                            .font(.caption.weight(.semibold))
                            .frame(width: 16, height: 16)
                            .accessibilityHidden(true)
                            Text(Self.title(item, current: step))
                                .font(.callout)
                                .foregroundStyle(item.rawValue > step.rawValue ? .secondary : .primary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityValue("Step \(item.rawValue + 1) of \(SavingStep.allCases.count), "
                            + (item.rawValue < step.rawValue ? "done" : item == step ? "in progress" : "pending"))
                    }
                }
            }
            .padding(14)
        }
    }

    private var accessibilityValue: String {
        guard step == .mixingAudio, let fraction = progress.fraction else { return ordinal }
        return "\(ordinal), \(fraction.formatted(.percent.precision(.fractionLength(0))))"
    }

    static func headline(_ step: SavingStep) -> String {
        switch step {
        case .stoppingTracks: "Stopping tracks"
        case .mixingAudio: "Mixing audio"
        case .handingOff: "Handing off to processing"
        }
    }

    /// Past tense once done, the headline while current, the plain step name while pending.
    static func title(_ item: SavingStep, current: SavingStep) -> String {
        if item == current { return headline(item) }
        let done = item.rawValue < current.rawValue
        switch item {
        case .stoppingTracks: return done ? "Tracks stopped · originals kept" : "Stop tracks"
        case .mixingAudio: return done ? "Audio mixed" : "Mix audio"
        case .handingOff: return done ? "Handed off to processing" : "Hand off to processing"
        }
    }
}
