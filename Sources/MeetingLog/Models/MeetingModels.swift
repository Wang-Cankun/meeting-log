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
}

struct TranscriptBlock: Codable, Identifiable {
    enum Status: String, Codable {
        case pending
        case complete
        case failed
    }

    let id: Int
    let startSeconds: Double
    let endSeconds: Double
    var status: Status = .pending
    var text: String = ""
    var error: String?
}

struct ActionItem: Codable, Equatable {
    var assignee: String
    var task: String
    var deadline: String
    var context: String
}

struct MeetingDecision: Codable, Equatable {
    var decision: String
    var reasoning: String
}

struct MeetingAnalysis: Codable, Equatable {
    var title: String
    var projectName: String
    var summary: [String]
    var actionItems: [ActionItem]
    var decisions: [MeetingDecision]
    var keyTopics: [String]
}

struct ProjectContext: Equatable {
    let name: String
    let markdown: String
}

struct ProjectFolder: Identifiable, Equatable {
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
}

enum AppPhase: Equatable {
    case idle
    case recording(startedAt: Date)
    case failed(String)

    func recordingAction(isBusy: Bool) -> RecordingAction? {
        guard !isBusy else { return nil }
        if case .recording = self { return .stop }
        return .start
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
        if case .recording = phase {
            systemImage = "record.circle.fill"
            accessibilityLabel = "MeetingLog recording"
        } else {
            systemImage = "waveform"
            accessibilityLabel = "MeetingLog, ready"
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
