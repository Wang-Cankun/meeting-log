import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Archive") {
                LabeledContent("Folder") {
                    Text(model.archiveRootPath)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Use Obsidian folder") { model.useObsidianArchive() }
                    Button("Choose…") { model.chooseArchiveRoot() }
                    Button("Open") { model.openArchive() }
                    Spacer()
                    Button("Delete archived media…", role: .destructive) {
                        model.deleteMediaKeepingMarkdown()
                    }
                }
                .disabled(model.isRecording || model.isProcessing)
            }

            Section("AI processing") {
                LabeledContent("Service", value: "OpenRouter")

                Picker("Model", selection: Binding(
                    get: { model.selectedModelID },
                    set: { model.selectModel($0) }
                )) {
                    if !model.modelOptions.contains(where: { $0.id == model.selectedModelID }) {
                        Text(model.selectedModelID).tag(model.selectedModelID)
                    }
                    ForEach(model.modelOptions) { option in
                        Text(option.name).tag(option.id)
                    }
                }
                .disabled(model.isRecording)

                HStack {
                    SecureField(
                        model.keySaved ? "Replace saved API key" : "OpenRouter API key",
                        text: $model.apiKey
                    )
                    .textFieldStyle(.roundedBorder)
                    Button(model.isVerifyingProvider ? "Verifying…" : "Save and verify") {
                        model.saveAndVerifyKey()
                    }
                    .disabled(
                        model.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || model.isVerifyingProvider
                        || model.isRecording
                    )
                }

                HStack {
                    Label(
                        providerStateText,
                        systemImage: providerStateSymbol
                    )
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button("Verify") { model.verifySavedKey() }
                        .disabled(!model.keySaved || model.isVerifyingProvider)
                    Button("Remove", role: .destructive) { model.removeKey() }
                        .disabled(!model.keySaved || model.isRecording)
                }

                Text("Audio previews stay on this Mac. MeetingLog sends compressed audio to OpenRouter only after recording stops.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .frame(width: 520, height: 400)
        .preferredColorScheme(.light)
        .onAppear { model.loadModels() }
    }

    private var providerStateText: String {
        model.providerStatus ?? (model.keySaved ? "API key stored in Keychain" : "API key required before recording")
    }

    private var providerStateSymbol: String {
        if model.providerStatus == nil { return model.keySaved ? "checkmark.circle" : "exclamationmark.circle" }
        return model.providerStatus == "Connected" ? "checkmark.circle" : "exclamationmark.circle"
    }
}
