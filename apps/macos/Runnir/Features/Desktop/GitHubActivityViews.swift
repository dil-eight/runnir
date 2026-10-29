import SwiftUI

/// Status icon for a run, job or step.
struct RunOutcomeIcon: View {
    let outcome: CoreRunOutcome
    var size: CGFloat = 14

    var body: some View {
        Image(systemName: outcome.symbol)
            .font(.system(size: size))
            .foregroundStyle(color)
            .accessibilityLabel(outcome.label)
            .help(outcome.label)
    }

    private var color: Color { Self.color(outcome) }

    static func color(_ outcome: CoreRunOutcome) -> Color {
        switch outcome {
        case .succeeded: RunnirTheme.success
        case .failed: RunnirTheme.destructive
        case .running, .queued: RunnirTheme.info
        case .cancelled, .skipped, .neutral: RunnirTheme.secondaryForeground
        }
    }
}


/// One line per run: status, title, number, branch, event, what it belongs
/// to and age. A superseded run shown on request is dimmed; an outdated one
/// (superseded, still going) says so.
struct RunRow: View {
    let run: CoreWorkflowRun
    var selected = false
    /// The pull request the run belongs to, for the help.
    var pullRequest: CoreChangePullRequest? = nil
    /// The run that superseded this one, for the outdated label's help.
    var newer: CoreWorkflowRun? = nil

    private var dimmed: Bool { run.isSuperseded && !run.outcome.isActive }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RunOutcomeIcon(outcome: run.outcome).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                // The age shares the title's line, so the detail line has
                // the full width for what the run belongs to.
                HStack(spacing: 6) {
                    Text(run.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if run.isOutdated {
                        RunTag(text: "outdated", tint: RunnirTheme.info).help(RunPresentation.outdatedHelp(run, newer: newer))
                    } else if dimmed {
                        RunTag(text: "older commit", tint: RunnirTheme.secondaryForeground)
                    }
                    Spacer(minLength: 8)
                    if let created = run.createdAt {
                        Text(created, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                            .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                            .lineLimit(1).fixedSize()
                    }
                }
                HStack(spacing: 0) {
                    if run.startedFromRunnir {
                        Text(RunPresentation.fromRunnir).foregroundStyle(RunnirTheme.primary).fixedSize()
                            .accessibilityLabel("started from Runnir")
                    }
                    Text(RunPresentation.detail(run)).foregroundStyle(RunnirTheme.secondaryForeground)
                }
                .font(.system(size: 11)).lineLimit(1)
            }
        }
        .opacity(dimmed ? 0.6 : 1)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .clickable()
        .background(selected ? RunnirTheme.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
        .help(RunPresentation.rowHelp(run, pullRequest: pullRequest))
        .accessibilityElement(children: .combine)
    }
}

/// The newest runs for the Overview.
struct RecentRunsList: View {
    let session: RepositorySession
    let github: GitHubSession?
    let hub: CoreHub?
    var limit = 5
    /// Off where the screen already says what is missing (the Overview's
    /// GitHub card or stale banner), so the same notice is not shown twice.
    var showsAccessNotice = true
    let open: (CoreWorkflowRun) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ActivityFreshnessLine(session: session)
            if let access = session.githubAccess,
               let help = hub?.accessHelp(access, workspaceID: session.workspaceID, purpose: .read, details: session.githubDetails)
                   ?? GitHubAccessHelp.forAccess(access, repository: session.githubRepository, purpose: .read, details: session.githubDetails) {
                if showsAccessNotice {
                    GitHubAccessNotice(help: help, style: .note, github: github) {
                        Task { await hub?.loadGitHubActivity(workspaceID: session.workspaceID) }
                    }
                } else if session.runs.isEmpty {
                    Text("Runs appear here once Runnir can read them from GitHub.")
                        .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground).padding(.vertical, 6)
                }
            }
            if session.runs.isEmpty {
                if session.isLoadingGitHub {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading runs...").font(.system(size: 12)) }
                } else if session.githubAccess == .ok {
                    UnavailableFeature(title: "No runs yet", detail: "No workflow has run on GitHub for this repository.", symbol: "play.circle")
                }
            }
            let pullRequests = RunPresentation.pullRequests(session.changes)
            ForEach(RunPresentation.visible(session.runs, showingSuperseded: false).prefix(limit)) { run in
                Button { open(run) } label: {
                    RunRow(run: run, pullRequest: run.link.pullRequest.flatMap { pullRequests[$0] })
                }.buttonStyle(.hit)
            }
        }
    }
}

