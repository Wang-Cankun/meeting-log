import SwiftUI

struct SummaryReviewView: View {
    @Environment(\.openWindow) private var openWindow
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
    @State private var pendingArchiveRefresh = false

    private var store: ArchiveStore { ArchiveStore(root: URL(filePath: model.archiveRootPath)) }
    private var service: SummaryRegenerator {
        SummaryRegenerator(store: store, client: ProviderClient(baseURL: model.providerBaseURL, apiKey: model.apiKey, model: model.selectedModelID))
    }
    private var meeting: ArchivedMeeting? { meetings.first { $0.url == selection } }
    private var busy: Bool { task != nil }
    private var changedTitle: Bool {
        guard let revision else { return false }
        return revision.markdown.components(separatedBy: .newlines).first != current.components(separatedBy: .newlines).first
    }

    // Preserve newest-first order within each project and put recently active projects first.
    private var meetingGroups: [(name: String, items: [ArchivedMeeting])] {
        let filtered = meetings.filter {
            query.isEmpty || ($0.title + " " + $0.projectName + " " + projectLabel($0.projectName))
                .localizedCaseInsensitiveContains(query)
        }
        var groups: [(name: String, items: [ArchivedMeeting])] = []
        for item in filtered {
            if let index = groups.firstIndex(where: { $0.name == item.projectName }) {
                groups[index].items.append(item)
            } else {
                groups.append((name: item.projectName, items: [item]))
            }
        }
        return groups
    }

