import Foundation

/// Structured summary parsing for the Meeting summaries window: current, legacy and Chinese formats,
/// evidence references, snippets, date sections, speakers and the project tree.
func checkSummaryDocument() {
    checkCurrentSummaryFormat()
    checkLegacySummaryFormats()
    checkChineseSummaryHeadings()
    checkEvidenceReferences()
    checkDateSections()
    checkTranscriptDocument()
    checkLibraryTreeAndSearch()
    print("Summary document passed: current, legacy and Chinese formats, references, snippets, dates, speakers, projects")
}

private func checkCurrentSummaryFormat() {
    let analysis = MeetingAnalysis(
        title: "Batch correction plan", projectName: "Lab/projects/Atlas",
        summary: ["Compare **Harmony** and scVI on the pilot (L18, L20).", "Second point."],
        actionItems: [
            ActionItem(assignee: "", task: "Send kBET scores", deadline: "Friday", context: "Needed before the full run.",
                       evidence: [EvidenceReference(line: 42, quote: "I'll send kBET", verified: true),
                                  EvidenceReference(line: 57, quote: "maybe", verified: false)]),
            ActionItem(assignee: "Speaker B", task: "Share QC thresholds", deadline: "", context: "", evidence: nil),
        ],
        decisions: [MeetingDecision(decision: "Keep the reference", reasoning: "Switching would invalidate the pilot.",
                                    evidence: [EvidenceReference(line: 31, quote: "keep it", verified: true)])],
        keyTopics: ["Batch correction", "QC"],
        uncertainties: ["A deadline was implied but not confirmed L44 [unverified reference]."],
        milestones: [EvidenceNote(text: "Full run next week", evidence: [EvidenceReference(line: 45, quote: "next week", verified: true)])])
    let markdown = MarkdownRenderer.summary(analysis, startedAt: Date(timeIntervalSince1970: 0), evidenceSource: .raw)
    let document = SummaryDocument.parse(markdown)
    precondition(document.title == "Batch correction plan" && document.project == "Lab/projects/Atlas", "\(document)")
    precondition(document.date?.count == 16 && SummaryDocument.startDate(document.date) != nil)
    precondition(document.evidence?.hasPrefix("transcript_raw.md") == true)
    precondition(document.sections.map(\.kind) == [.summary, .actionItems, .decisions, .milestones, .keyTopics, .needsVerification],
                 "\(document.sections.map(\.kind))")
    guard case let .actions(cards) = document.sections[1].body else { preconditionFailure("\(document.sections[1])") }
    precondition(cards.count == 2)
    precondition(cards[0] == ActionCard(task: "Send kBET scores", hasFields: true, owner: nil, deadline: "Friday",
                                        notes: ["Needed before the full run."],
                                        evidence: [EvidenceMark(line: 42, verified: true, quote: "I'll send kBET"),
                                                   EvidenceMark(line: 57, verified: false, quote: "maybe")]), "\(cards[0])")
    precondition(cards[1].owner == "Speaker B" && cards[1].deadline == nil && cards[1].hasFields && cards[1].evidence.isEmpty)
    guard case let .items(decisions) = document.sections[2].body else { preconditionFailure("\(document.sections[2])") }
    precondition(decisions == [SummaryItem(text: "Keep the reference", notes: ["Switching would invalidate the pilot."],
                                           evidence: [EvidenceMark(line: 31, verified: true, quote: "keep it")])])
    guard case let .items(milestones) = document.sections[3].body else { preconditionFailure() }
    precondition(milestones[0].evidence.map(\.line) == [45] && milestones[0].notes.isEmpty)
    precondition(document.snippet == "Compare Harmony and scVI on the pilot.", "\(document.snippet ?? "nil")")
    let references = SummaryInline.references(inMarkdown: markdown)
    precondition(references.map(\.line) == [18, 20, 42, 57, 31, 45, 44], "\(references)")
    precondition(references.first { $0.line == 57 }?.verified == false)

    // Empty sections and hand edits the typed forms cannot hold stay as Markdown blocks.
    let edited = SummaryDocument.parse("# T\n\nIntro line.\n\n## Decisions\n\nNone.\n\n## Notes\n\n- Outer\n  - Inner\n")
    precondition(edited.sections.map(\.kind) == [.other, .decisions, .other])
    precondition(edited.sections[0].heading == nil && edited.sections[0].body == .blocks([.paragraph("Intro line.")]))
    precondition(edited.sections[1].body == .blocks([.paragraph("None.")]))
    precondition(edited.sections[2].body == .blocks([.bullet(marker: "•", text: "Outer", depth: 0),
                                                     .bullet(marker: "•", text: "Inner", depth: 1)]))
    precondition(SummaryDocument.parse("# Custom title\n\nOld handwritten summary.\n").snippet == "Old handwritten summary.")
}

