import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var page = SettingsPage.library
    @State private var showingProject = false
    @State private var baseURL = ""
    @State private var modelID = ""
    @State private var key = ""
    @State private var useSpeech = false
    @State private var summaries = true
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
            if !model.providerReady { page = .provider }
        }
        .sheet(isPresented: $showingProject) { NewProjectSheet(model: model) }
        .confirmationDialog("Remove the saved AI configuration?", isPresented: $confirmingRemoval) {
            Button("Remove configuration", role: .destructive) {
                model.removeProviderConfiguration()
                loadSavedProvider()
            }
        } message: {
            Text("Existing meetings stay in your archive. New recordings will wait locally until you set up processing again.")
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
                Text("AI processing").font(.title2.weight(.semibold))
                Text(summaries
                     ? "Choose how to transcribe audio, then connect the provider that writes your summaries."
                     : "Recordings are transcribed with Azure Speech and saved as transcripts, without summaries.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Toggle("Generate AI summaries", isOn: draft($summaries))
                    Text(summaries
                         ? "An AI model writes each meeting's summary and Simplified Chinese summary."
                         : "No AI model is used. Each meeting keeps its audio and transcripts.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if summaries {
                    Picker("Transcription", selection: draft($useSpeech)) {
                        Text("AI provider").tag(false)
                        Text("Azure Speech · \(SpeechTranscriber.model)").tag(true)
                    }
                }
                if usesSpeech {
                    Text(summaries
                         ? "Audio goes to Azure Speech. Only transcript text goes to the AI provider below."
                         : "Audio goes to Azure Speech · \(SpeechTranscriber.model). Nothing is sent to an AI model.")
                        .font(.caption).foregroundStyle(.secondary)
                    field("Speech endpoint", hint: "Resource root URL from Azure, without /speechtotext or an API version.") {
                        TextField("", text: draft($speechEndpoint),
                                  prompt: Text("https://<resource>.cognitiveservices.azure.com"))
                    }
                    field("Speech key", hint: "Key for this Azure Speech or AI Services resource.") {
                        SecureField("", text: draft($speechKey), prompt: Text("Paste the resource key"))
                    }
                } else {
                    Text("The AI provider below handles both audio transcription and summaries. Choose a model that accepts audio input.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if summaries {
                    Divider()
                    Text(useSpeech ? "Summary provider" : "Transcription & summary provider").font(.headline)
                    field("API base URL", hint: "OpenAI-compatible HTTPS base URL, without /chat/completions.") {
                        TextField("", text: draft($baseURL), prompt: Text("https://openrouter.ai/api/v1"))
                    }
                    field("Model", hint: useSpeech ? "Text model or deployment ID that supports JSON output." : "Model ID that supports audio input and JSON output.") {
                        TextField("", text: draft($modelID), prompt: Text("Your provider's model ID"))
                    }
                    field("API key", hint: nil) {
                        SecureField("", text: draft($key), prompt: Text("Paste your API key"))
                    }
                }
            }
            .disabled(model.isVerifyingConfiguration)

            VStack(alignment: .leading, spacing: 12) {
                if model.isVerifyingConfiguration {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(model.configurationStatus ?? "Testing…").foregroundStyle(.secondary)
                    }
                } else {
                    Label(statusText, systemImage: statusSymbol)
                        .font(.callout)
                        .foregroundStyle(model.configurationStatus == "Connected" ? .green : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    if !model.apiKey.isEmpty || model.speechTranscriber != nil {
                        Button("Remove configuration…", role: .destructive) { confirmingRemoval = true }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if hasEdits {
                        Button("Revert") { loadSavedProvider(); model.configurationStatus = nil }
                    }
                    Button("Test & save") {
                        Task {
                            await model.testProcessingConfiguration(
                                baseURL: baseURL, modelID: modelID, key: key,
                                useSpeech: usesSpeech, speechEndpoint: speechEndpoint, speechKey: speechKey,
                                summaries: summaries
                            )
                            if model.configurationStatus == "Connected" { loadSavedProvider() }
                        }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!complete)
                }
                .disabled(model.isVerifyingConfiguration || archiveBusy)
                Text(summaries
                     ? "Testing sends a short text request and one second of generated silence to the selected services. Both must pass before saving resumes pending recordings."
                     : "Testing sends one second of generated silence to Azure Speech. It must pass before saving resumes pending recordings.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if archiveBusy {
                    Text("Wait for recording, importing, and processing to finish before saving changes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()
            DisclosureGroup("How processing & storage work", isExpanded: $showingDetails) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(summaries
                         ? "Without a saved AI configuration, recordings wait locally. You need a summary provider even when Azure Speech handles transcription."
                         : "Without a saved Azure Speech configuration, recordings wait locally. Turn on AI summaries to add a summary provider.")
                    Text("API keys are stored unencrypted in your local app preferences.")
                    Text(summaries
                         ? "Each meeting includes its transcript, a summary, a Simplified Chinese summary, and a short Chinese folder title."
                         : "Each meeting includes its audio, the original transcription and a readable transcript, in a folder named by its start time or imported file name.")
                }
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }
            .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusSymbol: String {
        if let status = model.configurationStatus {
            return status == "Connected" ? "checkmark.circle.fill" : "exclamationmark.circle"
        }
        return hasEdits ? "pencil.circle" : (model.providerReady ? "checkmark.circle" : "info.circle")
    }

    private func draft<Value>(_ value: Binding<Value>) -> Binding<Value> {
        Binding(get: { value.wrappedValue }, set: {
            value.wrappedValue = $0
            model.configurationStatus = nil
        })
    }

    private func field<Content: View>(_ title: String, hint: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline.weight(.medium))
            content()
                .labelsHidden().textFieldStyle(.roundedBorder).controlSize(.large)
                .font(.system(.body, design: .monospaced)).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity).accessibilityLabel(title)
            if let hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var statusText: String {
        if let status = model.configurationStatus {
            return status == "Connected" ? "Services verified. Configuration saved." : status
        }
        if hasEdits { return "Unsaved changes. Pending recordings use the saved configuration." }
        if !model.providerReady { return "Complete the fields above to enable processing." }
        if !model.summariesEnabled { return "Saved: \(SpeechTranscriber.model) for transcription. AI summaries are off." }
        return model.speechTranscriber != nil
            ? "Saved: \(SpeechTranscriber.model) for transcription; \(model.selectedModelID) for summaries."
            : "Saved: \(model.selectedModelID) for transcription and summaries."
    }

    private var hasEdits: Bool {
        guard summaries == model.summariesEnabled else { return true }
        let speechEdits = speechEndpoint != model.speechEndpoint || speechKey != model.speechKey
        // Hidden provider fields do not count while AI summaries are off.
        guard summaries else { return speechEdits }
        return baseURL != model.providerBaseURL || modelID != model.selectedModelID || key != model.apiKey
            || useSpeech != (model.speechTranscriber != nil)
            || (useSpeech && speechEdits)
    }
    private var complete: Bool {
        let fields = (summaries ? [baseURL, modelID, key] : []) + (usesSpeech ? [speechEndpoint, speechKey] : [])
        return fields.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    private var archiveBusy: Bool {
        model.isRecording || model.isChangingRecording || model.isProcessing || model.isImporting
    }
    /// Azure Speech transcribes when it is selected, and always when AI summaries are off.
    private var usesSpeech: Bool { useSpeech || !summaries }
    private func loadSavedProvider() {
        summaries = model.summariesEnabled
        baseURL = model.providerBaseURL
        modelID = model.selectedModelID
        key = model.apiKey
        speechEndpoint = model.speechEndpoint
        speechKey = model.speechKey
        useSpeech = model.speechTranscriber != nil
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