/// What a search has to cover: it loads again when the cache grows.
private struct SavedRunsSearch: Hashable {
    let searching: Bool
    let cachedRuns: Int
}

/// Runs section: the runs as a list or by change, and the selected run's
/// jobs and steps.
struct WorkspaceRunsView: View {
    let session: RepositorySession
    let hub: CoreHub
    let github: GitHubSession?
    @Binding var selectedRunID: Int64?
    @Binding var mode: RunsMode
    /// A search the global search asks for.
    @Binding var request: RunsListRequest?
    var dismissals: ConcurrencyHintDismissals? = nil
    var addConcurrency: (String) -> Void = { _ in }
    @State private var onlyCurrentBranch = false
    @State private var showingSuperseded = false
    @State private var expanded: Set<String> = []
    @State private var query = ""
    @State private var filter = RunFilter()
    /// The log of a job, opened over the list and the graph.
    @State private var layer: RunLayerModel
    /// The Core's answers to the typed query, and a deep search on GitHub.
    @State private var search: RunSearchModel

    init(session: RepositorySession, hub: CoreHub, github: GitHubSession?, selectedRunID: Binding<Int64?>, mode: Binding<RunsMode>,
         request: Binding<RunsListRequest?> = .constant(nil), dismissals: ConcurrencyHintDismissals? = nil, addConcurrency: @escaping (String) -> Void = { _ in }) {
        self.session = session
        self.hub = hub
        self.github = github
        _selectedRunID = selectedRunID
        _mode = mode
        _request = request
        self.dismissals = dismissals
        self.addConcurrency = addConcurrency
        _layer = State(initialValue: RunLayerModel(hub: hub, workspaceID: session.workspaceID))
        _search = State(initialValue: RunSearchModel(hub: hub, workspaceID: session.workspaceID))
    }

