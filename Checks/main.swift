import Foundation

precondition(ArchiveStore.slug("  Café Project / Linux Test  ") == "cafe-project-linux-test")
precondition(ArchiveStore.slug("中文会议") == "zhong-wen-hui-yi")

let analysis = MeetingAnalysis(
    title: "Weekly sync",
    projectName: "Demo",
    projectSlug: "demo",
    summary: ["Reviewed the launch."],
    actionItems: [.init(assignee: "", task: "Send the draft", deadline: "", context: "")],
    decisions: [],
    keyTopics: []
)
let markdown = MarkdownRenderer.summary(analysis, startedAt: Date(timeIntervalSince1970: 0))
precondition(markdown.contains("- Send the draft\n"))
precondition(markdown.contains("## Decisions\n\nNone."))

precondition(AudioLevelState(level: 0.02) == .silence)
precondition(AudioLevelState(level: 0.03) == .active)
precondition(AudioLevelState(level: 0.82) == .high)
precondition(AudioLevelState(level: 0.96) == .clipping)
print("MeetingLog check passed")