private func checkLegacySummaryFormats() {
    let table = SummaryDocument.parse("""
    # Legacy

    - Date: 2026-09-14 14:36
    - Project: Inbox

    ## Summary

    - First point.

    ## Action items
    | Task | Owner | Deadline | Context / evidence |
    | --- | --- | --- | --- |
    | Send the link | Madison | — | Following up.<br>L39: “I'll send you the link.”; L41 [unverified reference]: “soon” |
    | Draft MOUs | — | by Tuesday | — |
    """)
    guard case let .actions(cards) = table.sections[1].body else { preconditionFailure("\(table.sections)") }
    precondition(cards[0] == ActionCard(task: "Send the link", hasFields: true, owner: "Madison", deadline: nil,
                                        notes: ["Following up."],
                                        evidence: [EvidenceMark(line: 39, verified: true, quote: "I'll send you the link."),
                                                   EvidenceMark(line: 41, verified: false, quote: "soon")]), "\(cards[0])")
    precondition(cards[1] == ActionCard(task: "Draft MOUs", hasFields: true, owner: nil, deadline: "by Tuesday"))

    let oneLine = SummaryDocument.parse("# Old\n\n## Action items\n- Crop the TMA cores (Needed for figures.)\n")
    guard case let .actions(simple) = oneLine.sections[0].body else { preconditionFailure() }
    precondition(simple == [ActionCard(task: "Crop the TMA cores (Needed for figures.)")])

    // A table without owner or deadline columns is not an action list; it stays a table.
    let other = SummaryDocument.parse("## Action items\n| A | B |\n| --- | --- |\n| 1 | 2 |\n")
    precondition(other.sections[0].body == .blocks([.table(header: ["A", "B"], rows: [["1", "2"]])]))
}

private func checkChineseSummaryHeadings() {
    let chinese = SummaryDocument.parse("""
    # 批次校正计划

    - Date: 2026-09-29 14:05
    - Project: Lab
    - Evidence: transcript_raw.md (original transcription; L numbers refer to this file)

    ## 概述

    - 团队将比较两种方法（L18）。

    ## 待办事项

    - 发送 kBET 结果
      负责人：Ling Cai · 截止日期：—
      全量运行前需要。
      证据：L42: “I'll send kBET”; L57 [unverified reference]: “maybe”

    ## 已决事项

    - 保留当前参考注释
      中途切换会使对比失效。
      依据: L31: “keep it”

    ## 悬而未决的问题

    - 是否纳入 2024 批次
      证据: L46: “Should the 2024 batches go in?”

    ## 暂缓工作

    - 可视化
      证据: L50: “later”

    ## 基础设施与文档

    - BioHPC 共享目录
      证据: L60: “shared folder”

    ## 核心议题

    - 批次校正

    ## 待核实事项

    - QC 截止日期 [待确认]

    ## 录音恢复说明

    仅恢复了系统音频。
    """)
    precondition(chinese.title == "批次校正计划" && chinese.date == "2026-09-29 14:05")
    precondition(chinese.sections.map(\.kind) == [.summary, .actionItems, .decisions, .openQuestions, .deferredWork,
                                                   .inventory, .keyTopics, .needsVerification, .other],
                 "\(chinese.sections.map(\.kind))")
    guard case let .actions(cards) = chinese.sections[1].body else { preconditionFailure("\(chinese.sections[1])") }
    precondition(cards == [ActionCard(task: "发送 kBET 结果", hasFields: true, owner: "Ling Cai", deadline: nil,
                                      notes: ["全量运行前需要。"],
                                      evidence: [EvidenceMark(line: 42, verified: true, quote: "I'll send kBET"),
                                                 EvidenceMark(line: 57, verified: false, quote: "maybe")])], "\(cards)")
    guard case let .items(decisions) = chinese.sections[2].body else { preconditionFailure() }
    precondition(decisions[0].notes == ["中途切换会使对比失效。"] && decisions[0].evidence.map(\.line) == [31])
    precondition(chinese.snippet == "团队将比较两种方法。", "\(chinese.snippet ?? "nil")")
    for (heading, kind) in [("总结", SummarySection.Kind.summary), ("行动项", .actionItems), ("决定", .decisions),
                            ("决策", .decisions), ("里程碑", .milestones), ("待确定问题", .openQuestions),
                            ("待解决问题", .openQuestions), ("延后事项", .deferredWork), ("推迟的工作", .deferredWork),
                            ("关键议题", .keyTopics), ("待确认事项", .needsVerification), ("待核实信息", .needsVerification),
                            ("待验证事项", .needsVerification), ("Infrastructure and documents", .inventory),
                            ("Recording recovery", .other)] {
        precondition(SummarySection.kind(for: heading) == kind, heading)
    }
}

