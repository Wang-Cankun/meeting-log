import SwiftUI

/// Wraps subviews into lines, aligning each line on its first text baseline.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    private struct Item {
        let index: Int
        let x: CGFloat
        let size: CGSize
        let ascent: CGFloat
    }

    private struct Line {
        var items: [Item] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        guard let last = lines.last else { return .zero }
        return CGSize(width: lines.map(\.width).max() ?? 0, height: last.y + last.ascent + last.descent)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for line in arrange(width: bounds.width, subviews: subviews) {
            for item in line.items {
                subviews[item.index].place(at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + line.y + line.ascent - item.ascent),
                                           proposal: ProposedViewSize(item.size))
            }
        }
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? {
        guard guide == .firstTextBaseline, let first = arrange(width: bounds.width, subviews: subviews).first else { return nil }
        return first.ascent
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        var lineIsFull = false
        for (index, subview) in subviews.enumerated() {
            var size = subview.sizeThatFits(.unspecified)
            let wraps = size.width > width
            if wraps { size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            let ascent = subview.dimensions(in: ProposedViewSize(size))[VerticalAlignment.firstTextBaseline]
            // An item wrapped onto several lines owns its line, so nothing sits beside its first line only.
            if !line.items.isEmpty, wraps || lineIsFull || line.width + spacing + size.width > width {
                let next = line.y + line.ascent + line.descent + lineSpacing
                lines.append(line)
                line = Line(y: next)
            }
            let x = line.items.isEmpty ? 0 : line.width + spacing
            line.items.append(Item(index: index, x: x, size: size, ascent: ascent))
            line.width = x + size.width
            line.ascent = max(line.ascent, ascent)
            line.descent = max(line.descent, size.height - ascent)
            lineIsFull = wraps
        }
        if !line.items.isEmpty { lines.append(line) }
        return lines
    }
}

/// Summary text with `L<n>` references as chip buttons. Text without inline references stays a single selectable
/// `Text`; with inline references the text is split at word boundaries (each CJK character is one) so chips flow
/// inline, at the cost of selecting only one word at a time.
struct InlineText: View {
    let text: String
    /// Evidence from the item's `Evidence:` line, shown after the text.
    var trailing: [EvidenceMark] = []

    private enum Token {
        case words(AttributedString, spaceAfter: Bool)
        /// Adjacent brackets and punctuation travel with the chip so a line never starts with `)` or `，`.
        case chip(EvidenceMark, prefix: String, suffix: String)
    }

