import AppKit
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

/// An action at the top of the switcher, found by the same search.
enum WorkspaceSwitcherAction: CaseIterable, Identifiable {
    case importRepository, manager

    var id: Self { self }

    var title: String {
        switch self {
        case .importRepository: "Import Repository..."
        case .manager: "Workspace Manager..."
        }
    }

    var symbol: String {
        switch self {
        case .importRepository: "square.and.arrow.down"
        case .manager: "square.grid.2x2"
        }
    }

    var shortcut: String? {
        switch self {
        case .importRepository: nil
        case .manager: "⌘N"
        }
    }

    /// Every token of the query appears in the title.
    static func matching(_ query: String) -> [WorkspaceSwitcherAction] {
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return allCases.filter { action in tokens.allSatisfy { action.title.lowercased().contains($0) } }
    }
}

/// The workspace switcher under the title, laid out like JetBrains' project
/// and branch popups: search, actions with their shortcuts, then recent
/// workspaces with their branch and where they are open. Keyboard: arrows
/// move through actions and workspaces, Return opens, Command-Return opens a
/// workspace in a new window, Escape closes.
struct WorkspaceSwitcherView: View {
    let desktop: DesktopCoordinator
    let currentWorkspaceID: UUID
    let windowID: UUID
    let close: () -> Void
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var searchFocused: Bool

    private enum Entry: Identifiable {
        case action(WorkspaceSwitcherAction)
        case workspace(WorkspaceSwitcherItem)

        var id: String {
            switch self {
            case .action(let action): "action-\(action)"
            case .workspace(let item): item.id.uuidString
            }
        }
    }

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
        let actions = WorkspaceSwitcherAction.matching(query)
        let rows = items
        let entries = actions.map(Entry.action) + rows.map(Entry.workspace)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(RunnirTheme.secondaryForeground)
                TextField("Search workspaces and actions", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .focused($searchFocused)
                    .onSubmit { activate(entries, newWindow: false) }
                    .onKeyPress(.downArrow) { move(1, count: entries.count); return .handled }
                    .onKeyPress(.upArrow) { move(-1, count: entries.count); return .handled }
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        activate(entries, newWindow: true)
                        return .handled
                    }
            }
            .padding(.horizontal, 8).frame(height: 30)
            .background(RunnirTheme.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(RunnirTheme.primary.opacity(0.6)))
            .padding(10)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                            actionRow(action, selected: index == selection)
                                .id(Entry.action(action).id)
                                .clickable().onTapGesture { selection = index; activate(entries, newWindow: false) }
                        }
                        if !actions.isEmpty && !rows.isEmpty {
                            DesignDivider().padding(.vertical, 5).padding(.horizontal, 4)
                        }
                        if !rows.isEmpty {
                            Text("Recent").font(.system(size: 11, weight: .medium)).foregroundStyle(RunnirTheme.mutedForeground)
                                .padding(.horizontal, 10).padding(.top, 2).padding(.bottom, 3)
                        }
                        ForEach(Array(rows.enumerated()), id: \.element.id) { offset, item in
                            let index = actions.count + offset
                            row(item, selected: index == selection)
                                .id(item.id.uuidString)
                                .clickable().onTapGesture { selection = index; activate(entries, newWindow: false) }
                                .contextMenu {
                                    Button("Open in New Window") { close(); desktop.openRegistered(item.workspace) }
                                    Button("Show in Finder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.workspace.path)])
                                    }
                                }
                        }
                        if entries.isEmpty {
                            Text("Nothing matches \"\(query)\".").font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                                .frame(maxWidth: .infinity, minHeight: 60)
                        } else if rows.isEmpty && query.isEmpty {
                            Text("No workspaces yet. Import a repository to start.").font(.system(size: 12))
                                .foregroundStyle(RunnirTheme.secondaryForeground).padding(10)
                        }
                    }
                    .padding(.horizontal, 6).padding(.bottom, 6)
                }
                .frame(maxHeight: 420)
                .onChange(of: selection) { _, value in
                    if entries.indices.contains(value) { proxy.scrollTo(entries[value].id) }
                }
            }
            DesignDivider()
            Text("↩ open   ⌘↩ new window   esc close")
                .font(.system(size: 11)).foregroundStyle(RunnirTheme.mutedForeground)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).frame(height: 28)
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .background(RunnirTheme.surface)
        .foregroundStyle(RunnirTheme.foreground)
        .onAppear {
            searchFocused = true
            // Return goes to the most recent other workspace, as before.
            selection = rows.isEmpty ? 0 : actions.count
        }
        .onChange(of: query) { _, _ in selection = 0 }
        .onExitCommand { close() }
    }

    private func actionRow(_ action: WorkspaceSwitcherAction, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: action.symbol).frame(width: 18).foregroundStyle(RunnirTheme.secondaryForeground)
            Text(action.title).font(.system(size: 13))
            Spacer(minLength: 8)
            if let shortcut = action.shortcut {
                Text(shortcut).font(.system(size: 12)).foregroundStyle(RunnirTheme.mutedForeground)
            }
        }
        .padding(.horizontal, 8).frame(height: 28)
        .clickable()
        .background(selected ? RunnirTheme.primary.opacity(0.28) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func row(_ item: WorkspaceSwitcherItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            WorkspaceBadge(name: item.workspace.name, id: item.workspace.id, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Text(item.workspace.name).font(.system(size: 13, weight: item.isCurrent ? .semibold : .regular)).lineLimit(1)
                    if let branch = item.branch {
                        Label(branch, systemImage: "arrow.triangle.branch").labelStyle(.titleAndIcon)
                            .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground).lineLimit(1)
                    }
                }
                Text(item.githubRepository.map { "\($0) · \(item.displayPath)" } ?? item.displayPath)
                    .font(.system(size: 11)).foregroundStyle(RunnirTheme.mutedForeground)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if item.isCurrent {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(RunnirTheme.primary)
                    .help("This window")
            } else if item.openWindows > 0 {
                Text(item.openWindows == 1 ? "Open" : "Open in \(item.openWindows)")
                    .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
            }
        }
        .padding(.horizontal, 8).frame(height: 38)
        .clickable()
        .background(selected ? RunnirTheme.primary.opacity(0.28) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        selection = min(max(selection + delta, 0), count - 1)
    }

    /// An action runs. A workspace: Return focuses it where it is already
    /// open, otherwise shows it in this window; Command-Return always opens a
    /// new window.
    private func activate(_ entries: [Entry], newWindow: Bool) {
        guard entries.indices.contains(selection) else { return }
        close()
        switch entries[selection] {
        case .action(.importRepository):
            desktop.importRepository()
        case .action(.manager):
            desktop.showManager()
        case .workspace(let item):
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
}