private func checkEvidenceReferences() {
    let runs = SummaryInline.runs("Implied L44 [unverified reference] and L45 [needs verification]; “HLA2 L3” quoted.")
    precondition(runs == [.text("Implied "), .reference(EvidenceMark(line: 44, verified: false)), .text(" and "),
                          .reference(EvidenceMark(line: 45)), .text(" [needs verification]; “HLA2 L3” quoted.")], "\(runs)")
    precondition(SummaryInline.runs("[L12](x) and URL1") == [.text("[L12](x) and URL1")])
    precondition(SummaryInline.runs("证据 L7 [未验证引用]") == [.text("证据 "), .reference(EvidenceMark(line: 7, verified: false))])
    precondition(SummaryInline.evidenceList("Evidence: L12: “a”; see notes") == nil, "Trailing prose must stay visible")
    precondition(SummaryInline.evidenceList("Owner: Me · Deadline: —") == nil)
    precondition(SummaryInline.evidenceList("L3, L4") == [EvidenceMark(line: 3), EvidenceMark(line: 4)])
    precondition(SummaryInline.plain("Run [the pilot](https://x) first L3 [unverified reference] (L4; L5).") == "Run the pilot first.",
                 SummaryInline.plain("Run [the pilot](https://x) first L3 [unverified reference] (L4; L5)."))
    // Inline needs-verification markers become one mark attached to the preceding word, in either language,
    // and leave snippets; evidence status brackets stay with their reference.
    let mark = String(SummaryInline.verificationMark)
    precondition(SummaryInline.markingVerification("Fangjiang [needs verification]（Fangda [Needs Verification]）接手")
                 == "Fangjiang\(mark)（Fangda\(mark)）接手")
    precondition(SummaryInline.markingVerification("由Chenghu [待核实]接手，L3 [unverified reference]")
                 == "由Chenghu\(mark)接手，L3 [unverified reference]")
    precondition(SummaryInline.markingVerification("[uncertain: heard wording] stays") == "[uncertain: heard wording] stays")
    precondition(SummaryInline.plain("Yajing [needs verification] presented L4.") == "Yajing presented.",
                 SummaryInline.plain("Yajing [needs verification] presented L4."))
    precondition(SummaryDocument.ownerAndDeadline("Owner: Me · Deadline: Fri, Oct 2")! == ("Me", "Fri, Oct 2"))
    precondition(SummaryDocument.ownerAndDeadline("Location: BDSC · Role: archive") == nil)
    precondition(SummaryDocument.ownerAndDeadline("Due to the holiday: send it early") == nil, "Prose must not become a deadline")
    precondition(SummaryDocument.ownerAndDeadline("**Owners**: Me · Due date: —")! == ("Me", nil))
    precondition(SummaryDocument.ownerAndDeadline("负责人：Ling Cai · 截止时间：周五")! == ("Ling Cai", "周五"))
    let prose = SummaryDocument.parse("## Action items\n\n- Send slides\n  Due to the holiday: send it early\n")
    precondition(prose.sections[0].body == .actions([ActionCard(task: "Send slides", notes: ["Due to the holiday: send it early"])]),
                 "\(prose.sections)")
}

