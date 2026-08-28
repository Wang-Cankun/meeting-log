import Foundation

enum SessionStatus: String, Codable {
    case recording
    case captured
    case processing
    case complete
    case failed
}

struct SessionManifest: Codable, Identifiable {
    let id: UUID
    let startedAt: Date
    var status: SessionStatus
    var videoEnabled: Bool
    var microphoneID: String?
    var lastError: String?
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
    var projectSlug: String
    var summary: [String]
    var actionItems: [ActionItem]
    var decisions: [MeetingDecision]
    var keyTopics: [String]
}

struct ProjectChoice: Codable, Equatable {
    var title: String
    var projectName: String
    var projectSlug: String
}

struct ProjectContext: Equatable {
    let slug: String
    let markdown: String
}

enum AppPhase: Equatable {
    case idle
    case recording(startedAt: Date)
    case failed(String)
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
        case .silence: "Monitoring, silence"
        case .active: "Audio detected"
        case .high: "High level"
        case .clipping: "Near clipping"
        }
    }
}
