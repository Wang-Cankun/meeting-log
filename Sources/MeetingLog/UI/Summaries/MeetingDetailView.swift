import SwiftUI

/// The selected meeting: identity header, notices, the structured summary, and generation or preview state.
struct MeetingDetailView: View {
    struct Actions {
        let openContext: () -> Void
        let cancel: () -> Void
        let discard: () -> Void
        let save: () -> Void
    }

    let meeting: ArchivedMeeting
    /// The summary in the chosen language.
    let markdown: String
    /// The proposed summary in the chosen language while a regenerated preview is pending.
    let proposed: String?
    let titleChanged: Bool
    let duration: Double?
    let speakers: [String]
    let missingContext: Bool
    let generating: Bool
    let error: String?
    let saved: Bool
    let actions: Actions

    var body: some View {
        let document = SummaryDocument.parse(markdown)
        VStack(spacing: 0) {
            if let proposed {
                VStack(alignment: .leading, spacing: 14) {
                    header(document)
                    notices
                    previewBar
                    HStack(alignment: .top, spacing: 16) {
                        column("Current summary", markdown: markdown)
                        column("New summary", markdown: proposed)
                    }
                }
                .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                if generating { generationBar.padding(.horizontal, 24).padding(.top, 10) }
                ScrollView {
                    // A readable measure: the document keeps its line length on wide windows.
                    VStack(alignment: .leading, spacing: 22) {
                        header(document)
                        notices
                        SummaryDocumentView(markdown: markdown)
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, 32).padding(.top, 10).padding(.bottom, 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func header(_ document: SummaryDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(MeetingLibrary.projectPath(meeting.projectName))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Text(document.title ?? meeting.title)
                .font(.system(size: 24, weight: .bold))
                .kerning(-0.2)
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            FlowLayout(spacing: 6, lineSpacing: 6) {
                MetadataChip(systemImage: "calendar", text: dateText(document), label: "Date")
                if let duration = duration.flatMap(MeetingLibrary.duration) {
                    MetadataChip(systemImage: "clock", text: duration, label: "Duration")
                }
                if !speakers.isEmpty {
                    let shown = speakers.prefix(4).joined(separator: ", ")
                    MetadataChip(systemImage: "person.2", text: speakers.count > 4 ? "\(shown) +\(speakers.count - 4)" : shown,
                                 label: "Speakers")
                        .help(speakers.joined(separator: ", "))
                }
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var notices: some View {
        if missingContext {
            HStack(spacing: 10) {
                Image(systemName: "info.circle").foregroundStyle(Color.accentColor).accessibilityHidden(true)
                Text("Project context is empty. Add confirmed participants, terms, and handoff locations to improve this summary.")
                    .font(.system(size: 12)).foregroundStyle(.primary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Open context", action: actions.openContext).controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
        if let warning = meeting.captureWarning {
            Label(warning, systemImage: "exclamationmark.triangle")
                .font(.system(size: 12)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
        if let error {
            Text(error).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        if saved {
            Label("Summary saved. The previous version is backed up.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    private var generationBar: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Generating and checking evidence…").foregroundStyle(.secondary)
            Spacer()
            Button("Cancel", action: actions.cancel)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var previewBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.on.doc").foregroundStyle(.secondary).accessibilityHidden(true)
            Text("Compare the new summary with the current one. Nothing is replaced until you save.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Discard preview", action: actions.discard)
            Button("Save new summary", action: actions.save).buttonStyle(.borderedProminent)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func column(_ title: String, markdown: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ScrollView {
                SummaryDocumentView(markdown: markdown, showsTitle: titleChanged)
                    .padding(16)
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }

    private func dateText(_ document: SummaryDocument) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        let sameYear = Calendar.current.isDate(meeting.date, equalTo: Date(), toGranularity: .year)
        guard let start = SummaryDocument.startDate(document.date) else {
            formatter.dateFormat = sameYear ? "EEE, MMM d" : "EEE, MMM d, yyyy"
            return formatter.string(from: meeting.date)
        }
        formatter.dateFormat = sameYear ? "EEE, MMM d · HH:mm" : "EEE, MMM d, yyyy · HH:mm"
        return formatter.string(from: start)
    }
}

private struct MetadataChip: View {
    let systemImage: String
    let text: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).font(.system(size: 11)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(verbatim: text).font(.system(size: 12)).foregroundStyle(.primary.opacity(0.85)).lineLimit(1)
        }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color(nsColor: .quaternarySystemFill), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("\(label): \(text)")
    }
}
