import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ImportAudioView: View {
    @ObservedObject var model: AppModel
    @State private var files: [SelectedAudio] = []
    @State private var meetingDate = Date()
    @State private var project = ArchiveStore.inboxName
    @State private var isInspecting = false
    @State private var isTargeted = false
    @State private var error: String?
    @State private var imported = false

    private struct SelectedAudio: Identifiable {
        var id: URL { url }
        let url: URL
        let duration: TimeInterval
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Import a meeting").font(.title2.weight(.semibold))
                Text("Add recordings from the same meeting or topic.")
                    .foregroundStyle(.secondary)
            }

            if files.isEmpty {
                Button(action: chooseFiles) {
                    VStack(spacing: 10) {
                        Image(systemName: "square.and.arrow.down").font(.system(size: 28))
                        Text("Drop audio files here").font(.headline)
                        Text("or choose files from Downloads").foregroundStyle(.secondary)
                        Text("M4A, MP3, WAV, AIFF, CAF").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 26)
                    .background(.tint.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.tint.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [5])))
                }
                .buttonStyle(.plain)
                .disabled(busy)
            } else {
                VStack(spacing: 10) {
                    HStack {
                        Text("\(files.count) \(files.count == 1 ? "recording" : "recordings") · \(durationText(files.reduce(0) { $0 + $1.duration }))")
                            .font(.callout.weight(.medium))
                        Spacer()
                        if !imported { Button("Add files…", systemImage: "plus", action: chooseFiles).disabled(busy) }
                    }
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                                HStack(spacing: 10) {
                                    Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 20)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(file.url.lastPathComponent).lineLimit(2).truncationMode(.middle)
                                        Text(durationText(file.duration)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 4)
                                    if !imported {
                                        Button { files.swapAt(index, index - 1) } label: { Image(systemName: "chevron.up") }
                                            .disabled(busy || index == 0).help("Move earlier")
                                            .accessibilityLabel("Move \(file.url.lastPathComponent) earlier")
                                        Button { files.swapAt(index, index + 1) } label: { Image(systemName: "chevron.down") }
                                            .disabled(busy || index == files.count - 1).help("Move later")
                                            .accessibilityLabel("Move \(file.url.lastPathComponent) later")
                                        Button { files.remove(at: index) } label: { Image(systemName: "xmark") }
                                            .disabled(busy).help("Remove from this import")
                                            .accessibilityLabel("Remove \(file.url.lastPathComponent) from import")
                                    }
                                }
                                .buttonStyle(.borderless)
                                .padding(10)
                                if index < files.count - 1 { Divider().padding(.leading, 40) }
                            }
                        }
                    }
                    .frame(height: min(CGFloat(files.count) * 64, 200))
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    if !imported {
                        Text("Processed in this order. Files remain separate sources in one transcript and summary.")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if isInspecting {
                HStack { ProgressView().controlSize(.small); Text("Checking audio files…").font(.callout) }
            }

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 14) {
                GridRow {
                    Text("Project").foregroundStyle(.secondary)
                    ProjectChooser(projects: model.projects, selection: $project, refresh: model.refreshArchive)
                }
                GridRow {
                    Text("Archive date").foregroundStyle(.secondary)
                    DatePicker("Archive date", selection: $meetingDate, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                }
            }.disabled(busy || imported)
            Text("Use the meeting’s date or a reference date for this group. Original files are kept; gaps between recordings are not filled in.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            if imported {
                Label(model.providerReady ? "Meeting imported. Processing continues in MeetingLog." : "Meeting saved locally. Set up an AI provider in Settings to process it.", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
            }
            HStack {
                Text(imported ? "You can close this window or start another meeting." : (model.providerReady ? "Audio is sent to your configured AI provider." : "Audio will wait locally until an AI provider is configured."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                if model.isImporting { ProgressView().controlSize(.small) }
                Button(imported ? "New import" : (model.isImporting ? "Importing…" : "Import meeting")) {
                    if imported { files = []; imported = false; error = nil; return }
                    let urls = files.map(\.url)
                    error = nil
                    Task {
                        do {
                            try await model.importAudio(urls, date: meetingDate, projectName: project)
                            imported = true
                        } catch { self.error = error.localizedDescription }
                    }
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled((!imported && files.isEmpty) || busy)
            }
        }
        .padding(24).frame(width: 520)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isTargeted ? Color.accentColor : .clear, lineWidth: 2))
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty, !busy, !imported else { return false }
            add(urls)
            return true
        } isTargeted: { isTargeted = $0 }
        .onAppear { project = model.selectedProjectName ?? ArchiveStore.inboxName }
    }

    private var busy: Bool { model.isImporting || isInspecting }
    private func durationText(_ seconds: TimeInterval) -> String {
        let value = Int(seconds)
        return value >= 3600 ? "\(value / 3600) hr \((value % 3600) / 60) min" : "\(value / 60) min \(value % 60) sec"
    }
    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = AudioImport.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.prompt = "Add Recordings"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { add(panel.urls) }
    }
    private func add(_ urls: [URL]) {
        error = nil
        isInspecting = true
        Task {
            defer { isInspecting = false }
            do {
                var added: [SelectedAudio] = []
                var seen = Set(files.map { $0.url.resolvingSymlinksInPath().standardizedFileURL })
                for url in urls.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                    guard seen.insert(url.resolvingSymlinksInPath().standardizedFileURL).inserted else { throw ImportError.duplicate }
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    do {
                        added.append(SelectedAudio(url: url, duration: try await AudioImport.inspect(url)))
                    } catch {
                        throw NSError(domain: "AudioImport", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(url.lastPathComponent): \(error.localizedDescription)"])
                    }
                }
                if files.isEmpty, let first = added.first {
                    meetingDate = (try? first.url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                }
                files += added
            } catch { self.error = error.localizedDescription }
        }
    }
}