    private var branch: String? { onlyCurrentBranch && !session.branch.isEmpty ? session.branch : nil }
    private var runsByID: [Int64: CoreWorkflowRun] {
        Dictionary(session.runs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
    private var branchRuns: [CoreWorkflowRun] {
        guard let branch else { return session.runs }
        return session.runs.filter { $0.branch == branch }
    }
    private var searching: Bool { RunSearch.isActive(query) }
    /// A search or a filter narrows the list to the saved runs, all of them.
    private var narrowing: Bool { searching || !filter.isEmpty }
    /// The saved runs the Core found for the query; nil (nothing narrowed)
    /// until it answers or when it cannot.
    private var matchingIDs: Set<Int64>? { searching ? search.matchingIDs : nil }
    /// A query is typed and the Core has not answered any yet.
    private var awaitingAnswer: Bool { searching && search.matchingIDs == nil && !search.unavailable }
    /// Runs per status that match the typed query and the branch filter.
    private var statusCounts: [RunStatusFilter: Int] {
        RunStatusFilter.counts(RunPresentation.matching(session.runs, branch: branch, ids: matchingIDs))
    }
    /// Runs Runnir started that match the typed query and the branch filter.
    private var fromRunnirCount: Int {
        RunFilter.fromRunnirCount(RunPresentation.matching(session.runs, branch: branch, ids: matchingIDs))
    }
    /// The run shown in the inspector: a saved one, or one the search found.
    private var selectedRun: CoreWorkflowRun? {
        session.runs.first { $0.id == selectedRunID } ?? selectedRunID.flatMap { search.run(id: $0) }
    }
    /// What a search found beyond the saved runs, narrowed by the branch and the filter.
    private func beyondSaved(_ runs: [CoreWorkflowRun]) -> [CoreWorkflowRun] {
        let onBranch = branch.map { branch in runs.filter { $0.branch == branch } } ?? runs
        return filter.apply(onBranch)
    }
    /// Every run saved on this Mac, which a search covers.
    private var savedRuns: Int { max(session.cachedRuns, session.runs.count) }
    private var pullRequests: [Int64: CoreChangePullRequest] { RunPresentation.pullRequests(session.changes) }
    /// Suggestions the user did not turn off.
    private var hints: [CoreConcurrencyHint] {
        session.concurrencyHints.filter { !(dismissals?.isDismissed($0.path, workspaceID: session.workspaceID) ?? false) }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                ActivityFreshnessLine(session: session).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 10)
                if let help = hub.pullRequestsHelp(workspaceID: session.workspaceID) {
                    GitHubAccessNotice(help: help, style: .note, github: github) {
                        Task { await hub.loadGitHubActivity(workspaceID: session.workspaceID) }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 8)
                }
                DesignDivider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if let access = session.githubAccess,
                           let help = hub.accessHelp(access, workspaceID: session.workspaceID, purpose: .read, details: session.githubDetails) {
                            GitHubAccessNotice(help: help, style: .banner, github: github) {
                                Task { await hub.loadGitHubActivity(workspaceID: session.workspaceID) }
                            }.padding(8)
                        }
                        switch mode {
                        case .list: listRows
                        case .byChange: changeBlocks
                        }
                        // A search or a filter reads the saved runs only: loading older ones from GitHub waits until it ends.
                        if !narrowing { OlderRunsFooter(session: session, hub: hub) }
                    }.padding(6)
                }
            }
            .frame(width: 300)
            DesignDivider(vertical: true)
            inspector.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay {
            if layer.isOpen, let run = selectedRun {
                RunLogLayer(model: layer, run: run, workspaceID: session.workspaceID, hub: hub)
            }
        }
        .onChange(of: query) { search.update(query: query) }
        .onChange(of: request, initial: true) { _, value in
            guard let value else { return }
            request = nil
            if let id = value.unlessSaved, session.runs.contains(where: { $0.id == id }) { return }
            query = value.query
        }
        .onChange(of: session.cachedRuns) { search.refresh() }
        .onAppear { if selectedRunID == nil { selectedRunID = session.runs.first?.id } }
        // Runs the cache gets while the search is open (a sync, or a window that
        // opened with an empty cache) are covered too.
        .task(id: SavedRunsSearch(searching: narrowing, cachedRuns: session.cachedRuns)) {
            if narrowing {
                await hub.loadSavedRuns(workspaceID: session.workspaceID)
            } else {
                await hub.endSavedRunsSearch(workspaceID: session.workspaceID)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            modeRow
            HStack(spacing: 6) {
                searchField
                StatusFilterButton(filter: $filter, counts: statusCounts, fromRunnirCount: fromRunnirCount, query: query)
            }
            if !filter.isEmpty { StatusChips(filter: $filter) }
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(RunnirTheme.mutedForeground)
            TextField("Search runs", text: $query).textFieldStyle(.plain)
                .help("Title, workflow, commit, branch, author, event, status or #pull request; every word has to match")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).pointerStyle(.link).foregroundStyle(RunnirTheme.mutedForeground)
                    .help("Clear the search").accessibilityLabel("Clear the search")
            }
        }
        .font(.system(size: 12)).padding(.horizontal, 8).frame(height: 26)
        .background(RunnirTheme.surface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(RunnirTheme.border))
    }

    private var modeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker("Show runs", selection: $mode) {
                    Text("List").tag(RunsMode.list)
                    Text("By change").tag(RunsMode.byChange)
                }
                .pickerStyle(.segmented).pointerStyle(.link).labelsHidden().fixedSize()
                .help("List shows runs newest first; By change groups them by pull request and commit")
                Spacer()
                Button {
                    Task { await hub.loadGitHubActivity(workspaceID: session.workspaceID) }
                } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).pointerStyle(.link).disabled(session.isLoadingGitHub).help("Reload runs from GitHub")
            }
            // On a row of its own: a branch name such as dilbarov/docs-after-b33-b34 is long.
            Toggle(isOn: $onlyCurrentBranch) {
                Text(session.branch.isEmpty ? "Current branch" : session.branch).lineLimit(1).truncationMode(.middle)
            }
            .toggleStyle(.checkbox).pointerStyle(.link).disabled(session.branch.isEmpty)
            .help(session.branch.isEmpty ? "Only the runs of the branch checked out here" : "Only the runs of \(session.branch)")
        }
        .font(.system(size: 12))
    }

    /// What a search shows and covers, or what it found nothing in.
    @ViewBuilder private func searchNote(found: Int, noun: String, summary: String) -> some View {
        if found == 0 {
            VStack(alignment: .leading, spacing: 6) {
                if searching {
                    Text("No \(noun) match \u{201C}\(query.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}\(filter.isEmpty ? "" : " and the chosen filters").")
                } else {
                    Text("No \(noun) match the chosen filters.")
                }
                Text(summary).foregroundStyle(RunnirTheme.mutedForeground)
                HStack(spacing: 12) {
                    if searching { Button("Clear search") { query = "" }.buttonStyle(.link).pointerStyle(.link) }
                    if !filter.isEmpty { Button("Clear filters") { filter = RunFilter() }.buttonStyle(.link).pointerStyle(.link) }
                }
            }
            .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground).padding(12)
        } else {
            Text(summary)
                .font(.system(size: 11)).foregroundStyle(RunnirTheme.mutedForeground).padding(.horizontal, 10).padding(.vertical, 6)
        }
    }

    @ViewBuilder private var listRows: some View {
        let runs = RunPresentation.list(session.runs, branch: branch, matching: matchingIDs, filter: filter, showingSuperseded: showingSuperseded)
        let indexed = searching ? beyondSaved(search.indexedRuns) : []
        let github = searching ? beyondSaved(search.foundOnGitHub(excluding: Set(session.runs.map(\.id)))) : []
        if searching && search.unavailable {
            searchUnavailable
        } else if awaitingAnswer {
            searchingLine
        } else if narrowing {
            searchNote(found: runs.count + indexed.count + github.count, noun: "runs",
                       summary: RunSearch.summary(matches: runs.count, saved: savedRuns, indexed: searching ? (search.saved?.indexedSearched ?? 0) : 0,
                                                  historyComplete: session.historyComplete))
        }
        ForEach(runs) { run in
            RunRow(run: run, selected: run.id == selectedRunID, pullRequest: run.link.pullRequest.flatMap { pullRequests[$0] },
                   newer: run.supersededBy.flatMap { runsByID[$0] })
                .clickable().onTapGesture { selectedRunID = run.id }
        }
        if !indexed.isEmpty {
            RunGroupHeader(title: "IN THE SEARCH INDEX \u{00B7} \(indexed.count)")
            ForEach(indexed) { run in extraRow(run) }
        }
        if !github.isEmpty {
            RunGroupHeader(title: "FOUND ON GITHUB \u{00B7} \(github.count)")
            ForEach(github) { run in extraRow(run) }
        }
        if searching {
            DeepSearchFooter(model: search, githubReady: session.githubAccess == .ok)
        }
        if runs.isEmpty && !narrowing && session.githubAccess == .ok {
            Text(onlyCurrentBranch ? "No runs on this branch." : "No runs yet.")
                .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground).padding(12)
        }
        let hidden = RunPresentation.hiddenCount(branchRuns)
        if !narrowing, showingSuperseded || hidden > 0 {
            Button(showingSuperseded ? "Hide superseded runs" : "\(hidden) superseded \(hidden == 1 ? "run" : "runs") hidden · Show") {
                showingSuperseded.toggle()
            }
            .buttonStyle(.link).pointerStyle(.link).font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 6)
            .help("Runs on older commits of a pull request that a newer push replaced")
        }
    }

    private var searchingLine: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Searching the saved runs\u{2026}")
        }
        .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground).padding(12)
    }

    /// The Core did not answer: the list stays as it is rather than look empty.
    private var searchUnavailable: some View {
        Label("Runnir Core did not answer, so the search could not run. The list is not narrowed by it.", systemImage: "exclamationmark.triangle")
            .font(.system(size: 12)).foregroundStyle(RunnirTheme.warning).fixedSize(horizontal: false, vertical: true).padding(12)
    }

    /// A run the search found that the activity cache does not hold.
    private func extraRow(_ run: CoreWorkflowRun) -> some View {
        RunRow(run: run, selected: run.id == selectedRunID, pullRequest: nil, newer: nil)
            .clickable().onTapGesture { selectedRunID = run.id }
    }

    @ViewBuilder private var changeBlocks: some View {
        let changes = RunPresentation.changes(session.changes, runs: runsByID, branch: branch, matching: matchingIDs, filter: filter)
        if searching && search.unavailable {
            searchUnavailable
        } else if awaitingAnswer {
            searchingLine
        } else if narrowing {
            searchNote(found: changes.count, noun: "changes",
                       summary: "Showing \(changes.count) of \(session.changes.count) changes" + (session.historyComplete ? "" : ". Older runs are on GitHub."))
        }
        ForEach(changes) { change in
            RunChangeBlock(change: change, runs: runsByID, selectedRunID: selectedRunID, expanded: $expanded,
                           hints: hints.filter { hint in change.pullRequest.map { hint.pullRequests.contains($0.number) } ?? false },
                           workflowName: workflowName, select: { selectedRunID = $0 },
                           addConcurrency: addConcurrency, dismissHint: dismissHint)
        }
        if changes.isEmpty && !narrowing && session.githubAccess == .ok {
            Text(onlyCurrentBranch ? "No runs on this branch." : "No runs yet.")
                .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground).padding(12)
        }
    }

    @ViewBuilder private var inspector: some View {
        if let run = selectedRun {
            RunInspectorView(run: run, workspaceID: session.workspaceID, hub: hub, layer: layer, github: github,
                             context: RunPresentation.context(for: run, runs: runsByID, pullRequests: pullRequests, hints: hints,
                                                              workflowName: workflowName(run.workflowID)),
                             select: { selectedRunID = $0 }, addConcurrency: addConcurrency, dismissHint: dismissHint)
                .id(run.id)
        } else {
            UnavailableFeature(title: "Select a run", detail: "Choose a run to see its jobs, steps and logs.", symbol: "play.circle")
                .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func workflowName(_ id: Int64) -> String {
        session.remoteWorkflows.first { $0.id == id }?.name ?? "this workflow"
    }

    private func dismissHint(_ path: String) {
        dismissals?.dismiss(path, workspaceID: session.workspaceID)
    }
}

/// Workflows section: the repository's workflows on GitHub with each one's
/// newest run.
struct WorkspaceWorkflowsView: View {
    let session: RepositorySession
    let hub: CoreHub
    let github: GitHubSession?
    var favorites: WorkflowFavorites?
    let showRun: (CoreWorkflowRun) -> Void
    let runWorkflow: (CoreGitHubWorkflow) -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if let access = session.githubAccess,
                   let help = hub.accessHelp(access, workspaceID: session.workspaceID, purpose: .read, details: session.githubDetails) {
                    GitHubAccessNotice(help: help, style: .banner, github: github) {
                        Task { await hub.loadGitHubActivity(workspaceID: session.workspaceID) }
                    }.padding(.bottom, 12)
                } else if let installation = session.githubDetails?.installation,
                          let help = GitHubAccessHelp.installationBlocker(installation, purpose: .run, refused: false) {
                    // Workflows can be read, but starting them waits for an owner.
                    GitHubAccessNotice(help: help, style: .banner, github: github).padding(.bottom, 12)
                }
                ForEach(favorites?.ordered(session.remoteWorkflows, workspaceID: session.workspaceID, path: \.path) ?? session.remoteWorkflows) { workflow in
                    let latest = session.runs.first { $0.workflowID == workflow.id }
                    let favorite = favorites?.isFavorite(workflow.path, workspaceID: session.workspaceID) ?? false
                    HStack(spacing: 10) {
                        if let favorites, WorkflowFavorites.canFavorite(workflow.path) {
                            Button { favorites.toggle(workflow.path, workspaceID: session.workspaceID) } label: {
                                Image(systemName: favorite ? "star.fill" : "star")
                                    .foregroundStyle(favorite ? RunnirTheme.warning : RunnirTheme.mutedForeground)
                            }
                            .buttonStyle(.borderless).pointerStyle(.link).disabled(!favorites.isAvailable)
                            .help(favorite ? "Remove from favorites" : "Add to favorites; favorites come first")
                            .accessibilityLabel(favorite ? "Remove \(workflow.name) from favorites" : "Add \(workflow.name) to favorites")
                        }
                        if let latest { RunOutcomeIcon(outcome: latest.outcome) } else {
                            Image(systemName: "circle.dashed").foregroundStyle(RunnirTheme.secondaryForeground)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(workflow.name).font(.system(size: 13, weight: .medium))
                            Text(workflow.path).font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                        }
                        Spacer()
                        if workflow.state != "active" {
                            Text(workflow.state.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(.system(size: 11)).foregroundStyle(RunnirTheme.warning)
                        }
                        if let latest {
                            Button("Last run") { showRun(latest) }.buttonStyle(.link).pointerStyle(.link).font(.system(size: 12))
                        }
                        if workflow.canBeStartedByHand {
                            Button("Run...") { runWorkflow(workflow) }.buttonStyle(.link).pointerStyle(.link).font(.system(size: 12))
                                .help("Start this workflow by hand if it has a workflow_dispatch trigger")
                        }
                        if let url = workflow.htmlURL {
                            Button { openURL(url) } label: { Image(systemName: "arrow.up.right.square") }
                                .buttonStyle(.borderless).pointerStyle(.link).help("Open on GitHub")
                        }
                    }
                    .padding(.horizontal, 12).frame(height: 52)
                    DesignDivider()
                }
                if session.remoteWorkflows.isEmpty && session.githubAccess == .ok {
                    UnavailableFeature(title: "No workflows on GitHub",
                                       detail: "Workflows appear here after they are pushed to GitHub. Local files are in the Workspace section.",
                                       symbol: "point.3.connected.trianglepath.dotted")
                }
            }.padding(24)
        }
    }
}
