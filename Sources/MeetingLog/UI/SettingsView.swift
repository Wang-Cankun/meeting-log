import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var page = SettingsPage.library
    @State private var showingProject = false
    @State private var baseURL = ""
    @State private var modelID = ""
    @State private var key = ""
    @State private var testResult: String?
    @State private var speechEndpoint = ""
    @State private var speechKey = ""
    @State private var confirmingRemoval = false
    @State private var confirmingDiscard = false
    @State private var showingDetails = false

    private enum SettingsPage: String, CaseIterable {
        case library = "Projects & storage"
        case provider = "AI processing"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings section", selection: $page) {
                ForEach(SettingsPage.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)
            .padding(.top, 20)
            .padding(.bottom, 16)

            if page == .library {
                Form { library }
                    .formStyle(.grouped)
            } else {
                ScrollView {
                    provider
                        .padding(.horizontal, 28)
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                }
            }
        }
        .frame(width: 600, height: 570)
        .onAppear {
            model.settingsDidOpen()
            loadSavedProvider()
        }
        .sheet(isPresented: $showingProject) { NewProjectSheet(model: model) }
        .confirmationDialog("Remove the saved AI configuration?", isPresented: $confirmingRemoval) {
            Button("Remove configuration", role: .destructive) {
                model.removeProviderConfiguration()
                loadSavedProvider()
                testResult = nil
            }
        } message: {
            Text("Existing meetings stay in your archive. New recordings will wait locally until you configure a provider again.")
        }
        .confirmationDialog("Discard pending meetings?", isPresented: $confirmingDiscard) {
            Button("Move to Trash", role: .destructive) { model.discardPendingMeetings() }
        } message: {
            let count = model.pendingMeetingCount
            Text("\(count) unfinished \(count == 1 ? "meeting" : "meetings") will be moved to the Trash and will no longer be processed.")
        }
    }

    private var library: some View {
        Group {
            Section {
                HStack {
                    Text("Projects").font(.headline)
                    Spacer()
                    Button("New project…", systemImage: "plus") { showingProject = true }
                }
                if model.projects.isEmpty {
                    Text("Create a project to keep related meetings together. Otherwise, meetings go to Inbox.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.projects) { project in
                    HStack(spacing: 10) {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(project.displayPath).fixedSize(horizontal: false, vertical: true)
                            if model.selectedProjectName == project.name {
                                Text("Meeting context: global › " + project.displayPath)
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer()
                        if model.selectedProjectName == project.name {
                            Text("Selected").font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Open", systemImage: "arrow.up.right") { model.showInFinder(project.url) }
                            .labelStyle(.iconOnly)
                            .help("Open \(project.name) in Finder")
                    }
                }
            } footer: {
                Text("Choose a project when recording or importing. Rename project folders in Finder.")
            }

            Section("Storage") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Meeting archive").font(.subheadline.weight(.medium))
                    Text(model.archiveRootPath)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    HStack {
                        Button("Open in Finder") { model.showArchiveInFinder() }
                        Spacer()
                        Button("Change folder…") { model.chooseArchiveRoot() }
                            .disabled(archiveBusy || model.pendingMeetingsExist)
                    }
                }
                if model.pendingMeetingsExist {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Some recordings are waiting for processing. Finish them before changing the archive folder.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Move pending recordings to Trash…", role: .destructive) { confirmingDiscard = true }
                            .disabled(archiveBusy)
                    }
                }
            }
        }
    }

    private var provider: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("AI provider").font(.title2.weight(.semibold))
                Text("Connect a provider to transcribe audio and write meeting summaries.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 18) {
                field("API base URL", hint: "OpenAI-compatible HTTPS endpoint") {
                    TextField("", text: draft($baseURL),
                              prompt: Text("https://openrouter.ai/api/v1"))
                }
                field("Model", hint: "Must support audio input unless a speech service is set below.") {
                    TextField("", text: draft($modelID),
                              prompt: Text("Provider model ID"))
                }
                field("API key", hint: nil) {
                    SecureField("", text: draft($key), prompt: Text("Paste your API key"))
                }
            }
            .disabled(model.isVerifyingProvider)

            VStack(alignment: .leading, spacing: 12) {
                if model.isVerifyingProvider {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Testing connection…").foregroundStyle(.secondary)
                    }
                } else {
                    Label(statusText, systemImage: statusSymbol)
                        .font(.callout)
                        .foregroundStyle(statusColor)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    if model.keySaved {
                        Button("Remove provider…", role: .destructive) { confirmingRemoval = true }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .disabled(model.isVerifyingProvider || archiveBusy)
                    }
                    Spacer()
                    if hasEdits && model.keySaved {
                        Button("Revert") { loadSavedProvider(); testResult = nil }
                            .disabled(model.isVerifyingProvider)
                    }
                    Button(hasEdits || !model.keySaved ? "Test & save" : "Test connection") {
                        Task {
                            await model.testProviderConfiguration(baseURL: baseURL, modelID: modelID, key: key)
                            testResult = model.providerStatus
                            if testResult == "Connected" { loadSavedProvider() }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!complete || model.isVerifyingProvider || archiveBusy)
                }
            }
            .padding(.top, 2)

            Divider()
            speech

            Divider()
            DisclosureGroup("How processing & storage work", isExpanded: $showingDetails) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Audio is sent to the speech service when one is saved, otherwise to this provider. Without a saved provider, recordings wait locally.")
                    Text("Testing sends a short text request, not audio. Saving resumes pending recordings.")
                    Text("The API key is stored unencrypted in your local app preferences.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusSymbol: String {
        if let testResult { return testResult == "Connected" ? "checkmark.circle.fill" : "exclamationmark.circle" }
        return hasEdits ? "pencil.circle" : (model.keySaved ? "checkmark.circle" : "info.circle")
    }

    private var statusColor: Color {
        if let testResult { return testResult == "Connected" ? .green : .orange }
        return .secondary
    }

    private func draft(_ value: Binding<String>) -> Binding<String> {
        Binding(get: { value.wrappedValue }, set: {
            value.wrappedValue = $0
            testResult = nil
        })
    }

    private func field<Content: View>(_ title: String, hint: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline.weight(.medium))
            content()
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .font(.system(.body, design: .monospaced))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(title)
            if let hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var speech: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Speech transcription (optional)").font(.headline)
                Text("Azure Speech with \(SpeechTranscriber.model) transcribes each recording in one request with speaker separation. The provider above then handles text only.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            field("Speech endpoint", hint: "Azure AI Services or Speech resource URL") {
                TextField("", text: $speechEndpoint, prompt: Text("https://<resource>.cognitiveservices.azure.com"))
            }
            field("Speech key", hint: nil) {
                SecureField("", text: $speechKey, prompt: Text("Paste the resource key"))
            }
            HStack(spacing: 10) {
                if model.isVerifyingSpeech {
                    ProgressView().controlSize(.small)
                    Text("Testing…").foregroundStyle(.secondary)
                } else if let status = model.speechStatus {
                    Text(status == "Connected" ? "Speech service verified and saved." : status)
                        .font(.callout)
                        .foregroundStyle(status == "Connected" ? .green : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if model.speechTranscriber != nil {
                    Button("Remove", role: .destructive) {
                        model.removeSpeechConfiguration()
                        speechEndpoint = ""
                        speechKey = ""
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.isVerifyingSpeech || archiveBusy)
                }
                Button("Test & save") {
                    Task { await model.testSpeechConfiguration(endpoint: speechEndpoint, key: speechKey) }
                }
                .disabled(speechEndpoint.isEmpty || speechKey.isEmpty || model.isVerifyingSpeech || archiveBusy)
            }
        }
        .disabled(model.isVerifyingProvider)
    }

    private var statusText: String {
        if let testResult {
            return testResult == "Connected" ? "Connection verified. Configuration saved." : testResult
        }
        if hasEdits { return "Unsaved changes" }
        return model.keySaved ? "Configuration saved." : "Add a provider when you’re ready to process audio."
    }

    private var hasEdits: Bool {
        baseURL != model.providerBaseURL || modelID != model.selectedModelID || key != model.apiKey
    }
    private var complete: Bool {
        [baseURL, modelID, key].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    private var archiveBusy: Bool {
        model.isRecording || model.isChangingRecording || model.isProcessing || model.isImporting
    }
    private func loadSavedProvider() {
        baseURL = model.providerBaseURL
        modelID = model.selectedModelID
        key = model.apiKey
        speechEndpoint = model.speechEndpoint
        speechKey = model.speechKey
    }
}

struct NewProjectSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("New project", systemImage: "folder.badge.plus").font(.title2.weight(.semibold))
            Text("Keep related recordings, transcripts, and summaries together.")
                .foregroundStyle(.secondary)
            TextField("Project name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit(create)
            Text("Created in your meeting archive and selected for new recordings.")
                .font(.caption).foregroundStyle(.secondary)
            if let message = error ?? validationMessage {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create project", action: create)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(validName == nil)
            }
        }
        .padding(24)
        .frame(width: 400)
        .onAppear { nameFocused = true }
        .onChange(of: name) { error = nil }
    }

    private var validName: String? { try? ArchiveStore.projectName(name) }
    private var validationMessage: String? {
        guard !name.isEmpty else { return nil }
        guard let validName else { return "Use 1–60 characters without /, :, control characters, or leading or trailing periods." }
        if model.projects.contains(where: { $0.name.localizedCaseInsensitiveCompare(validName) == .orderedSame }) {
            return "This project already exists. Creating will select the existing project."
        }
        return nil
    }
    private func create() {
        guard let validName else { return }
        do {
            try model.createProject(named: validName)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
