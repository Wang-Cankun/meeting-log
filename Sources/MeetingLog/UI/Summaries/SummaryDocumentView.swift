import SwiftUI

/// Renders a summary as a structured document. Sections that the typed forms cannot hold fall back to
/// block-by-block Markdown, so hand-edited and legacy content is never dropped.
struct SummaryDocumentView: View {
    let markdown: String
    var showsTitle = false

    var body: some View {
        let document = SummaryDocument.parse(markdown)
        VStack(alignment: .leading, spacing: 24) {
            if showsTitle, let title = document.title {
                Text(title).font(.title3.bold()).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(document.sections) { SummarySectionView(section: $0) }
        }
        .font(SummaryType.body)
        .lineSpacing(SummaryType.lineSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

/// Type scale of the summary document.
enum SummaryType {
    static let body = Font.system(size: 13.5)
    static let note = Font.system(size: 12.5)
    static let heading = Font.system(size: 15, weight: .semibold)
    static let lineSpacing: CGFloat = 4.5
}

private struct SummarySectionView: View {
    let section: SummarySection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let heading = section.heading {
                Text(heading).font(SummaryType.heading).accessibilityAddTraits(.isHeader)
            }
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch section.body {
        case let .actions(cards):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(cards.enumerated()), id: \.offset) { _, card in ActionCardView(card: card) }
            }
        case let .items(items):
            if section.kind == .needsVerification {
                VerificationCallout(items: items)
            } else if section.kind == .keyTopics, items.allSatisfy({ $0.notes.isEmpty && $0.evidence.isEmpty }) {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        InlineText.styled(InlineText.attributed(SummaryInline.markingVerification(item.text)))
                            .font(.system(size: 12.5))
                            .lineSpacing(0)
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .background(Color(nsColor: .quaternarySystemFill), in: Capsule())
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in ItemRow(item: item) }
                }
            }
        case let .blocks(blocks):
            MarkdownBlocksView(blocks: blocks)
        }
    }
}

/// A list marker in the secondary colour, set in the body font so it shares the first line's baseline.
private struct Marker: View {
    let text: String

    var body: some View {
        Text(verbatim: text == "•" ? "•" : text)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
            .frame(minWidth: 8, alignment: .leading)
            .accessibilityHidden(true)
    }
}

private struct ItemRow: View {
    let item: SummaryItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Marker(text: item.marker)
            VStack(alignment: .leading, spacing: 3) {
                InlineText(text: item.text, trailing: item.evidence)
                // Decisions carry their stated reasoning here; other sections carry context.
                ForEach(Array(item.notes.enumerated()), id: \.offset) { _, note in
                    InlineText(text: note).font(SummaryType.note).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ActionCardView: View {
    let card: ActionCard

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            InlineText(text: card.task).fontWeight(.medium)
            // Unstated owners and deadlines are left out rather than shown as "not stated".
            if card.owner != nil || card.deadline != nil || !card.evidence.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    if let owner = card.owner { FieldTag(label: "Owner", value: owner, prominent: true) }
                    if let deadline = card.deadline { FieldTag(label: "Due", value: deadline, prominent: false) }
                    ForEach(Array(card.evidence.enumerated()), id: \.offset) { _, mark in EvidenceChip(mark: mark) }
                }
            }
            ForEach(Array(card.notes.enumerated()), id: \.offset) { _, note in
                InlineText(text: note).font(SummaryType.note).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

private struct FieldTag: View {
    let label: String
    let value: String
    let prominent: Bool

    var body: some View {
        Text(verbatim: "\(label) · \(value)")
            .font(.system(size: 11.5))
            .lineSpacing(0)
            .foregroundStyle(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary.opacity(0.8)))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(prominent ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(Color(nsColor: .quaternarySystemFill)),
                        in: Capsule())
            .accessibilityLabel("\(label): \(value)")
    }
}

private struct VerificationCallout: View {
    let items: [SummaryItem]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
                .accessibilityLabel("Needs verification")
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if items.count > 1 { Marker(text: item.marker) }
                        VStack(alignment: .leading, spacing: 3) {
                            // The whole block needs verification, so per-item markers are not repeated here.
                            InlineText(text: Self.unmarked(item.text), trailing: item.evidence)
                            ForEach(Array(item.notes.enumerated()), id: \.offset) { _, note in
                                InlineText(text: note).font(SummaryType.note).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .font(.system(size: 13))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private static func unmarked(_ text: String) -> String {
        SummaryInline.markingVerification(text).replacingOccurrences(of: String(SummaryInline.verificationMark), with: "")
    }
}

/// Generic Markdown blocks for legacy, hand-edited or unknown sections.
struct MarkdownBlocksView: View {
    let blocks: [SummaryMarkdown]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in view(for: block) }
        }
    }

    @ViewBuilder
    private func view(for block: SummaryMarkdown) -> some View {
        switch block {
        case let .heading(level, text):
            InlineText(text: text)
                .font(level == 1 ? .title3.bold() : level == 2 ? SummaryType.heading : .system(size: 13.5, weight: .semibold))
                .padding(.top, level == 1 ? 0 : 6)
        case let .bullet(marker, text, depth):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Marker(text: marker)
                InlineText(text: text).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(depth) * 16)
        case let .detail(text, depth):
            InlineText(text: text)
                .font(SummaryType.note).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 18 + CGFloat(depth) * 16)
        case let .quote(text):
            InlineText(text: text)
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 3) }
        case let .table(header, rows):
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in tableRow(row, header: header) }
        case let .paragraph(text):
            InlineText(text: text)
        case .rule:
            Divider()
        }
    }

    /// Rows render as cards: first column as the title, short middle columns as a caption,
    /// and a final long column (such as context and evidence) as the body.
    private func tableRow(_ cells: [String], header: [String]) -> some View {
        let caption = cells.count > 2 ? Array(cells.dropFirst().dropLast()) : Array(cells.dropFirst())
        let captionText = caption.enumerated().map { index, value in
            index + 1 < header.count ? "\(header[index + 1]): \(value)" : value
        }.joined(separator: " · ")
        let body = cells.count > 2 ? cells.last : nil
        return VStack(alignment: .leading, spacing: 6) {
            if let title = cells.first { InlineText(text: title).fontWeight(.medium) }
            if !captionText.isEmpty { InlineText(text: captionText).font(.system(size: 11.5)).foregroundStyle(.secondary) }
            if let body, body != "—" {
                ForEach(Array(body.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                    InlineText(text: line).font(SummaryType.note).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: .separatorColor)))
    }
}
