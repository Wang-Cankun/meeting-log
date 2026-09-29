import SwiftUI

/// One destination control for the recording panel and import window.
struct ProjectChooser: View {
    /// `field` is a compact bordered button for forms; `card` is the panel's full-width card with a folder icon.
    enum Style { case field, card }

    let projects: [ProjectFolder]
    @Binding var selection: String
    var refresh: () -> Void = {}
    var style: Style = .field
    @State private var presented = false
    @State private var query = ""
    @State private var collapsed: Set<String> = []
    @State private var highlighted: String?
    @FocusState private var searchFocused: Bool

    private var selected: ProjectFolder? { projects.first { $0.name == selection } }
    private var missing: Bool { selection != ArchiveStore.inboxName && selected == nil }
    private struct Row: Identifiable {
        let id: String
        let project: ProjectFolder?
        let title: String
        let depth: Int
        let group: Bool
    }
    private var rows: [Row] {
        let visible = projects.filter { $0.name != ArchiveStore.inboxName }
        if !query.isEmpty {
            return ([Row(id: "Inbox", project: nil, title: "Inbox", depth: 0, group: false)]
                + visible.map { Row(id: $0.name, project: $0, title: MeetingLibrary.displayName($0.displayName), depth: 0, group: false) })
                .filter { row in
                    let path = row.project?.displayPath ?? row.title
                    return path.localizedStandardContains(query) || MeetingLibrary.displayName(path).localizedStandardContains(query)
                }
        }
        var result = [Row(id: "Inbox", project: nil, title: "Inbox", depth: 0, group: false)]
        func children(of parent: ProjectFolder?, depth: Int) {
            for project in visible {
                let ancestors = visible.filter { project.name.hasPrefix($0.name + "/") }
                let nearest = ancestors.max { $0.name.count < $1.name.count }
                guard nearest?.name == parent?.name else { continue }
                let group = visible.contains { $0.name.hasPrefix(project.name + "/") }
                result.append(Row(id: group ? "group:" + project.name : project.name,
                                  project: project, title: MeetingLibrary.displayName(project.displayName), depth: depth, group: group))
                if group, !collapsed.contains(project.name) {
                    result.append(Row(id: project.name, project: project, title: "General meetings", depth: depth + 1, group: false))
                    children(of: project, depth: depth + 1)
                }
            }
        }
        children(of: nil, depth: 0)
        return result
    }
    private var previewPath: String {
        let row = rows.first { $0.id == highlighted }
        return (row?.project?.name ?? (row == nil ? selection : "Inbox")) + "/meetings"
    }
    private var title: String {
        selected.map { MeetingLibrary.displayName($0.displayName) } ?? (missing ? "Choose a new location" : "Inbox")
    }
    private var caption: String? {
        if missing { return selection }
        guard let parent = selected?.parentDisplay, !parent.isEmpty else { return nil }
        return MeetingLibrary.displayName(parent)
    }

    var body: some View {
        Group {
            switch style {
            case .field:
                Button(action: open) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).foregroundStyle(missing ? Color.orange : Color.primary)
                            if let caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
                        }.multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 2)
                        Image(systemName: missing ? "exclamationmark.folder" : "chevron.up.chevron.down").font(.caption)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered).controlSize(.small)
            case .card:
                Button(action: open) {
                    HStack(spacing: 10) {
                        Image(systemName: missing ? "exclamationmark.folder" : "folder")
                            .font(.system(size: 15))
                            .foregroundStyle(missing ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tint))
                            .frame(width: 20)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title)
                                .font(.body.weight(.medium))
                                .foregroundStyle(missing ? Color.orange : Color.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if let caption {
                                Text(caption)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(ProjectCardStyle())
                .focusEffectDisabled()
                .help(selected.map { MeetingLibrary.displayName($0.displayPath) } ?? selection)
            }
        }
        .accessibilityLabel("Save meeting to \(selected.map { MeetingLibrary.displayName($0.displayPath) } ?? selection)")
        .popover(isPresented: $presented, arrowEdge: .bottom) { panel }
    }

    private func open() {
        refresh(); query = ""; highlighted = nil; presented = true
    }

    var panel: some View {
            VStack(alignment: .leading, spacing: 0) {
                TextField("Search projects", text: $query)
                    .textFieldStyle(.roundedBorder).focused($searchFocused)
                    .padding(12).onChange(of: query) { _, _ in highlighted = rows.first?.id }
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(rows) { row in
                                Button { activate(row) } label: {
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: row.group ? (collapsed.contains(row.project!.name) ? "chevron.right" : "chevron.down") : (selection == row.id ? "checkmark" : "folder"))
                                            .font(.system(size: 12)).frame(width: 16).padding(.top, 2)
                                            .foregroundStyle(selection == row.id ? Color.accentColor : Color.secondary)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(row.title).fontWeight(row.group ? .semibold : .regular)
                                            if !query.isEmpty, let parent = row.project?.parentDisplay, !parent.isEmpty {
                                                Text(parent).font(.caption).foregroundStyle(.secondary)
                                            }
                                        }.fixedSize(horizontal: false, vertical: true)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.leading, CGFloat(min(row.depth, 3)) * 16).padding(8)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(ProjectRowStyle(highlighted: highlighted == row.id))
                                .id(row.id)
                                .accessibilityLabel(row.group ? "\(row.title), project group" : (row.project?.displayPath ?? row.title))
                            }
                            if rows.isEmpty { Text("No matching projects").foregroundStyle(.secondary).padding(16) }
                        }.padding(6)
                    }
                    .frame(height: min(320, max(100, CGFloat(rows.count) * 42)))
                    .onChange(of: highlighted) { _, value in if let value { proxy.scrollTo(value) } }
                }
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Save location").font(.caption).foregroundStyle(.secondary)
                    Text(previewPath.replacingOccurrences(of: "/", with: " / "))
                        .font(.caption).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }.padding(12)
            }.frame(width: 350)
                .onAppear { searchFocused = true }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.return) {
                    if let row = rows.first(where: { $0.id == highlighted }) { activate(row) }
                    return .handled
                }
                .onKeyPress(.escape) { presented = false; return .handled }
    }

    private func move(_ amount: Int) {
        guard !rows.isEmpty else { return }
        let index = highlighted.flatMap { id in rows.firstIndex { $0.id == id } } ?? (amount > 0 ? -1 : rows.count)
        highlighted = rows[min(rows.count - 1, max(0, index + amount))].id
    }
    private func activate(_ row: Row) {
        if row.group, let project = row.project {
            if collapsed.contains(project.name) { collapsed.remove(project.name) } else { collapsed.insert(project.name) }
            highlighted = row.id
        } else { selection = row.id; presented = false }
    }
}

/// The panel's destination card: card fill, hairline border and a pressed tint, with its own focus ring.
private struct ProjectCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CardBody(configuration: configuration)
    }

    private struct CardBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .padding(.leading, 12)
                .padding(.trailing, 12)
                .padding(.vertical, 8)
                .frame(minHeight: 46)
                .background(RoundedRectangle(cornerRadius: 10).fill(PanelColors.card))
                .overlay(RoundedRectangle(cornerRadius: 10).fill(configuration.isPressed ? PanelColors.hover : .clear))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PanelColors.border))
                .overlay {
                    if isFocused {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 2)
                    }
                }
                .opacity(isEnabled ? 1 : 0.6)
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct ProjectRowStyle: ButtonStyle {
    let highlighted: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.accentColor.opacity(0.2) : (highlighted ? Color.accentColor.opacity(0.1) : .clear), in: RoundedRectangle(cornerRadius: 5))
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
    }
}