    private func projectLabel(_ path: String) -> String {
        ProjectFolder(name: path, url: URL(filePath: path)).displayPath
            .replacingOccurrences(of: "_", with: " ")
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Meetings").font(.system(size: 18, weight: .semibold))
                        Spacer()
                        Button(action: reload) { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless).help("Refresh meetings")
                            .accessibilityLabel("Refresh meetings").disabled(busy || revision != nil)
                    }
                    TextField("Search meetings or projects", text: $query)
                        .textFieldStyle(.roundedBorder)
                }.padding(20)
                Divider()
                List(selection: $selection) {
                    ForEach(meetingGroups, id: \.name) { group in
                        Section {
                            ForEach(group.items) { item in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.title)
                                        .font(.system(size: 13, weight: .medium))
                                        .lineLimit(3)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(item.date.formatted(date: .abbreviated, time: .omitted))
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                                .tag(item.url)
                                .help(item.title)
                                .listRowSeparator(.visible)
                            }
                        } header: {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(projectLabel(group.name))
                                    .font(.system(size: 12, weight: .semibold))
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                Text(group.items.count.formatted())
                                    .font(.system(size: 11)).monospacedDigit()
                            }
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                            .padding(.top, 8).padding(.bottom, 4)
                        }
                    }
                }
                .disabled(busy || revision != nil)
                .listStyle(.plain)
                .padding(.horizontal, 12)
                .scrollContentBackground(.hidden)
                .overlay {
                    if meetingGroups.isEmpty {
                        ContentUnavailableView(query.isEmpty ? "No meetings yet" : "No matching meetings",
                            systemImage: query.isEmpty ? "tray" : "magnifyingglass",
                            description: Text(query.isEmpty ? "Completed meetings appear here." : "Try another title or project."))
                    }
                }
            }.frame(width: 260)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))

            VStack(alignment: .leading, spacing: 12) {
                if let meeting {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(meeting.title).font(.system(size: 18, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        Text("\(meeting.projectName.replacingOccurrences(of: "/", with: " › ")) · \(current.components(separatedBy: .newlines).first(where: { $0.hasPrefix("- Date: ") }).map { String($0.dropFirst(8)) } ?? meeting.date.formatted(date: .abbreviated, time: .omitted))")
                            .font(.callout).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if missingContext {
                        Label("Project context is empty. Add confirmed participants, terms, and handoff locations to improve this summary.", systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let warning = meeting.captureWarning {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 12) {
                        Picker("Summary language", selection: $chinesePreview) {
                            Text("Original").tag(false)
                            Text("简体中文").tag(true)
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 220, alignment: .leading)
                        Spacer(minLength: 8)
                        Menu {
                        Button("Open transcript") { NSWorkspace.shared.open(meeting.url.appending(path: "transcript.md")) }
                        Button("Open source transcript") {
                            NSWorkspace.shared.open(meeting.url.appending(path: evidenceFileName(for: meeting)))
                        }
                        Button("Open meeting context") {
                            let file = meeting.url.deletingLastPathComponent().deletingLastPathComponent().appending(path: "meeting_context.md")
                            do {
                                if !FileManager.default.fileExists(atPath: file.path) {
                                    try "# Meeting context\n".write(to: file, atomically: true, encoding: .utf8)
                                }
                                NSWorkspace.shared.open(file)
                            } catch { self.error = error.localizedDescription }
                        }
                        Button("Show in Finder") { model.showInFinder(meeting.url) }
                        Divider()
                        Button("Move to project…", systemImage: "folder.badge.arrowshape.forward") {
                            model.meetingToMove = meeting
                            openWindow(id: "move-meeting")
                            NSApplication.shared.activate(ignoringOtherApps: true)
                        }
                        .disabled(busy || revision != nil || !model.canMoveMeeting(meeting))
                        } label: { Label("Files", systemImage: "folder") }
                    }.controlSize(.regular)
                    if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    if saved { Label("Summary saved. The previous version is backed up.", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    HStack(alignment: .top, spacing: 16) {
                        preview("Current summary", text: chinesePreview ? ((try? String(contentsOf: meeting.url.appending(path: "summary_cn.md"), encoding: .utf8)) ?? "No Chinese summary yet.") : current, showTitle: chinesePreview || changedTitle)
                        if let revision { preview("New summary", text: chinesePreview ? revision.chineseMarkdown : revision.markdown, showTitle: chinesePreview || changedTitle) }
                    }
                    Divider()
                    Text("Evidence: \(evidenceFileName(for: meeting))\(evidenceFileName(for: meeting) == "transcript.md" ? " (legacy fallback)" : "") · meeting context · \(URL(string: model.providerBaseURL)?.host ?? "configured provider")")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("Model: \(model.selectedModelID). Audio is not uploaded. Both summary languages are generated.")
                    HStack {
                        if busy {
                            ProgressView().controlSize(.small)
                            Text("Generating and checking evidence…").foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel") { cancel() }
                        } else if revision != nil {
                            Spacer(minLength: 0)
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
            }.padding(20).frame(minWidth: 550, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 850, minHeight: 550)
        .onAppear {
            if !busy && revision == nil { reload(); applyOpenRequest() }
        }
        .onChange(of: selection) { _, _ in loadCurrent() }
        .onChange(of: model.summaryOpenRequest) { _, _ in applyOpenRequest() }
        .onChange(of: busy) { _, value in
            if !value && revision == nil && pendingArchiveRefresh {
                pendingArchiveRefresh = false; reload()
            }
            applyOpenRequest()
        }
        .onChange(of: revision == nil) { _, empty in
            if empty, !busy {
                if let selection { model.summaryLockedURLs.remove(selection) }
                if pendingArchiveRefresh { pendingArchiveRefresh = false; reload() }
            }
            applyOpenRequest()
        }
        .onChange(of: model.lastMeetingMove) { _, move in
            guard let move else { return }
            if selection == move.source { selection = move.destination }
            if !busy && revision == nil { reload() }
            else { pendingArchiveRefresh = true }
        }
        .onChange(of: model.archiveRootPath) { _, _ in
            cancel()
            if !busy, let selection { model.summaryLockedURLs.remove(selection) }
            revision = nil; selection = nil; pendingArchiveRefresh = false; reload()
        }
        .onDisappear {
            cancel()
            if !busy, let selection { model.summaryLockedURLs.remove(selection); revision = nil }
        }
    }

    private func preview(_ title: String, text: String, showTitle: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ScrollView {
                SummaryMarkdownView(markdown: previewBody(text, showTitle: showTitle))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(16)
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
        }.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }
    // Identity is already displayed once in the shared header. Saved Markdown stays intact.
    private func previewBody(_ markdown: String, showTitle: Bool) -> String {
        var inPreamble = true
        return markdown.components(separatedBy: .newlines).filter { line in
            if line.hasPrefix("## ") { inPreamble = false }
            if inPreamble && ((!showTitle && line.hasPrefix("# ")) || line.hasPrefix("- Date: ") || line.hasPrefix("- Project: ")) { return false }
            return true
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func errorFreeTranscript(_ meeting: ArchivedMeeting) -> Bool {
        FileManager.default.fileExists(atPath: meeting.url.appending(path: evidenceFileName(for: meeting)).path)
    }
    private func evidenceFileName(for meeting: ArchivedMeeting) -> String {
        FileManager.default.fileExists(atPath: meeting.url.appending(path: SummaryEvidence.Source.raw.rawValue).path)
            ? SummaryEvidence.Source.raw.rawValue : SummaryEvidence.Source.legacy.rawValue
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
        let context = (try? store.meetingContext(for: meeting.projectName)) ?? ""
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
        model.summaryLockedURLs.insert(meeting.url)
        task = Task { @MainActor in
            defer {
                task = nil
                if revision == nil { model.summaryLockedURLs.remove(meeting.url) }
            }
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
            if let refreshed = try? store.recentMeetings(limit: Int.max) { meetings = refreshed }
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
