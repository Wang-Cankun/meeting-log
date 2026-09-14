import SwiftUI

/// One destination control for the recording panel and import window.
struct ProjectChooser: View {
    let projects: [ProjectFolder]
    @Binding var selection: String
    var refresh: () -> Void = {}
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
                + visible.map { Row(id: $0.name, project: $0, title: $0.displayName, depth: 0, group: false) })
                .filter { ($0.project?.displayPath ?? $0.title).localizedStandardContains(query) }
        }
        var result = [Row(id: "Inbox", project: nil, title: "Inbox", depth: 0, group: false)]
        func children(of parent: ProjectFolder?, depth: Int) {
            for project in visible {
                let ancestors = visible.filter { project.name.hasPrefix($0.name + "/") }
                let nearest = ancestors.max { $0.name.count < $1.name.count }
                guard nearest?.name == parent?.name else { continue }
                let group = visible.contains { $0.name.hasPrefix(project.name + "/") }
                result.append(Row(id: group ? "group:" + project.name : project.name,
                                  project: project, title: project.displayName, depth: depth, group: group))
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
    var body: some View {
        Button {
            refresh(); query = ""; highlighted = nil; presented = true
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selected?.displayName ?? (missing ? "Choose a new location" : "Inbox"))
                        .foregroundStyle(missing ? Color.orange : Color.primary)
                    if let parent = selected?.parentDisplay, !parent.isEmpty {
                        Text(parent).font(.caption).foregroundStyle(.secondary)
                    }
                    if missing { Text(selection).font(.caption).foregroundStyle(.secondary) }
                }.multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 2)
                Image(systemName: missing ? "exclamationmark.folder" : "chevron.up.chevron.down").font(.caption)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered).controlSize(.small)
        .accessibilityLabel("Save meeting to \(selected?.displayPath ?? selection)")
        .popover(isPresented: $presented, arrowEdge: .bottom) { panel }
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

private struct ProjectRowStyle: ButtonStyle {
    let highlighted: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.accentColor.opacity(0.2) : (highlighted ? Color.accentColor.opacity(0.1) : .clear), in: RoundedRectangle(cornerRadius: 5))
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
    }
}
