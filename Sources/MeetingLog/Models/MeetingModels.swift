import Foundation

enum SessionStatus: String, Codable {
    case recording
    case captured
    case processing
    case failed
}

struct SessionManifest: Codable, Identifiable {
    let id: UUID
    let startedAt: Date
    var status: SessionStatus
    var videoEnabled: Bool
    var microphoneID: String?
    var lastError: String?
    var projectName: String? = nil
    var importedFileName: String? = nil
    var importedParts: [ImportedAudioPart]? = nil
}

/// Captured meetings transcribe each raw track separately so the microphone identifies the recording user.
enum TranscriptTrack: String, Codable, Sendable {
    case system
    case microphone
}

struct TranscriptBlock: Codable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable {
        case pending
        case complete
        case failed
    }

    let id: Int
    let startSeconds: Double
    let endSeconds: Double
    var track: TranscriptTrack? = nil
    var status: Status = .pending
    var text: String = ""
    var error: String?
}

struct ActionItem: Codable, Equatable {
    var assignee: String
    var task: String
    var deadline: String
    var context: String
    var evidence: [EvidenceReference]? = nil
}

struct MeetingDecision: Codable, Equatable {
    var decision: String
    var reasoning: String
    var evidence: [EvidenceReference]? = nil
}

struct MeetingAnalysis: Codable, Equatable {
    var title: String
    var projectName: String
    var summary: [String]
    var actionItems: [ActionItem]
    var decisions: [MeetingDecision]
    var keyTopics: [String]
    var uncertainties: [String]? = nil
    var milestones: [EvidenceNote]? = nil
    var openQuestions: [EvidenceNote]? = nil
    var deferredWork: [EvidenceNote]? = nil
    var inventory: [EvidenceNote]? = nil
}

// Prompts ask for empty strings and arrays when a field is unsupported; JSON mode does not enforce the schema,
// so a model that omits such a field means the same thing and must not fail the whole meeting.
extension ActionItem {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(assignee: try values.decodeIfPresent(String.self, forKey: .assignee) ?? "",
                  task: try values.decode(String.self, forKey: .task),
                  deadline: try values.decodeIfPresent(String.self, forKey: .deadline) ?? "",
                  context: try values.decodeIfPresent(String.self, forKey: .context) ?? "",
                  evidence: try values.decodeIfPresent([EvidenceReference].self, forKey: .evidence))
    }
}

extension MeetingDecision {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(decision: try values.decode(String.self, forKey: .decision),
                  reasoning: try values.decodeIfPresent(String.self, forKey: .reasoning) ?? "",
                  evidence: try values.decodeIfPresent([EvidenceReference].self, forKey: .evidence))
    }
}

extension MeetingAnalysis {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(title: try values.decode(String.self, forKey: .title),
                  projectName: try values.decodeIfPresent(String.self, forKey: .projectName) ?? "",
                  summary: try values.decodeIfPresent([String].self, forKey: .summary) ?? [],
                  actionItems: try values.decodeIfPresent([ActionItem].self, forKey: .actionItems) ?? [],
                  decisions: try values.decodeIfPresent([MeetingDecision].self, forKey: .decisions) ?? [],
                  keyTopics: try values.decodeIfPresent([String].self, forKey: .keyTopics) ?? [],
                  uncertainties: try values.decodeIfPresent([String].self, forKey: .uncertainties),
                  milestones: try values.decodeIfPresent([EvidenceNote].self, forKey: .milestones),
                  openQuestions: try values.decodeIfPresent([EvidenceNote].self, forKey: .openQuestions),
                  deferredWork: try values.decodeIfPresent([EvidenceNote].self, forKey: .deferredWork),
                  inventory: try values.decodeIfPresent([EvidenceNote].self, forKey: .inventory))
    }
}

struct ProjectContext: Equatable {
    let name: String
    let markdown: String
}

struct ProjectFolder: Identifiable, Equatable {
    var displayName: String { url.lastPathComponent }
    var displayPath: String {
        [parentDisplay, displayName].filter { !$0.isEmpty }.joined(separator: " › ")
    }
    var parentDisplay: String {
        name.split(separator: "/").dropLast().filter { !["projects", "studies"].contains(String($0)) }.joined(separator: " › ")
    }

    var id: URL { url }
    let name: String
    let url: URL
}

struct ArchivedMeeting: Identifiable, Equatable {
    var id: URL { url }
    let title: String
    let projectName: String
    let dateText: String
    let date: Date
    let createdAt: Date
    let url: URL
    var captureWarning: String? = nil
    /// False for meetings processed with AI summaries off: the folder holds audio and transcripts only.
    var hasSummary = true
}

/// Steps between Stop and handing the session to processing; raw tracks are never removed here.
enum SavingStep: Int, CaseIterable, Equatable {
    case stoppingTracks
    case mixingAudio
    case handingOff
}

enum AppPhase: Equatable {
    case idle
    case recording(startedAt: Date)
    /// Stop was requested: the timer is frozen at `duration` while tracks close and mix.
    case saving(duration: TimeInterval, step: SavingStep)
    case failed(String)

    func recordingAction(isBusy: Bool) -> RecordingAction? {
        guard !isBusy else { return nil }
        switch self {
        case .recording: return .stop
        case .saving: return nil
        case .idle, .failed: return .start
        }
    }

    var clearingFailure: AppPhase {
        if case .failed = self { return .idle }
        return self
    }
}

enum RecordingAction: Equatable {
    case start
    case stop
}

