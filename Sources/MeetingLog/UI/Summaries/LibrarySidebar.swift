import SwiftUI

/// Library and project tree. Selecting a parent project lists it with its sub-projects; its own meetings are
/// under General meetings, and the parent row shows the total including sub-projects.
struct LibrarySidebar: View {
    @Binding var scope: LibraryScope?
    let tree: [ProjectNode]
    let inboxName: String
    let counts: [String: Int]
    let total: Int
    let newProject: () -> Void
    @State private var collapsed: Set<String> = []

    var body: some View {
        List(selection: $scope) {
            Section("Library") {
                Label("All meetings", systemImage: "tray.full")
                    .badge(total)
                    .tag(LibraryScope.all)
            }
            Section("Projects") {
                Label("Inbox", systemImage: "tray")
                    .badge(counts[inboxName, default: 0])
                    .tag(LibraryScope.project(inboxName))
                ForEach(tree) { ProjectRows(node: $0, counts: counts, collapsed: $collapsed) }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(action: newProject) { Label("New project…", systemImage: "plus") }
                .buttonStyle(.borderless)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Create a project folder in the meeting archive")
        }
    }
}

private struct ProjectRows: View {
    let node: ProjectNode
    let counts: [String: Int]
    @Binding var collapsed: Set<String>

    var body: some View {
        if node.children.isEmpty {
            Label(node.displayName, systemImage: "folder")
                .badge(counts[node.name, default: 0])
                .tag(LibraryScope.project(node.name))
                .help(node.name)
        } else {
            DisclosureGroup(isExpanded: Binding(
                get: { !collapsed.contains(node.name) },
                set: { expanded in
                    if expanded { collapsed.remove(node.name) } else { collapsed.insert(node.name) }
                })) {
                // A parent without meetings of its own has nothing to list under General meetings.
                if counts[node.name, default: 0] > 0 {
                    Label("General meetings", systemImage: "folder")
                        .badge(counts[node.name, default: 0])
                        .tag(LibraryScope.own(node.name))
                        .help(node.name)
                }
                ForEach(node.children) { ProjectRows(node: $0, counts: counts, collapsed: $collapsed) }
            } label: {
                Label(node.displayName, systemImage: "folder")
                    .fontWeight(.medium)
                    .badge(node.total(counts))
                    .tag(LibraryScope.project(node.name))
                    .help("\(node.name), including sub-projects")
            }
        }
    }
}