    var body: some View {
        let inline = SummaryInline.runs(text).map { run -> InlineRun in
            if case let .text(value) = run { return .text(SummaryInline.markingVerification(value)) }
            return run
        }
        let runs = inline + trailing.map(InlineRun.reference)
        let flagged = text != SummaryInline.markingVerification(text)
        Group {
            if !inline.contains(where: { if case .reference = $0 { true } else { false } }), !trailing.isEmpty {
                // Evidence from an `Evidence:` line follows the whole text, which stays one selectable,
                // sentence-level accessible `Text`. Chips sit beside a one-line text and wrap below a longer one.
                FlowLayout(spacing: 5, lineSpacing: 4) {
                    Self.styled(Self.attributed(SummaryInline.markingVerification(text))).fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(trailing.enumerated()), id: \.offset) { _, mark in EvidenceChip(mark: mark) }
                }
            } else if runs.contains(where: { if case .reference = $0 { true } else { false } }) {
                FlowLayout(spacing: 0, lineSpacing: 4) {
                    ForEach(Array(tokens(runs).enumerated()), id: \.offset) { _, token in
                        switch token {
                        case let .words(value, spaceAfter):
                            Self.styled(value).padding(.trailing, spaceAfter ? 3.5 : 0)
                        case let .chip(mark, prefix, suffix):
                            HStack(alignment: .firstTextBaseline, spacing: 0) {
                                if !prefix.isEmpty { Text(prefix) }
                                EvidenceChip(mark: mark).padding(.horizontal, 1.5)
                                if !suffix.isEmpty { Text(suffix) }
                            }
                        }
                    }
                }
            } else {
                Self.styled(Self.attributed(SummaryInline.markingVerification(text))).fixedSize(horizontal: false, vertical: true)
            }
        }
        .help(flagged ? "Terms marked with a warning sign need verification" : "")
    }

    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    /// Text with each `SummaryInline.verificationMark` drawn as a small amber warning sign.
    static func styled(_ value: AttributedString) -> Text {
        let characters = value.characters
        guard characters.contains(SummaryInline.verificationMark) else { return Text(value) }
        var result = Text(verbatim: "")
        var start = characters.startIndex
        var index = start
        while index < characters.endIndex {
            if characters[index] == SummaryInline.verificationMark {
                result = Text("\(result)\(Text(AttributedString(value[start..<index])))\(verificationIcon)")
                start = characters.index(after: index)
            }
            index = characters.index(after: index)
        }
        return Text("\(result)\(Text(AttributedString(value[start..<characters.endIndex])))")
    }

    private static var verificationIcon: Text {
        Text("\u{2009}\(Image(systemName: "exclamationmark.triangle.fill"))")
            .font(.system(size: 9.5))
            .baselineOffset(1)
            .foregroundStyle(Color.orange)
            .accessibilityLabel("Needs verification")
    }

    private func tokens(_ original: [InlineRun]) -> [Token] {
        var runs = original
        var prefixes: [Int: String] = [:]
        var suffixes: [Int: String] = [:]
        for index in runs.indices {
            guard case .reference = runs[index] else { continue }
            if index > 0, case let .text(before) = runs[index - 1] {
                let opening = String(before.reversed().prefix { Self.isOpeningPunctuation($0) }.reversed())
                prefixes[index] = opening
                runs[index - 1] = .text(String(before.dropLast(opening.count)))
            }
            if index + 1 < runs.count, case let .text(after) = runs[index + 1] {
                let closing = String(after.prefix { Self.isClosingPunctuation($0) })
                suffixes[index] = closing
                runs[index + 1] = .text(String(after.dropFirst(closing.count)))
            }
        }
        var result: [Token] = []
        for (position, run) in runs.enumerated() {
            switch run {
            case let .reference(mark):
                result.append(.chip(mark, prefix: prefixes[position] ?? "", suffix: suffixes[position] ?? ""))
            case let .text(value):
                let attributed = Self.attributed(value)
                let characters = attributed.characters
                var start = characters.startIndex
                var index = characters.startIndex
                func flush(to end: AttributedString.Index, spaceAfter: Bool) {
                    let slice = AttributedString(attributed[start..<end])
                    if !slice.characters.isEmpty { result.append(.words(slice, spaceAfter: spaceAfter)) }
                    else if spaceAfter, case let .words(previous, _)? = result.last { result[result.count - 1] = .words(previous, spaceAfter: true) }
                }
                while index < characters.endIndex {
                    let character = characters[index]
                    let next = characters.index(after: index)
                    if character.isWhitespace {
                        flush(to: index, spaceAfter: true)
                        start = next
                    } else if next < characters.endIndex, Self.breaks(after: character, before: characters[next]) {
                        flush(to: next, spaceAfter: false)
                        start = next
                    }
                    index = next
                }
                flush(to: characters.endIndex, spaceAfter: false)
            }
        }
        return result
    }

    /// CJK text may wrap between characters. Punctuation stays inside a token, because a separate `Text`
    /// compresses full-width punctuation at its end, and lines must not end on opening or start on closing marks.
    private static func breaks(after character: Character, before next: Character) -> Bool {
        if isClosingPunctuation(next) || isClosingPunctuation(character) || isOpeningPunctuation(character) { return false }
        return isCJK(character) || isCJK(next)
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let value = character.unicodeScalars.first?.value else { return false }
        return (0x2E80...0x9FFF).contains(value) || (0xAC00...0xD7AF).contains(value)
            || (0xF900...0xFAFF).contains(value) || (0xFF00...0xFFEF).contains(value)
    }

    private static func isOpeningPunctuation(_ character: Character) -> Bool {
        "（「『“‘《〈【(".contains(character)
    }

    private static func isClosingPunctuation(_ character: Character) -> Bool {
        "，。、；：！？）」』”’》〉】,.;:!?)".contains(character)
    }
}

