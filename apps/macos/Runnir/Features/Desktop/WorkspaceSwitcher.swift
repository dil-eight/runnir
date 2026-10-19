import SwiftUI

/// One row of the workspace switcher.
struct WorkspaceSwitcherItem: Identifiable, Equatable {
    let workspace: WorkspaceRecord
    /// Windows showing this workspace, including the current one.
    let openWindows: Int
    let isCurrent: Bool
    let branch: String?
    let githubRepository: String?

    var id: UUID { workspace.id }
    var displayPath: String { WorkspaceSwitcher.abbreviate(workspace.path) }
}

/// Ordering and search for the switcher, kept free of UI so it can be tested.
enum WorkspaceSwitcher {
    /// Every token of `query` must appear in the name, GitHub repository or
    /// path. Without a query, other workspaces come first by last use and the
    /// current one last. With a query, name matches outrank repository and path
    /// matches, and ties go to the most recently used.
    static func items(workspaces: [WorkspaceRecord],
                      query: String,
                      currentWorkspaceID: UUID?,
                      openWindows: (UUID) -> Int,
                      details: (UUID) -> (branch: String?, githubRepository: String?)) -> [WorkspaceSwitcherItem] {
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let scored: [(item: WorkspaceSwitcherItem, score: Int)] = workspaces.compactMap { workspace in
            let info = details(workspace.id)
            let item = WorkspaceSwitcherItem(
                workspace: workspace,
                openWindows: openWindows(workspace.id),
                isCurrent: workspace.id == currentWorkspaceID,
                branch: info.branch,
                githubRepository: info.githubRepository
            )
            guard let score = score(item, tokens: tokens) else { return nil }
            return (item, score)
        }
        return scored.sorted { lhs, rhs in
            if tokens.isEmpty, lhs.item.isCurrent != rhs.item.isCurrent { return rhs.item.isCurrent }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.item.workspace.lastOpenedAt != rhs.item.workspace.lastOpenedAt {
                return lhs.item.workspace.lastOpenedAt > rhs.item.workspace.lastOpenedAt
            }
            return lhs.item.workspace.name.localizedStandardCompare(rhs.item.workspace.name) == .orderedAscending
        }.map(\.item)
    }

    /// nil when a token matches nothing; higher is better.
    private static func score(_ item: WorkspaceSwitcherItem, tokens: [String]) -> Int? {
        let name = item.workspace.name.lowercased()
        let repository = item.githubRepository?.lowercased() ?? ""
        let path = item.workspace.path.lowercased()
        var total = 0
        for token in tokens {
            if name.hasPrefix(token) { total += 30 }
            else if name.contains(token) { total += 20 }
            else if repository.contains(token) { total += 10 }
            else if path.contains(token) { total += 5 }
            else { return nil }
        }
        return total
    }

    /// "/Users/me/projects/app" becomes "~/projects/app".
    static func abbreviate(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count > 3, parts[0].isEmpty, parts[1] == "Users" else { return path }
        return "~/" + parts.dropFirst(3).joined(separator: "/")
    }
}

/// "Open Quickly" for workspaces: search, keyboard navigation, and where each
/// workspace is already open.
struct WorkspaceSwitcherView: View {
    let desktop: DesktopCoordinator
    let currentWorkspaceID: UUID
    let windowID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var searchFocused: Bool

    private var items: [WorkspaceSwitcherItem] {
        WorkspaceSwitcher.items(
            workspaces: desktop.snapshot.workspaces,
            query: query,
            currentWorkspaceID: currentWorkspaceID,
            openWindows: { desktop.openCount($0) },
            details: { id in
                let session = desktop.core?.session(for: id)
                return (session?.branch.isEmpty == false ? session?.branch : nil, session?.githubRepository)
            }
        )
    }

    var body: some View {
        let rows = items
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(RunnirTheme.secondaryForeground)
                TextField("Search workspaces", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 15))
                    .focused($searchFocused)
                    .onSubmit { open(rows, newWindow: false) }
                    .onKeyPress(.downArrow) { move(1, in: rows); return .handled }
                    .onKeyPress(.upArrow) { move(-1, in: rows); return .handled }
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        open(rows, newWindow: true)
                        return .handled
                    }
            }
            .padding(.horizontal, 16).frame(height: 48)
            Divider()
            if rows.isEmpty {
                Text(desktop.snapshot.workspaces.isEmpty ? "No workspaces yet. Import a repository to start." : "No workspace matches \"\(query)\".")
                    .font(.system(size: 13)).foregroundStyle(RunnirTheme.secondaryForeground)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                                row(item, selected: index == selection)
                                    .id(item.id)
                                    .onTapGesture(count: 2) { selection = index; open(rows, newWindow: false) }
                                    .onTapGesture { selection = index }
                            }
                        }.padding(8)
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: selection) { _, value in
                        if rows.indices.contains(value) { proxy.scrollTo(rows[value].id) }
                    }
                }
            }
            Divider()
            HStack(spacing: 12) {
                Button("Import Repository...") { dismiss(); desktop.importRepository() }
                Button("Workspace Manager...") { dismiss(); desktop.showManager() }
                Spacer()
                Text("↩ open   ⌘↩ new window   esc close")
                    .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
            }
            .buttonStyle(.link).font(.system(size: 12))
            .padding(.horizontal, 16).frame(height: 40)
        }
        .frame(width: 560)
        .background(RunnirTheme.background)
        .foregroundStyle(RunnirTheme.foreground)
        .onAppear { searchFocused = true }
        .onChange(of: query) { _, _ in selection = 0 }
        .onExitCommand { dismiss() }
    }

    private func row(_ item: WorkspaceSwitcherItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox").frame(width: 18)
                .foregroundStyle(selected ? RunnirTheme.primary : RunnirTheme.secondaryForeground)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.workspace.name).font(.system(size: 13, weight: .medium))
                    if let branch = item.branch {
                        Label(branch, systemImage: "arrow.triangle.branch").labelStyle(.titleAndIcon)
                            .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                    }
                }
                Text(item.githubRepository.map { "\($0) · \(item.displayPath)" } ?? item.displayPath)
                    .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if item.isCurrent {
                Text("This window").font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
            } else if item.openWindows > 0 {
                Text(item.openWindows == 1 ? "Open" : "Open in \(item.openWindows) windows")
                    .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
            }
        }
        .padding(.horizontal, 10).frame(height: 46)
        .contentShape(Rectangle())
        .background(selected ? RunnirTheme.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func move(_ delta: Int, in rows: [WorkspaceSwitcherItem]) {
        guard !rows.isEmpty else { return }
        selection = min(max(selection + delta, 0), rows.count - 1)
    }

    /// Return: focus the workspace where it is already open, otherwise show it
    /// in this window. Command-Return: always a new window.
    private func open(_ rows: [WorkspaceSwitcherItem], newWindow: Bool) {
        guard rows.indices.contains(selection) else { return }
        let item = rows[selection]
        dismiss()
        if newWindow {
            desktop.openRegistered(item.workspace)
        } else if item.isCurrent {
            return
        } else if item.openWindows > 0 {
            desktop.focus(item.workspace.id)
        } else {
            desktop.openRegistered(item.workspace, reuseWindowID: windowID)
        }
    }
}
