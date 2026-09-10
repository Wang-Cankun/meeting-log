import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ImportAudioView: View {
    @ObservedObject var model: AppModel
    @State private var file: URL?
    @State private var duration: TimeInterval?
    @State private var meetingDate = Date()
    @State private var project = ArchiveStore.inboxName
    @State private var isInspecting = false
    @State private var isTargeted = false
    @State private var error: String?
    @State private var imported = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.badge.plus")
                    .font(.system(size: 28)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Import audio").font(.title2.weight(.semibold))
                    Text("Turn an iPhone recording into a meeting.").foregroundStyle(.secondary)
                }
            }
            Button(action: chooseFile) {
                VStack(spacing: 10) {
                    Image(systemName: file == nil ? "square.and.arrow.down" : "waveform")
                        .font(.system(size: 28)).foregroundStyle(.tint)
                    Text(file?.lastPathComponent ?? "Drop your recording here")
                        .font(.headline).lineLimit(2).truncationMode(.middle)
                    if isInspecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(duration.map { "\(Int($0) / 60) min \(Int($0) % 60) sec · Choose a different file" }
                             ?? "or click to choose from Downloads")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Text("M4A, MP3, WAV, AIFF, CAF").font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 26)
                .background(.tint.opacity(isTargeted ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.tint.opacity(isTargeted ? 0.8 : 0.25), style: StrokeStyle(lineWidth: 1, dash: file == nil ? [5] : [])))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.isImporting || isInspecting)
            .dropDestination(for: URL.self) { urls, _ in
                guard urls.count == 1, !model.isImporting, !isInspecting, let url = urls.first else { return false }
                select(url)
                return true
            } isTargeted: { isTargeted = $0 }

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 16) {
                GridRow {
                    Text("Project").foregroundStyle(.secondary)
                    Picker("Project", selection: $project) {
                        Text("Inbox").tag(ArchiveStore.inboxName)
                        ForEach(model.projects.filter { $0.name != ArchiveStore.inboxName }) { item in
                            Text(item.name).tag(item.name)
                        }
                    }.labelsHidden()
                }
                GridRow {
                    Text("Meeting date").foregroundStyle(.secondary)
                    DatePicker("Meeting date", selection: $meetingDate, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                }
            }.disabled(model.isImporting || imported)
            Text("Check the date after AirDrop. The original audio is kept, and this project receives the transcript and summary.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            if imported {
                Label(model.keySaved ? "Imported. Processing continues in MeetingLog." : "Saved locally. Configure an AI provider in Settings to process it.", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
            }
            HStack(alignment: .center) {
                Text(imported ? "You can close this window or add another recording." : (model.keySaved ? "Audio is sent to your configured AI provider." : "No AI provider configured. Audio will wait locally."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                if model.isImporting { ProgressView().controlSize(.small) }
                Button(imported ? "Import another" : (model.isImporting ? "Importing…" : (model.keySaved ? "Import & Process" : "Import Audio"))) {
                    if imported { chooseFile(); return }
                    guard let file else { return }
                    error = nil
                    Task {
                        do {
                            try await model.importAudio(file, date: meetingDate, projectName: project)
                            imported = true
                        } catch { self.error = error.localizedDescription }
                    }
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled((!imported && (file == nil || duration == nil)) || isInspecting || model.isImporting)
            }
        }
        .padding(24).frame(width: 460)
        .onAppear { project = model.selectedProjectName ?? ArchiveStore.inboxName }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = AudioImport.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.prompt = "Choose Audio"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { select(url) }
    }

    private func select(_ url: URL) {
        file = url
        duration = nil
        error = nil
        imported = false
        isInspecting = true
        Task {
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
                isInspecting = false
            }
            do {
                duration = try await AudioImport.inspect(url)
                meetingDate = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            } catch { self.error = error.localizedDescription }
        }
    }
}