/// Speaker colours: `Me` uses the accent colour; others take palette entries by order of appearance.
/// Neighbouring entries differ in lightness as well as hue, and every coloured label also shows the name.
enum SpeakerStyle {
    private static let palette: [Color] = [.purple, .teal, .brown, .pink, .indigo, .mint, .orange]

    static func color(for speaker: String, in document: TranscriptDocument?) -> Color {
        if speaker == "Me" { return .accentColor }
        let rank = document?.rank(of: speaker) ?? speaker.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[abs(rank) % palette.count]
    }
}

struct EvidenceChip: View {
    let mark: EvidenceMark
    @EnvironmentObject private var navigator: TranscriptNavigator
    @State private var presented = false

    var body: some View {
        Button { presented = true } label: {
            Text(verbatim: "L\(mark.line)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(mark.verified ? (presented ? Color.white : Color.accentColor) : Color.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background {
                    if mark.verified {
                        RoundedRectangle(cornerRadius: 5).fill(presented ? Color.accentColor : Color.accentColor.opacity(0.12))
                    } else {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.secondary.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            EvidencePopover(mark: mark, navigator: navigator, player: navigator.player) { presented = false }
        }
        .help(mark.verified ? "Evidence from transcript line \(mark.line)" : "Approximate reference to transcript line \(mark.line)")
        .accessibilityLabel(mark.verified ? "Evidence, line \(mark.line)" : "Approximate evidence, line \(mark.line)")
    }
}

struct EvidencePopover: View {
    let mark: EvidenceMark
    @ObservedObject var navigator: TranscriptNavigator
    @ObservedObject var player: TranscriptPlayer
    let dismiss: () -> Void

    var body: some View {
        let line = navigator.source?.line(mark.line)
        let cue = navigator.source?.cueSeconds(for: mark.line)
        VStack(alignment: .leading, spacing: 8) {
            header(line)
            if !mark.verified {
                Label("Approximate reference: the summary's quote was not found on this line. Check nearby lines.",
                      systemImage: "questionmark.circle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if navigator.loading {
                ProgressView().controlSize(.small)
            } else if let line {
                Text(verbatim: "“\(Self.body(of: line))”")
                    .font(.system(size: 13)).lineSpacing(3).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(verbatim: navigator.error ?? "Line L\(mark.line) is not in \(navigator.sourceFile).")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !mark.verified, let quote = mark.quote, !quote.isEmpty {
                Text("Summary quoted: “\(quote)”")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button {
                    navigator.play(line: mark.line)
                    dismiss()
                } label: {
                    Label(cue.map { "Play from \(Self.clock($0))" } ?? "Play", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                // A line outside the file would otherwise cue the last timestamp before it.
                .disabled(line == nil || cue == nil || !player.isAvailable)
                Button("Show in transcript") {
                    navigator.show(line: mark.line)
                    dismiss()
                }
                .disabled(line == nil)
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(width: 320, alignment: .leading)
    }

    @ViewBuilder
    private func header(_ line: TranscriptLine?) -> some View {
        HStack(spacing: 6) {
            if case let .turn(speaker, stamp, _) = line?.kind {
                let color = SpeakerStyle.color(for: speaker, in: navigator.source)
                Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(speaker).fontWeight(.semibold).foregroundStyle(color)
                Text(verbatim: "· \(stamp) · L\(mark.line)").foregroundStyle(.secondary)
            } else {
                Text(verbatim: "L\(mark.line) · \(navigator.sourceFile)").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    private static func body(of line: TranscriptLine) -> String {
        switch line.kind {
        case let .turn(_, _, text): text
        case let .heading(title): title
        case .text: line.text.trimmingCharacters(in: .whitespaces)
        }
    }

    static func clock(_ seconds: Double) -> String {
        let value = seconds.isFinite ? Int(seconds) : 0
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}
