import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Archive Location") {
                LabeledContent("Folder") {
                    Text(model.archiveRootPath)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Change") { model.chooseArchiveRoot() }
                    Button("Show in Finder") { model.showArchiveInFinder() }
                    Spacer()
                }
                .disabled(model.isRecording || model.isProcessing)
            }

            Section("Projects") {
                if model.projects.isEmpty {
                    Text("No projects yet. Meetings without a matching project will use Inbox.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.projects) { project in
                        HStack {
                            Label(project.name, systemImage: "folder")
                                .lineLimit(1)
                            Spacer()
                            Button("Show in Finder") { model.showInFinder(project.url) }
                                .controlSize(.small)
                        }
                    }
                }
                Button("New Project…") { model.createProject() }
                    .disabled(model.isRecording || model.isProcessing)
            }

            Section("AI processing") {
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

                Text("Recording works without an API key. MeetingLog sends compressed audio to OpenRouter only after recording stops.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .frame(width: 560, height: 500)
        .onAppear { model.settingsDidOpen() }
    }

    private var providerStateText: String {
        model.providerStatus ?? (model.keySaved ? "API key stored in Keychain" : "API key required for transcription")
    }

    private var providerStateSymbol: String {
        if model.providerStatus == nil { return model.keySaved ? "checkmark.circle" : "exclamationmark.circle" }
        return model.providerStatus == "Connected" ? "checkmark.circle" : "exclamationmark.circle"
    }
}
