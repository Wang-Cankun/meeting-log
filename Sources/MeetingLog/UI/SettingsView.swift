import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("AI provider") {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Base URL").font(.subheadline.weight(.medium))
                        Text("The root URL for an OpenAI-compatible API.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("https://openrouter.ai/api/v1", text: $model.providerBaseURL)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Model ID").font(.subheadline.weight(.medium))
                        Text("Must accept audio input and return text.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("google/gemini-3.7-flash", text: $model.selectedModelID)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Authentication") {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("API key").font(.subheadline.weight(.medium))
                        SecureField("Required", text: $model.apiKey)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                    }

                    if model.isVerifyingProvider {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Verifying configuration…")
                        }
                        .foregroundStyle(.secondary)
                    } else {
                        Label(providerStateText, systemImage: providerStateSymbol)
                            .foregroundStyle(providerStateColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack {
                        Spacer()
                        if model.keySaved {
                            Button("Remove configuration", role: .destructive) {
                                model.removeProviderConfiguration()
                            }
                            .disabled(model.isRecording)
                        }
                        Button("Test connection") {
                            model.testProviderConfiguration()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!providerConfigurationComplete || model.isVerifyingProvider || model.isRecording)
                    }

                    Text("The API key is stored unencrypted in this Mac user's app preferences. Recording works without it; processing waits until a configuration is available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            Section("Archive Location") {
                LabeledContent("Archive folder") {
                    Text(model.archiveRootPath)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Change") { model.chooseArchiveRoot() }
                        .disabled(model.pendingMeetingsExist)
                    Button("Show in Finder") { model.showArchiveInFinder() }
                    Button("New Project…") { model.createProject() }
                    Spacer()
                }
                .disabled(model.isRecording || model.isProcessing)
                if model.pendingMeetingsExist {
                    HStack {
                        Text("Finish pending meetings before changing the archive.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Discard Pending…", role: .destructive) { model.discardPendingMeetings() }
                            .controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .frame(width: 600, height: 600)
        .onAppear { model.settingsDidOpen() }
    }

    private var providerStateText: String {
        model.providerStatus ?? (model.keySaved ? "Configuration saved" : "Configuration required for transcription")
    }

    private var providerStateSymbol: String {
        if model.providerStatus == nil { return model.keySaved ? "checkmark.circle" : "exclamationmark.circle" }
        return model.providerStatus == "Connected" ? "checkmark.circle" : "exclamationmark.circle"
    }

    private var providerStateColor: Color {
        model.providerStatus == "Connected" ? .green : .secondary
    }

    private var providerConfigurationComplete: Bool {
        [model.providerBaseURL, model.selectedModelID, model.apiKey]
            .allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