private func checkDateSections() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 1
    func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }
    let now = date("2026-09-29 10:00") // Tuesday; the week starts on Sunday the 27th.
    func title(_ text: String, now: Date = now) -> String {
        MeetingLibrary.bucket(for: date(text), now: now, calendar: calendar).title
    }
    precondition(title("2026-09-29 00:00") == "Today")
    precondition(title("2026-09-28 23:59") == "Yesterday")
    precondition(title("2026-09-27 00:00") == "This week")
    precondition(title("2026-09-26 23:59") == "Earlier in September")
    precondition(title("2026-09-01 00:00") == "Earlier in September")
    precondition(title("2026-08-31 23:59") == "August 2026")
    precondition(title("2025-09-29 10:00") == "September 2025")
    let newYear = date("2027-01-01 09:00")
    precondition(title("2026-12-31 12:00", now: newYear) == "Yesterday")
    precondition(title("2026-12-28 12:00", now: newYear) == "This week", "A week spanning the new year stays this week")
    precondition(title("2026-12-26 12:00", now: newYear) == "December 2026")
    let meetings = ["2026-09-29 00:00", "2026-09-27 00:00", "2026-09-18 00:00", "2026-09-03 00:00", "2026-08-20 00:00"].map {
        ArchivedMeeting(title: $0, projectName: "Inbox", dateText: "", date: date($0), createdAt: date($0), url: URL(filePath: "/\($0)"))
    }
    let sections = MeetingLibrary.sections(meetings, now: now, calendar: calendar)
    precondition(sections.map(\.title) == ["Today", "This week", "Earlier in September", "August 2026"])
    precondition(sections[2].meetings.count == 2)
    precondition(MeetingLibrary.rowDate(start: date("2026-09-29 14:05"), hasTime: true, now: now, calendar: calendar) == "14:05")
    precondition(MeetingLibrary.rowDate(start: date("2026-09-29 00:00"), hasTime: false, now: now, calendar: calendar) == nil)
    precondition(MeetingLibrary.rowDate(start: date("2026-09-27 11:00"), hasTime: true, now: now, calendar: calendar) == "Sun 11:00")
    precondition(MeetingLibrary.rowDate(start: date("2026-09-18 11:00"), hasTime: true, now: now, calendar: calendar) == "Sep 18")
    precondition(MeetingLibrary.rowDate(start: date("2025-09-18 11:00"), hasTime: true, now: now, calendar: calendar) == "Sep 18, 2025")
    precondition(MeetingLibrary.duration(42 * 60 + 17) == "42 min")
    precondition(MeetingLibrary.duration(3900) == "1 h 5 min" && MeetingLibrary.duration(7200) == "2 h")
    precondition(MeetingLibrary.duration(30) == "<1 min" && MeetingLibrary.duration(0) == nil && MeetingLibrary.duration(.nan) == nil)
}

