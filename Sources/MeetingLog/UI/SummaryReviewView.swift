import SwiftUI

struct SummaryReviewView: View {
    @ObservedObject var model: AppModel
    @State private var meetings: [ArchivedMeeting] = []
    @State private var selection: URL?
    @State private var handledRequestID: UUID?
    @State private var current = ""
    @State private var revision: SummaryRevision?
    @State private var task: Task<Void, Never>?
    @State private var error: String?
    @State private var saved = false
    @State private var query = ""
    @State private var missingContext = false
    @State private var chinesePreview = false

    private var store: ArchiveStore { ArchiveStore(root: URL(filePath: model.archiveRootPath)) }
    private var service: SummaryRegenerator {
        SummaryRegenerator(store: store, client: ProviderClient(baseURL: model.providerBaseURL, apiKey: model.apiKey, model: model.selectedModelID))
    }
    private var meeting: ArchivedMeeting? { meetings.first { $0.url == selection } }
    private var busy: Bool { task != nil }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Meetings").font(.title2.bold())
                TextField("Search meetings or projects", text: $query)
                    .textFieldStyle(.roundedBorder)
                List(selection: $selection) {
                    ForEach(meetings.filter { query.isEmpty || ($0.title + $0.projectName).localizedCaseInsensitiveContains(query) }) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).lineLimit(2)
                            Text("\(item.projectName) · \(item.date.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }.tag(item.url)
                    }
                }
                .disabled(busy || revision != nil)
                Button("Refresh meetings", action: reload).disabled(busy || revision != nil)
            }.padding().frame(minWidth: 220, idealWidth: 260, maxWidth: 340)

            VStack(alignment: .leading, spacing: 16) {
                if let meeting {
                    Text(meeting.title).font(.title2.bold()).textSelection(.enabled)
                    Text("Generate a new summary from the saved transcript and current project context.")
                        .foregroundStyle(.secondary)
                    if missingContext {
                        Label("Project context is empty. Add confirmed participants, terms, and handoff locations to improve this summary.", systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Open transcript") { NSWorkspace.shared.open(meeting.url.appending(path: "transcript.md")) }
                        Button("Open meeting context") { NSWorkspace.shared.open(meeting.url.deletingLastPathComponent().deletingLastPathComponent().appending(path: "meeting_context.md")) }
                        Spacer()
                        Button("Show in Finder") { model.showInFinder(meeting.url) }
                    }
                    if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    if saved { Label("Summary saved. The previous version is backed up.", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    Picker("Summary language", selection: $chinesePreview) {
                        Text("Original language").tag(false)
                        Text("简体中文").tag(true)
                    }.pickerStyle(.segmented).labelsHidden()
                    HSplitView {
                        preview("Current summary", text: chinesePreview ? ((try? String(contentsOf: meeting.url.appending(path: "summary_cn.md"), encoding: .utf8)) ?? "No Chinese summary yet.") : current)
                        if let revision { preview("New summary", text: chinesePreview ? revision.chineseMarkdown : revision.markdown) }
                    }
                    Text("Transcript and context are sent to \(URL(string: model.providerBaseURL)?.host ?? "your configured provider") · \(model.selectedModelID). Audio is not uploaded.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if busy {
                            ProgressView().controlSize(.small)
                            Text("Generating and checking evidence…").foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel") { cancel() }
                        } else if revision != nil {
                            Text("Review both versions before saving.").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Discard preview") { revision = nil; error = nil }
                            Button("Save new summary", action: save).buttonStyle(.borderedProminent)
                        } else {
                            Spacer()
                            Button("Regenerate summary", action: generate)
                                .buttonStyle(.borderedProminent)
                                .disabled(model.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !errorFreeTranscript(meeting))
                        }
                    }
                    if model.apiKey.isEmpty { Text("Add an AI provider in Settings to generate a summary.").font(.caption).foregroundStyle(.secondary) }
                } else {
                    ContentUnavailableView("Choose a meeting", systemImage: "doc.text", description: Text("Completed meetings with saved transcripts appear here."))
                }
            }.padding(24).frame(minWidth: 550, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 850, minHeight: 550)
        .onAppear {
            if !busy && revision == nil { reload(); applyOpenRequest() }
        }
        .onChange(of: selection) { _, _ in loadCurrent() }
        .onChange(of: model.summaryOpenRequest) { _, _ in applyOpenRequest() }
        .onChange(of: busy) { _, _ in applyOpenRequest() }
        .onChange(of: revision == nil) { _, _ in applyOpenRequest() }
        .onChange(of: model.archiveRootPath) { _, _ in cancel(); revision = nil; selection = nil; reload() }
        .onDisappear { cancel() }
    }

    private func preview(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ScrollView {
                SummaryMarkdownView(markdown: text)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(16)
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
        }.frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
    }
    private func errorFreeTranscript(_ meeting: ArchivedMeeting) -> Bool {
        FileManager.default.fileExists(atPath: meeting.url.appending(path: "transcript.md").path)
    }
    private func applyOpenRequest() {
        guard !busy, revision == nil,
              let request = model.summaryOpenRequest, request.id != handledRequestID else { return }
        handledRequestID = request.id
        selection = request.url
        reload()
    }
    private func reload() {
        do {
            meetings = try store.recentMeetings(limit: Int.max)
            if selection == nil { selection = meetings.first?.url }
            if !meetings.contains(where: { $0.url == selection }) { selection = meetings.first?.url }
            loadCurrent()
        } catch { self.error = error.localizedDescription }
    }
    private func loadCurrent() {
        error = nil; saved = false; revision = nil
        guard let meeting else { current = ""; return }
        let contextURL = meeting.url.deletingLastPathComponent().deletingLastPathComponent().appending(path: "meeting_context.md")
        let context = (try? String(contentsOf: contextURL, encoding: .utf8)) ?? ""
        missingContext = context.components(separatedBy: .newlines).allSatisfy {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return line.isEmpty || line.hasPrefix("#")
        }
        do { current = try String(contentsOf: meeting.url.appending(path: "summary.md"), encoding: .utf8) }
        catch { current = ""; self.error = error.localizedDescription }
    }
    private func generate() {
        guard let meeting, !busy else { return }
        error = nil; saved = false
        let generator = service
        task = Task { @MainActor in
            defer { task = nil }
            do {
                let result = try await generator.generate(for: meeting)
                try Task.checkCancellation()
                current = result.original
                revision = result
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
    private func cancel() { task?.cancel() }
    private func save() {
        guard let revision else { return }
        do {
            try service.save(revision)
            current = revision.markdown
            self.revision = nil; error = nil; saved = true
        } catch { self.error = error.localizedDescription }
    }
}

/// Native, selectable preview for the Markdown format produced by MeetingLog.
private struct SummaryMarkdownView: View {
    let markdown: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(markdown.components(separatedBy: .newlines).enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("| Task |") || line.hasPrefix("| ---") {
                    EmptyView()
                } else if line.hasPrefix("| ") {
                    let cells = line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast().map {
                        String($0).trimmingCharacters(in: .whitespaces)
                            .replacingOccurrences(of: "<br>", with: "\n")
                            .replacingOccurrences(of: "&#124;", with: "|")
                            .replacingOccurrences(of: "&lt;", with: "<")
                            .replacingOccurrences(of: "&gt;", with: ">")
                            .replacingOccurrences(of: "&amp;", with: "&")
                    }
                    if cells.count == 4 {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(cells[0]).fontWeight(.medium)
                            Text("Owner: \(cells[1]) · Deadline: \(cells[2])").font(.caption).foregroundStyle(.secondary)
                            if cells[3] != "—" { Text(cells[3]).font(.callout).foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    } else { Text(line) }
                } else if line.hasPrefix("## ") {
                    Text(String(line.dropFirst(3))).font(.headline).padding(.top, 10)
                } else if line.hasPrefix("# ") {
                    Text(String(line.dropFirst(2))).font(.title3.bold())
                } else if line.hasPrefix("- ") {
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(.init(String(line.dropFirst(2)))).frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if !line.isEmpty { Text(.init(line)) }
            }
        }
    }
}
