import SwiftUI

/// The control at the top of the menu bar window and the Pull Requests
/// window: Pull requests | Runs. The Runs segment carries the number of
/// failed runs in a neutral count, in the colour of the control.
struct MenuListTabPicker: View {
    @Binding var tab: MenuListTab
    let failedCount: Int

    var body: some View {
        HStack(spacing: 2) {
            segment(.pullRequests, count: 0)
            segment(.runs, count: failedCount)
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(RunnirTheme.secondary))
        .accessibilityElement(children: .contain)
    }

    private func segment(_ value: MenuListTab, count: Int) -> some View {
        let chosen = tab == value
        return Button { tab = value } label: {
            HStack(spacing: 5) {
                Text(value.segment).font(.system(size: 12, weight: .medium))
                if count > 0 {
                    Text("\(count)").font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(RunnirTheme.foreground.opacity(0.1)))
                }
            }
            .foregroundStyle(chosen ? RunnirTheme.foreground : RunnirTheme.secondaryForeground)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(chosen ? RunnirTheme.background : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.hit)
        .accessibilityLabel(count > 0 ? "\(value.segment), \(count) failed" : value.segment)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// One failed or running run (S19): its status, "Workflow · title" and
/// where and when. Hovering highlights it and says what a click does; a
/// failed one can be removed from the list.
struct WatchedRunRow: View {
    let row: WatchedRun
    /// The server's host, shown when more than one account is signed in.
    var serverHost: String? = nil
    let action: String
    let open: () -> Void
    var dismiss: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.frame(width: 16).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(WatchedRunText.title(row.run)).font(.system(size: 13, weight: .medium)).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    subtitle(now: context.date).font(.system(size: 11)).lineLimit(1)
                }
            }
            if hovering {
                Text(action).font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground).lineLimit(1).padding(.top, 2)
            }
            if let dismiss {
                ListRemoveButton(action: dismiss)
                    .opacity(hovering ? 1 : 0)
                    .padding(.top, -6).padding(.trailing, -6)
                    .help("Remove from this list")
                    .accessibilityLabel("Remove \(WatchedRunText.title(row.run)) from this list")
            }
        }
        .padding(.vertical, 7).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? RunnirTheme.selected : .clear))
        .clickable()
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .help(action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
        .accessibilityActions {
            if let dismiss { Button("Remove from this list", action: dismiss) }
        }
    }

    /// "From Runnir · " in the accent colour before the rest.
    private func subtitle(now: Date) -> Text {
        let rest = Text(WatchedRunText.subtitle(row, host: serverHost, now: now)).foregroundStyle(RunnirTheme.secondaryForeground)
        guard row.run.startedFromRunnir else { return rest }
        return Text(RunPresentation.fromRunnirLabel + " · ").foregroundStyle(RunnirTheme.primary) + rest
    }

    @ViewBuilder private var icon: some View {
        let status = RunStatusFilter.of(row.run) ?? (row.run.status == "completed" ? .failed : .queued)
        if row.run.conclusion == "timed_out" {
            Image(systemName: "clock.badge.xmark").foregroundStyle(RunnirTheme.destructive).accessibilityLabel("Timed out")
        } else {
            Image(systemName: status.symbol).foregroundStyle(status.tint).accessibilityLabel(status.label)
        }
    }
}

