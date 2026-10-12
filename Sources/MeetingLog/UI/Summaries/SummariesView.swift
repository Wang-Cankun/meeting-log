import SwiftUI

private struct ArchiveSnapshot: Sendable {
    let projects: [String]
    let meetings: [ArchivedMeeting]
    let error: String?
}

/// Meeting summaries window: library sidebar, date-grouped meetings, the structured summary with evidence
/// chips, and the transcript inspector. Regeneration, preview and move flows keep their existing rules.
struct SummariesView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: AppModel
    @StateObject private var index = MeetingIndex()
    @StateObject private var navigator = TranscriptNavigator()
    @State private var meetings: [ArchivedMeeting] = []
    @State private var projectNames: [String] = []
    @State private var loaded = false
    @State private var reloadGeneration = 0
    @State private var now = Date()
    @State private var scope: LibraryScope? = .all
    @State private var selection: URL?
    @State private var query = ""
    @State private var handledRequestID: UUID?
    @State private var current = ""
    /// The meeting `current` was read from; nil until a selected meeting's files are loaded.
    @State private var loadedURL: URL?
    @State private var currentChinese: String?
    @State private var revision: SummaryRevision?
    @State private var task: Task<Void, Never>?
    @State private var error: String?
    @State private var saved = false
    @State private var missingContext = false
    @State private var chinesePreview = false
    @State private var pendingArchiveRefresh = false
    @State private var evidenceSource = SummaryEvidence.Source.raw
    @State private var transcriptAvailable = false
    @State private var showingNewProject = false
    /// The transcript inspector opens by default and remembers the user's choice.
    @AppStorage("summariesShowsTranscript") private var showsTranscript = true

    private var store: ArchiveStore { ArchiveStore(root: URL(filePath: model.archiveRootPath)) }
    private var service: SummaryRegenerator {
        SummaryRegenerator(store: store, client: ProviderClient(baseURL: model.providerBaseURL, apiKey: model.apiKey, model: model.selectedModelID))
    }
    private var meeting: ArchivedMeeting? { meetings.first { $0.url == selection } }
    private var busy: Bool { task != nil }
    /// Generation and unsaved previews pin the selection, as in the previous browser.
    private var locked: Bool { busy || revision != nil }
    private var activeScope: LibraryScope { scope ?? .all }
    private var inboxName: String {
        projectNames.first { $0.localizedCaseInsensitiveCompare(ArchiveStore.inboxName) == .orderedSame } ?? ArchiveStore.inboxName
    }
    private var scopedMeetings: [ArchivedMeeting] { meetings.filter(inScope) }
    private var visibleMeetings: [ArchivedMeeting] { scopedMeetings.filter(matchesQuery) }
    private var displayedMarkdown: String { chinesePreview ? (currentChinese ?? "No Chinese summary yet.") : current }
    private var proposedMarkdown: String? { revision.map { chinesePreview ? $0.chineseMarkdown : $0.markdown } }
    private var titleChanged: Bool {
        guard let proposedMarkdown else { return false }
        return SummaryDocument.parse(proposedMarkdown).title != SummaryDocument.parse(displayedMarkdown).title
    }
    private var canRegenerate: Bool {
        meeting?.hasSummary == true && !locked && transcriptAvailable && model.canGenerateSummaries
    }

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(scope: $scope, tree: MeetingLibrary.tree(projectNames), inboxName: inboxName,
                           counts: MeetingLibrary.counts(meetings), total: meetings.count) { showingNewProject = true }
                .disabled(locked)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } content: {
            MeetingListColumn(title: scopeTitle,
                              sections: MeetingLibrary.sections(visibleMeetings, now: now),
                              count: visibleMeetings.count,
                              selection: $selection, index: index, now: now,
                              emptyState: emptyState, refresh: { reload() })
                .disabled(locked)
                // The column's own width does not keep the list clear of the floating sidebar; this minimum does.
                .frame(minWidth: 285)
                .navigationSplitViewColumnWidth(min: 285, ideal: 300, max: 440)
                .searchable(text: $query, prompt: "Search titles and summaries")
        } detail: {
            detail
                .navigationSplitViewColumnWidth(min: 380, ideal: 560)
                .inspector(isPresented: $navigator.showsInspector) {
                    TranscriptInspector(navigator: navigator, player: navigator.player,
                                        evidenceLines: SummaryInline.references(inMarkdown: displayedMarkdown).map(\.line))
                        .inspectorColumnWidth(min: 280, ideal: 320, max: 600)
                }
                .toolbar { detailToolbar }
        }
        .environmentObject(navigator)
        .toolbar(removing: .title)
        .frame(minWidth: 960, minHeight: 600)
        .sheet(isPresented: $showingNewProject, onDismiss: { reload(reloadingCurrent: false) }) {
            NewProjectSheet(model: model)
        }
        .onAppear {
            navigator.showsInspector = showsTranscript
            if !locked { reload(); applyOpenRequest() }
        }
        .onChange(of: selection) { _, _ in loadCurrent() }
        .onChange(of: scope) { _, _ in
            if selection.map({ url in !visibleMeetings.contains { $0.url == url } }) ?? true {
                selection = visibleMeetings.first?.url
            }
        }
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
            if !locked { reload() } else { pendingArchiveRefresh = true }
        }
        .onChange(of: model.recentMeetings) { _, _ in
            // New or deleted meetings appear without a manual refresh.
            if !locked { reload(reloadingCurrent: false) } else { pendingArchiveRefresh = true }
        }
        .onChange(of: model.archiveRootPath) { _, _ in
            cancel()
            if !busy, let selection { model.summaryLockedURLs.remove(selection) }
            // Drop the old archive's list first, so the scope change cannot select one of its meetings.
            meetings = []; projectNames = []
            revision = nil; selection = nil; scope = .all; pendingArchiveRefresh = false; reload()
        }
        .onChange(of: navigator.showsInspector) { _, shown in
            if !shown { navigator.player.pause() }
            if showsTranscript != shown { showsTranscript = shown }
        }
        .onDisappear {
            cancel()
            if !busy, let selection { model.summaryLockedURLs.remove(selection); revision = nil }
            navigator.player.pause()
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let meeting {
            MeetingDetailView(
                meeting: meeting, markdown: displayedMarkdown, proposed: proposedMarkdown, titleChanged: titleChanged,
                duration: index.durations[meeting.url], speakers: navigator.source?.speakers ?? [],
                missingContext: missingContext, generating: busy, error: error, saved: saved,
                actions: .init(openContext: { openContext(for: meeting) }, cancel: cancel,
                               discard: { revision = nil; error = nil }, save: save))
        } else {
            ContentUnavailableView("Choose a meeting", systemImage: "doc.text",
                                   description: Text("Completed meetings with saved transcripts appear here."))
        }
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        // Without a window title, the flexible space keeps the actions at the trailing edge of the summary.
        ToolbarSpacer(.flexible)
        ToolbarItem(placement: .primaryAction) {
            Picker("Summary language", selection: $chinesePreview) {
                Text("Original").tag(false)
                Text("简体中文").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .disabled(meeting?.hasSummary != true)
            .help("Summary language")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: generate) { Label("Regenerate", systemImage: "arrow.triangle.2.circlepath") }
                .labelStyle(.titleAndIcon)
                .disabled(!canRegenerate)
                .help(regenerateHelp)
            Menu {
                if let meeting { moreMenu(meeting) }
            } label: { Label("More", systemImage: "ellipsis.circle") }
                .disabled(meeting == nil)
                .help("Files and move")
            Button { navigator.showsInspector.toggle() } label: {
                Label(navigator.showsInspector ? "Hide transcript" : "Show transcript", systemImage: "sidebar.right")
            }
            .help(navigator.showsInspector ? "Hide the transcript" : "Show the transcript. Click an L reference to jump to its line.")
        }
    }

    @ViewBuilder
    private func moreMenu(_ meeting: ArchivedMeeting) -> some View {
        Button("Open transcript") { NSWorkspace.shared.open(meeting.url.appending(path: SummaryEvidence.Source.legacy.rawValue)) }
        Button("Open source transcript") { NSWorkspace.shared.open(meeting.url.appending(path: evidenceSource.rawValue)) }
        Button("Open meeting context") { openContext(for: meeting) }
        Button("Show in Finder") { model.showInFinder(meeting.url) }
        Divider()
        Button("Move to project…", systemImage: "folder.badge.arrowshape.forward") {
            model.meetingToMove = meeting
            openWindow(id: "move-meeting")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        .disabled(locked || !model.canMoveMeeting(meeting))
    }

    /// Where a summary comes from, shown only on the Regenerate button rather than as a bar in the document.
    private var regenerateHelp: String {
        if meeting?.hasSummary == false { return "This meeting was saved as a transcript only, without an AI summary." }
        guard model.canGenerateSummaries else {
            return model.summariesEnabled ? "Add an AI provider in Settings to generate a summary."
                                          : "Turn on AI summaries in Settings to regenerate."
        }
        let host = URL(string: model.providerBaseURL)?.host ?? "the configured provider"
        let fallback = evidenceSource == .legacy ? " (legacy fallback)" : ""
        return "Generate a new summary from \(evidenceSource.rawValue)\(fallback) and the meeting context with \(model.selectedModelID) "
            + "on \(host), then compare it before saving. Audio is not uploaded; both summary languages are generated."
    }

    private var scopeTitle: String {
        switch activeScope {
        case .all: "All meetings"
        case let .project(name): name == inboxName ? "Inbox" : ProjectNode(name: name).displayName
        case let .own(name): "\(ProjectNode(name: name).displayName) · General"
        }
    }

    private var emptyState: MeetingListColumn.EmptyState? {
        guard loaded, visibleMeetings.isEmpty else { return nil }
        if meetings.isEmpty {
            return .init(title: "No meetings yet", systemImage: "tray", description: "Completed meetings appear here.")
        }
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            return .init(title: "No matching meetings", systemImage: "magnifyingglass",
                         description: "Try another title, project, or phrase from a summary.")
        }
        return .init(title: "No meetings yet", systemImage: "tray", description: "Meetings saved to this project appear here.")
    }

    private func inScope(_ meeting: ArchivedMeeting) -> Bool {
        activeScope.contains(projectName: meeting.projectName)
    }

    private func matchesQuery(_ meeting: ArchivedMeeting) -> Bool {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
        let fields = [meeting.title, meeting.projectName, MeetingLibrary.projectPath(meeting.projectName),
                      index.digests[meeting.url]?.searchText ?? ""]
        return MeetingLibrary.matches(query, fields: fields)
    }

    private func openContext(for meeting: ArchivedMeeting) {
        let file = meeting.url.deletingLastPathComponent().deletingLastPathComponent().appending(path: "meeting_context.md")
        do {
            if !FileManager.default.fileExists(atPath: file.path) {
                try "# Meeting context\n".write(to: file, atomically: true, encoding: .utf8)
            }
            NSWorkspace.shared.open(file)
        } catch { self.error = error.localizedDescription }
    }

    private func applyOpenRequest() {
        guard !locked, let request = model.summaryOpenRequest, request.id != handledRequestID else { return }
        handledRequestID = request.id
        // Consumed once: a later plain open, after this window is rebuilt, must not reselect it.
        model.summaryOpenRequest = nil
        query = ""
        selection = request.url
        reload()
    }

    /// Scans the archive off the main actor. The selection follows its meeting across scopes; a selection that
    /// no longer exists falls back to the first visible meeting.
    private func reload(reloadingCurrent: Bool = true) {
        reloadGeneration += 1
        let generation = reloadGeneration
        let root = URL(filePath: model.archiveRootPath)
        Task {
            let snapshot = await Task.detached(priority: .userInitiated) { () -> ArchiveSnapshot in
                let store = ArchiveStore(root: root)
                do {
                    return ArchiveSnapshot(projects: try store.projects().map(\.name),
                                           meetings: try store.recentMeetings(limit: Int.max), error: nil)
                } catch {
                    return ArchiveSnapshot(projects: [], meetings: [], error: error.localizedDescription)
                }
            }.value
            guard generation == reloadGeneration else { return }
            loaded = true
            now = Date()
            if let message = snapshot.error { error = message; return }
            projectNames = snapshot.projects
            meetings = snapshot.meetings
            index.refresh(meetings.map(\.url))
            if let name = activeScope.projectName, name != inboxName, !projectNames.contains(name) { scope = .all }
            let previous = selection
            if let selected = meeting {
                if !inScope(selected) { scope = .all }
            } else {
                selection = visibleMeetings.first?.url
            }
            // A later scan can supersede one that was meant to reload the selection, as when a move refreshes
            // both the recent meetings and the moved selection, so also load a selection that is not loaded yet.
            if selection == previous && (reloadingCurrent || loadedURL != meeting?.url) { loadCurrent() }
        }
    }

    private func loadCurrent() {
        error = nil; saved = false; revision = nil
        navigator.open(meeting?.url)
        loadedURL = meeting?.url
        guard let meeting else {
            current = ""; currentChinese = nil; missingContext = false; transcriptAvailable = false
            return
        }
        evidenceSource = TranscriptDocument.evidenceSource(in: meeting.url)
        transcriptAvailable = FileManager.default.fileExists(atPath: meeting.url.appending(path: evidenceSource.rawValue).path)
        guard meeting.hasSummary else {
            // Transcript-only meetings have no summary files to read.
            current = ""; currentChinese = nil; missingContext = false
            return
        }
        currentChinese = try? String(contentsOf: meeting.url.appending(path: "summary_cn.md"), encoding: .utf8)
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
            currentChinese = revision.chineseMarkdown
            index.invalidate(revision.meeting.url)
            self.revision = nil; error = nil; saved = true
            reload(reloadingCurrent: false)
        } catch { self.error = error.localizedDescription }
    }
}

#if DEBUG
extension SummariesView {
    /// Debug renderer entry: starts in a given scope and search, with a navigator the renderer can drive.
    init(model: AppModel, navigator: TranscriptNavigator, scope: LibraryScope?, query: String) {
        self.model = model
        _navigator = StateObject(wrappedValue: navigator)
        _scope = State(initialValue: scope)
        _query = State(initialValue: query)
    }
}
#endif
