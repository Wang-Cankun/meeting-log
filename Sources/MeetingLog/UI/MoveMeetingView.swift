import SwiftUI

struct MoveMeetingView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var destination = ""
    @State private var error: String?
    @State private var moved: ArchivedMeeting?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let moved {
                Label("Meeting moved", systemImage: "checkmark.circle.fill")
                    .font(.title2.bold()).foregroundStyle(.green)
                Text(moved.title).font(.headline)
                Text("Moved to \(moved.projectName).")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Review summary…") {
                        model.summaryOpenRequest = SummaryOpenRequest(url: moved.url)
                        openWindow(id: "meeting-summaries")
                        dismiss()
                    }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .help("Regenerate the summary using the new project’s context")
                }
            } else if let meeting = model.meetingToMove {
                Text("Move to project").font(.title2.bold())
                Text(meeting.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                Text("From: \(meeting.projectName)").font(.callout).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text("To").font(.headline)
                    ProjectChooser(projects: model.projects, selection: $destination, refresh: model.refreshArchive)
                }
                if !model.canMoveMeeting(meeting) {
                    Text(model.summaryLockedURLs.contains(meeting.url)
                         ? "Finish or close the summary review first."
                         : "Available when recording and processing finish.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                HStack {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Move") {
                        do { moved = try model.moveMeeting(meeting, to: destination); error = nil }
                        catch { self.error = error.localizedDescription; model.refreshArchive() }
                    }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(destination.isEmpty || destination == meeting.projectName || !model.canMoveMeeting(meeting))
                }
            }
        }
        .padding(24).frame(width: 420)
        .onAppear { reset() }
        .onChange(of: model.meetingToMove) { _, _ in reset() }
        .onChange(of: model.archiveRootPath) { _, _ in dismiss() }
    }

    private func reset() {
        destination = model.meetingToMove?.projectName ?? ""
        moved = nil; error = nil
        model.refreshArchive()
    }
}