enum RecordingDurationPolicy {
    static let minimumSeconds: TimeInterval = 10

    static func shouldProcess(startedAt: Date, stoppedAt: Date) -> Bool {
        stoppedAt.timeIntervalSince(startedAt) >= minimumSeconds
    }
}

struct StatusItemPresentation: Equatable {
    let systemImage: String
    let accessibilityLabel: String

    init(phase: AppPhase) {
        switch phase {
        case .recording:
            systemImage = "record.circle.fill"
            accessibilityLabel = "MeetingLog recording"
        case .saving:
            // Saving must never claim that capture is still running.
            systemImage = "waveform"
            accessibilityLabel = "MeetingLog, saving recording"
        case .idle, .failed:
            systemImage = "waveform"
            accessibilityLabel = "MeetingLog, ready"
        }
    }
}

/// Structured processing position; the panel draws `segmentTitles` as a six-segment bar.
enum ProcessingStage: Equatable, Sendable {
    case prepare
    case transcribe(completed: Int, total: Int)
    case clean
    case summary
    case evidence
    case chinese
    case complete

    static let segmentTitles = ["Prepare", "Transcribe", "Clean", "Summary", "Evidence", "中文"]

    /// Index of the current segment in `segmentTitles`; `complete` is 6, meaning every segment is full.
    var segment: Int {
        switch self {
        case .prepare: 0
        case .transcribe: 1
        case .clean: 2
        case .summary: 3
        case .evidence: 4
        case .chinese: 5
        case .complete: 6
        }
    }

    /// Partial fill of the current segment: completed/total while transcribing, otherwise 0.
    var segmentFraction: Double {
        guard case let .transcribe(completed, total) = self, total > 0 else { return 0 }
        return min(1, max(0, Double(completed) / Double(total)))
    }

    /// Transcript-only jobs end after Clean, so their bar shows only the stages they run.
    static func segmentTitles(summaries: Bool) -> [String] {
        summaries ? segmentTitles : Array(segmentTitles.prefix(3))
    }

    /// The stage bar's VoiceOver value, counting only the segments the job runs.
    static func progressDescription(_ stage: ProcessingStage?, summaries: Bool) -> String {
        guard let stage else { return "Not started" }
        let titles = segmentTitles(summaries: summaries)
        guard stage.segment < titles.count else { return "Complete" }
        let title = titles[stage.segment] == "中文" ? "Chinese" : titles[stage.segment]
        if case let .transcribe(completed, total) = stage, total > 0 {
            return "Step \(stage.segment + 1) of \(titles.count), \(title), \(completed) of \(total)"
        }
        return "Step \(stage.segment + 1) of \(titles.count), \(title)"
    }
}

struct ProcessingProgress: Equatable, Sendable {
    var stage: ProcessingStage
    /// Human-readable line shown under the stage bar.
    var detail: String
    /// False for a job processed with AI summaries off.
    var summaries = true
}

/// One pending (not yet archived) session as the panel's Recent list shows it.
struct PendingMeetingItem: Identifiable, Equatable {
    enum State: Equatable {
        case processing
        case queued
        case failed(String)
        case waitingForProvider
        case needsRetry

        var sortOrder: Int {
            switch self {
            case .processing: 0
            case .queued: 1
            case .failed: 2
            case .waitingForProvider: 3
            case .needsRetry: 4
            }
        }
    }

    /// The pending session directory.
    let id: URL
    let startedAt: Date
    let title: String
    let projectName: String?
    let state: State

    init(directory: URL, manifest: SessionManifest, state: State) {
        id = directory
        startedAt = manifest.startedAt
        title = manifest.importedFileName ?? "Recording"
        projectName = manifest.projectName
        self.state = state
    }

    static func state(for manifest: SessionManifest, path: String, processingPath: String?,
                      queuedPaths: Set<String>, providerReady: Bool) -> State {
        if path == processingPath { return .processing }
        if queuedPaths.contains(path) { return .queued }
        if manifest.status == .failed { return .failed(manifest.lastError ?? "Processing stopped before completion.") }
        if !providerReady { return .waitingForProvider }
        return .needsRetry
    }

    /// Active work first, then failures, then idle sessions; newest first within a state.
    static func sorted(_ items: [Self]) -> [Self] {
        items.sorted {
            ($0.state.sortOrder, -$0.startedAt.timeIntervalSinceReferenceDate)
                < ($1.state.sortOrder, -$1.startedAt.timeIntervalSinceReferenceDate)
        }
    }
}

enum AudioLevelState: Equatable {
    case silence
    case active
    case high
    case clipping

    init(level: Float) {
        switch level {
        case 0..<0.03: self = .silence
        case 0.03..<0.82: self = .active
        case 0.82..<0.96: self = .high
        default: self = .clipping
        }
    }

    var label: String {
        switch self {
        case .silence: "Listening for audio"
        case .active: "Audio detected"
        case .high: "High level"
        case .clipping: "Near clipping"
        }
    }
}


struct ImportedAudioPart: Codable, Equatable {
    let fileName: String
    let originalName: String
    let duration: TimeInterval
}

/// A menu action is an event, even when it targets the same meeting twice.
struct SummaryOpenRequest: Equatable {
    let id = UUID()
    let url: URL
}

struct EvidenceReference: Codable, Equatable {
    var line: Int
    let quote: String
    var verified: Bool? = nil
}

struct EvidenceNote: Codable, Equatable {
    let text: String
    var evidence: [EvidenceReference]? = nil
}
