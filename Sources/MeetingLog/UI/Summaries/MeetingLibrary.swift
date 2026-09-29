import Foundation

/// What the sidebar selects. A project scope lists the project and its sub-projects; `own` lists only meetings
/// saved directly in a parent project, shown as its General meetings row as in the project chooser.
enum LibraryScope: Hashable {
    case all
    case project(String)
    case own(String)

    var projectName: String? {
        switch self {
        case .all: nil
        case let .project(name), let .own(name): name
        }
    }

    func contains(projectName meetingProject: String) -> Bool {
        switch self {
        case .all: true
        case let .project(name): meetingProject == name || meetingProject.hasPrefix(name + "/")
        case let .own(name): meetingProject == name
        }
    }
}

struct ProjectNode: Identifiable, Equatable {
    var id: String { name }
    let name: String
    var children: [ProjectNode] = []
    var displayName: String { MeetingLibrary.displayName(name.split(separator: "/").last.map(String.init) ?? name) }

    /// Own meetings plus every descendant's.
    func total(_ counts: [String: Int]) -> Int {
        counts[name, default: 0] + children.reduce(0) { $0 + $1.total(counts) }
    }
}

enum MeetingLibrary {
    /// Nests projects under their nearest project ancestor, like `ProjectChooser`. Inbox is listed separately.
    static func tree(_ names: [String]) -> [ProjectNode] {
        let visible = names.filter { $0.localizedCaseInsensitiveCompare(ArchiveStore.inboxName) != .orderedSame }
        func parent(of name: String) -> String? {
            visible.filter { name.hasPrefix($0 + "/") }.max { $0.count < $1.count }
        }
        func children(of name: String?) -> [ProjectNode] {
            visible.filter { parent(of: $0) == name }.map { ProjectNode(name: $0, children: children(of: $0)) }
        }
        return children(of: nil)
    }

    /// Readable project path such as `Lab › Atlas`, built from the project name rather than a meeting folder.
    static func projectPath(_ name: String) -> String {
        displayName(ProjectFolder(name: name, url: URL(filePath: name)).displayPath)
    }

    /// Folder names often use underscores for spaces; the window shows spaces without renaming anything.
    static func displayName(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ")
    }

    static func counts(_ meetings: [ArchivedMeeting]) -> [String: Int] {
        meetings.reduce(into: [:]) { $0[$1.projectName, default: 0] += 1 }
    }

    /// Every whitespace-separated term must appear in at least one field; case and diacritics are ignored.
    static func matches(_ query: String, fields: [String]) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        return terms.allSatisfy { term in fields.contains { $0.localizedStandardContains(term) } }
    }

    enum DateBucket: Equatable {
        case today, yesterday, thisWeek
        case earlierThisMonth(String)
        case month(String)

        var title: String {
            switch self {
            case .today: "Today"
            case .yesterday: "Yesterday"
            case .thisWeek: "This week"
            case let .earlierThisMonth(month): "Earlier in \(month)"
            case let .month(title): title
            }
        }
    }

    static func bucket(for date: Date, now: Date, calendar: Calendar = .current,
                       locale: Locale = Locale(identifier: "en_US")) -> DateBucket {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return .yesterday
        }
        func month(_ format: String) -> String {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = locale
            formatter.dateFormat = format
            return formatter.string(from: date)
        }
        if date < now {
            if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return .thisWeek }
            if calendar.isDate(date, equalTo: now, toGranularity: .month) { return .earlierThisMonth(month("LLLL")) }
        }
        return .month(month("LLLL yyyy"))
    }

    /// Groups newest-first meetings into date sections, preserving their order.
    static func sections(_ meetings: [ArchivedMeeting], now: Date, calendar: Calendar = .current,
                         locale: Locale = Locale(identifier: "en_US")) -> [(title: String, meetings: [ArchivedMeeting])] {
        var result: [(title: String, meetings: [ArchivedMeeting])] = []
        for meeting in meetings {
            let title = bucket(for: meeting.date, now: now, calendar: calendar, locale: locale).title
            if let index = result.firstIndex(where: { $0.title == title }) { result[index].meetings.append(meeting) }
            else { result.append((title, [meeting])) }
        }
        return result
    }

    /// Row date text: the time for today and yesterday, weekday and time this week, otherwise the day.
    static func rowDate(start: Date, hasTime: Bool, now: Date, calendar: Calendar = .current,
                        locale: Locale = Locale(identifier: "en_US")) -> String? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        switch bucket(for: start, now: now, calendar: calendar, locale: locale) {
        case .today, .yesterday:
            guard hasTime else { return nil }
            formatter.dateFormat = "HH:mm"
        case .thisWeek:
            formatter.dateFormat = hasTime ? "EEE HH:mm" : "EEEE"
        case .earlierThisMonth, .month:
            formatter.dateFormat = calendar.isDate(start, equalTo: now, toGranularity: .year) ? "MMM d" : "MMM d, yyyy"
        }
        return formatter.string(from: start)
    }

    static func duration(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        guard seconds >= 60 else { return "<1 min" }
        let minutes = Int((seconds / 60).rounded())
        guard minutes >= 60 else { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }
}