/// The Runs tab (S19, B39): the user's failed and running runs across
/// registered workspaces and starred repositories.
struct WatchedRunsList: View {
    let model: WatchedRunsModel
    let desktop: DesktopCoordinator
    var inset: CGFloat = 16
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch PullRequestsListState.of(desktop) {
            case .restoring:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking the saved sign-in...") }
                    .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                    .padding(.horizontal, inset).padding(.vertical, 16)
            case .signedOut:
                PullRequestsSignedOut(desktop: desktop)
            case .lists:
                lists
            }
        }
    }

    @ViewBuilder private var lists: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            if model.unanswered {
                note(WatchedRunText.unanswered(readAt: model.oldestRead), symbol: "exclamationmark.triangle")
            } else if let until = model.pausedUntil {
                note(WatchedRunText.paused(until: until, readAt: model.oldestRead), symbol: "pause.circle")
            } else if model.offline {
                note(WatchedRunText.offline(readAt: model.oldestRead), symbol: "wifi.slash")
            }
        }
        summary
        if model.loadedAt == nil {
            // Until a first answer; the note says when the Core gives none.
            if !model.unanswered { reading }
        } else if model.answers.isEmpty {
            nothingToWatch
        } else if model.failed.isEmpty && model.running.isEmpty {
            nothingListed
        } else {
            DesignDivider()
            if !model.failed.isEmpty {
                ListSectionHeader(title: "FAILED", count: model.failed.count, inset: inset)
                ForEach(model.failed) { row in
                    WatchedRunRow(row: row, serverHost: host(of: row), action: action(row), open: { open(row) }) { model.dismiss(row) }
                        .padding(.horizontal, inset - 8)
                }
            }
            if !model.running.isEmpty {
                ListSectionHeader(title: "RUNNING", count: model.running.count, inset: inset)
                ForEach(model.running) { row in
                    WatchedRunRow(row: row, serverHost: host(of: row), action: action(row), open: { open(row) })
                        .padding(.horizontal, inset - 8)
                }
            }
        }
        if !model.skipped.isEmpty {
            note(WatchedRunText.skipped(model.skipped.count), symbol: "eye.slash")
                .help(model.skipped.map(\.repository.repository.fullName).joined(separator: ", "))
                .padding(.top, 10)
        }
        if !model.unwatched.isEmpty {
            note(WatchedRunText.budget(watched: model.watched.count, total: model.answers.count), symbol: "info.circle")
                .help(model.unwatched.map(\.repository.repository.fullName).joined(separator: ", "))
                .padding(.top, 10)
        }
        Color.clear.frame(height: 8)
    }

    private func note(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, inset).padding(.bottom, 10)
    }

    /// Chips counting failed and running runs.
    @ViewBuilder private var summary: some View {
        let failed = model.failed.count, running = model.running.count
        if failed + running > 0 {
            HStack(spacing: 6) {
                if failed > 0 {
                    ListChip(symbol: "xmark.circle.fill", label: "\(failed) failed", tint: RunnirTheme.destructive, background: PullRequestColors.failedSoft)
                }
                if running > 0 {
                    ListChip(symbol: "arrow.triangle.2.circlepath", label: "\(running) running", tint: PullRequestColors.running, background: PullRequestColors.runningSoft)
                }
            }
            .padding(.horizontal, inset).padding(.bottom, 12)
            .accessibilityElement(children: .combine)
        }
    }

    private var reading: some View {
        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading runs...") }
            .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
            .padding(.horizontal, inset).padding(.vertical, 12)
    }

    private var nothingListed: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle").font(.system(size: 20)).foregroundStyle(RunnirTheme.success)
            Text("No failed or running runs").font(.system(size: 13, weight: .medium))
            if let scope = WatchedRunText.scope(workspaces: model.scope.workspaces, starred: model.scope.starred) {
                Text(scope)
                    .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, inset).padding(.top, 14).padding(.bottom, 16)
    }

    private var nothingToWatch: some View {
        VStack(spacing: 6) {
            Image(systemName: "star").font(.system(size: 20)).foregroundStyle(RunnirTheme.secondaryForeground)
            Text("Nothing to watch yet").font(.system(size: 13, weight: .medium))
            Text("Star repositories in the Workspace Manager's GitHub tab, or link a workspace to its GitHub repository, to see your failed and running runs here.")
                .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Workspace Manager") { desktop.showManager() }
                .buttonStyle(DesignButtonStyle()).padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, inset).padding(.top, 14).padding(.bottom, 16)
    }

    private func action(_ row: WatchedRun) -> String {
        WatchedRunText.action(row) { id in desktop.snapshot.workspaces.first { $0.id == id }?.name }
    }

    /// A run of a repository with a workspace opens there, in the
    /// inspector; one without opens on GitHub.
    private func open(_ row: WatchedRun) {
        if let id = row.repository.workspaceIDs.first, desktop.snapshot.workspaces.contains(where: { $0.id == id }) {
            desktop.showRun(.run(id: row.run.id, number: row.run.runNumber), workspaceID: id)
        } else if let url = row.run.htmlURL {
            openURL(url)
        }
    }

    /// The run's server host, when more than one account is signed in.
    private func host(of row: WatchedRun) -> String? {
        guard let hub = desktop.core, hub.signedInServers.count > 1 else { return nil }
        let server = row.repository.repository.serverID
        return server.isEmpty ? "github.com" : hub.serverRef(for: server)?.webHost
    }
}