private func checkTranscriptDocument() {
    let text = [
        "# Transcript",                         // L1
        "",
        "Turns labeled Me come from the microphone.", // L3
        "",
        "## 00:00–10:00",                       // L5
        "",
        "[00:05] Speaker 27: Hello there.",     // L7
        "",
        "[00:09] Me: Hi.",                      // L9
        "",
        "continuation line",                    // L11
        "",
        "[00:15] Speaker A: Next: a colon.",    // L13
        "",
        "## Recording 2: file.m4a",             // L15
        "",
        "[61:02] Speaker 27: Again.",           // L17
    ].joined(separator: "\n")
    let document = TranscriptDocument(text)
    precondition(document.speakers == ["Me", "Speaker 27", "Speaker A"], "\(document.speakers)")
    precondition(document.rank(of: "Speaker 27") == 0 && document.rank(of: "Speaker A") == 1 && document.rank(of: "Me") == nil)
    precondition(document.line(7)?.kind == .turn(speaker: "Speaker 27", stamp: "00:05", text: "Hello there."))
    precondition(document.line(13)?.kind == .turn(speaker: "Speaker A", stamp: "00:15", text: "Next: a colon."))
    precondition(document.line(5)?.kind == .heading("00:00–10:00") && document.line(15)?.kind == .heading("Recording 2: file.m4a"))
    precondition(document.line(3)?.kind == .text && document.line(2) == nil)
    precondition(document.cueSeconds(for: 11) == 9 && document.cueSeconds(for: 12) == 9 && document.cueSeconds(for: 17) == 3662)
    precondition(document.cueSeconds(for: 3) == nil)
    precondition(TranscriptDocument("[00:01] Speaker A: a\n[00:02] Speaker B: b").speakers == ["Speaker A", "Speaker B"])

    let directory = FileManager.default.temporaryDirectory.appending(path: "transcript-source-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try! "readable".write(to: directory.appending(path: "transcript.md"), atomically: true, encoding: .utf8)
    precondition(TranscriptDocument.evidenceSource(in: directory) == .legacy)
    try! "raw".write(to: directory.appending(path: "transcript_raw.md"), atomically: true, encoding: .utf8)
    precondition(TranscriptDocument.evidenceSource(in: directory) == .raw)
}

private func checkLibraryTreeAndSearch() {
    let tree = MeetingLibrary.tree(["Inbox", "Lab", "Lab/projects/Atlas", "Lab/projects/Atlas/Pilot", "Lab/projects/Grant", "Other"])
    precondition(tree.map(\.name) == ["Lab", "Other"])
    precondition(tree[0].children.map(\.displayName) == ["Atlas", "Grant"] && tree[0].children[0].children.map(\.name) == ["Lab/projects/Atlas/Pilot"])
    let counts = ["Lab": 2, "Lab/projects/Atlas": 3, "Lab/projects/Atlas/Pilot": 1, "Other": 4]
    precondition(tree[0].total(counts) == 6 && tree[1].total(counts) == 4)
    // A parent scope lists its sub-projects; General meetings lists only its own; names sharing a prefix stay out.
    precondition(LibraryScope.project("Lab").contains(projectName: "Lab/projects/Atlas/Pilot")
                 && LibraryScope.project("Lab").contains(projectName: "Lab")
                 && !LibraryScope.project("Lab").contains(projectName: "Lab2"))
    precondition(LibraryScope.own("Lab").contains(projectName: "Lab") && !LibraryScope.own("Lab").contains(projectName: "Lab/projects/Atlas"))
    precondition(LibraryScope.all.contains(projectName: "Other") && LibraryScope.all.projectName == nil)
    // The breadcrumb names the project, not the meeting folder, and hides structural containers.
    precondition(MeetingLibrary.projectPath("Lab/projects/Atlas") == "Lab › Atlas" && MeetingLibrary.projectPath("Inbox") == "Inbox")
    // Underscores display as spaces everywhere a project is named; the folder name itself is unchanged.
    let underscored = MeetingLibrary.tree(["Ling_Xenium", "Ling_Xenium/projects/Xenium_workflow"])
    precondition(underscored[0].displayName == "Ling Xenium" && underscored[0].children[0].displayName == "Xenium workflow"
                 && underscored[0].children[0].name == "Ling_Xenium/projects/Xenium_workflow")
    precondition(MeetingLibrary.projectPath("Ling_Xenium/projects/Xenium_workflow") == "Ling Xenium › Xenium workflow")
    precondition(MeetingLibrary.matches("atlas 批次", fields: ["Atlas plan", "处理批次"]))
    precondition(!MeetingLibrary.matches("atlas missing", fields: ["Atlas plan"]))
    precondition(MeetingLibrary.matches("  ", fields: []) && MeetingLibrary.matches("etude", fields: ["Étude"]))
}
