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
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 12, height: 12)
                        .accessibilityHidden(true)
                    Text("SAVING RECORDING")
                        .font(.callout.weight(.semibold))
                        .tracking(0.2)
                        .foregroundStyle(.tint)
                    Spacer()
                    PanelMoreMenu(showSettings: showSettings)
                        .padding(.vertical, -6)
                }
                Text(Self.formatted(duration))
                    .font(.system(size: timerSize, weight: .semibold).monospacedDigit())
                    .tracking(-0.5)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Recording length")
                    .accessibilityValue(Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide)))
                PanelDestination(prefix: "Saving to", path: model.recordingDestinationPath)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, PanelMetrics.textLeading)
            .padding(.trailing, PanelMetrics.cardInset)
            .padding(.top, 16)
            .padding(.bottom, 18)

            SavingStepsCard(progress: model.savingProgress, step: step)
                .padding(.horizontal, PanelMetrics.cardInset)

            Button {} label: {
                PanelActionLabel(title: "Saving…")
            }
            .buttonStyle(.bordered)
            .panelActionStyle()
            .disabled(true)
            .padding(.horizontal, PanelMetrics.cardInset)
            .padding(.top, 16)

            Text(model.providerReady
                 ? "You can close this panel. MeetingLog keeps saving and will notify you when the meeting is ready."
                 : "You can close this panel. The recording will wait in Recent until processing is set up in Settings.")
                .font(.subheadline)
                .lineSpacing(2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, 16)
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
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(Self.headline(step)).font(.body.weight(.medium))
                        Spacer()
                        Group {
                            if step == .mixingAudio, let fraction = progress.fraction {
                                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                            } else {
                                Text(ordinal)
                            }
                        }
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    if step == .mixingAudio {
                        if let fraction = progress.fraction {
                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(PanelColors.track)
                                    Capsule().fill(Color.accentColor)
                                        .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                                }
                            }
                            .frame(height: 6)
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
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 14, height: 14)
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
