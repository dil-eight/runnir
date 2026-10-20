import SwiftUI

/// A workflow's jobs in columns: each job sits one column to the right of the
/// last job it needs, so the columns read as the order a run goes through.
enum PipelineLayout {
    static func columns(_ jobs: [CoreJob]) -> [[CoreJob]] {
        let byID = Dictionary(jobs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var depth: [String: Int] = [:]
        func level(_ id: String, visiting: inout Set<String>) -> Int {
            if let known = depth[id] { return known }
            // A cycle (an invalid workflow) is cut instead of recursing forever.
            guard let job = byID[id], visiting.insert(id).inserted else { return 0 }
            let value = job.needs.filter { byID[$0] != nil }.map { level($0, visiting: &visiting) + 1 }.max() ?? 0
            visiting.remove(id)
            depth[id] = value
            return value
        }
        for job in jobs {
            var visiting = Set<String>()
            _ = level(job.id, visiting: &visiting)
        }
        guard let last = depth.values.max() else { return [] }
        var columns = Array(repeating: [CoreJob](), count: last + 1)
        for job in jobs { columns[depth[job.id] ?? 0].append(job) }
        return columns
    }

    /// The jobs of a GitHub run that belong to one workflow job: the same
    /// name, or a matrix variant such as "build (ubuntu, 18)".
    static func runJobs(for job: CoreJob, in runJobs: [CoreRunJob]) -> [CoreRunJob] {
        let names = Set([job.name, job.id].filter { !$0.isEmpty })
        return runJobs.filter { run in names.contains(run.name) || names.contains { run.name.hasPrefix($0 + " (") } }
    }

    /// The outcome that matters most among a job's matrix variants.
    static func outcome(_ jobs: [CoreRunJob]) -> CoreRunOutcome? {
        let outcomes = Set(jobs.map(\.outcome))
        return [.failed, .running, .queued, .cancelled, .succeeded, .skipped, .neutral].first { outcomes.contains($0) }
    }

    /// From the first start to the last finish; a job still running counts to `now`.
    static func duration(_ jobs: [CoreRunJob], now: Date) -> TimeInterval? {
        guard let start = jobs.compactMap(\.startedAt).min() else { return nil }
        let end = jobs.map { $0.completedAt ?? now }.max() ?? now
        return max(0, end.timeIntervalSince(start))
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \(total / 60 % 60)m"
    }
}

/// The Overview (S03): the workspace's workflows with favorites first and
/// each one's latest GitHub run, the selected workflow's last run as a
/// pipeline, recent runs, and presets to run by hand.
struct WorkspaceOverview: View {
    let workspaceID: UUID
    let session: RepositorySession?
    let hub: CoreHub?
    let github: GitHubSession?
    let files: WorkspaceFilesModel
    let favorites: WorkflowFavorites
    let presets: DispatchPresetLibrary
    let openRun: (CoreWorkflowRun) -> Void
    let openRuns: () -> Void
    let openFile: (LocalWorkflowFile) -> Void
    /// Opens Run Workflow for a GitHub workflow id, optionally with a preset.
    let runWorkflow: (Int64?, UUID?) -> Void
    @State private var selectedPath: String?
    @State private var runJobs: CoreGitHubResult<CoreRunJob>?

    private var workflows: [LocalWorkflowFile] {
        favorites.ordered(files.files, workspaceID: workspaceID, path: \.relativePath)
    }

    private var selected: LocalWorkflowFile? {
        workflows.first { $0.relativePath == selectedPath } ?? workflows.first
    }

    private func remote(_ path: String) -> CoreGitHubWorkflow? {
        session?.remoteWorkflows.first { $0.path == path }
    }

    private func latestRun(_ path: String) -> CoreWorkflowRun? {
        guard let remote = remote(path) else { return nil }
        return session?.runs.first { $0.workflowID == remote.id }
    }

    private var githubReady: Bool { session?.githubAccess == .ok || isStale }

    /// GitHub could not be reached, so what is shown is the last data read.
    private var isStale: Bool {
        guard let session, session.githubLoadedAt != nil else { return false }
        switch session.githubAccess {
        case .unavailable, .rateLimited: return true
        default: return false
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if isStale, let session { staleBanner(session) }
                if session?.githubRepository == nil || (session?.githubAccess != .ok && !isStale) {
                    GitHubLinkCard(repository: session?.githubRepository, coreReady: session?.phase == .ready, github: github,
                                   hub: hub, workspaceID: workspaceID)
                        .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
                }
                if workflows.isEmpty {
                    UnavailableFeature(title: files.isLoading ? "Reading workflows..." : "No workflows",
                                       detail: "Workflow files in .github/workflows of this working tree appear here.",
                                       symbol: "point.3.connected.trianglepath.dotted")
                } else {
                    header
                    pipeline
                }
                DesignDivider()
                HStack(alignment: .top, spacing: 40) {
                    recentRuns.frame(maxWidth: .infinity, alignment: .leading)
                    runManually.frame(maxWidth: .infinity, alignment: .leading)
                }
                if let problem = favorites.problem {
                    Label(problem, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(RunnirTheme.warning)
                }
            }.padding(.horizontal, 28).padding(.vertical, 24)
        }
        .task(id: jobsKey) { await loadJobs() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(workflows) { file in
                        Button { selectedPath = file.relativePath } label: {
                            HStack(spacing: 6) {
                                if favorites.isFavorite(file.relativePath, workspaceID: workspaceID) {
                                    Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(RunnirTheme.warning)
                                        .accessibilityLabel("Favorite")
                                }
                                if let run = latestRun(file.relativePath) { RunOutcomeIcon(outcome: run.outcome, size: 10) }
                                Text(file.name.replacingOccurrences(of: ".yml", with: "").replacingOccurrences(of: ".yaml", with: ""))
                            }
                        }
                        .buttonStyle(WorkflowTabStyle(selected: selected == file))
                        .help(file.relativePath)
                    }
                }
            }.scrollIndicators(.hidden)
            Spacer(minLength: 8)
            if let selected {
                latestRunSummary(selected)
                Button { favorites.toggle(selected.relativePath, workspaceID: workspaceID) } label: {
                    Image(systemName: favorites.isFavorite(selected.relativePath, workspaceID: workspaceID) ? "star.fill" : "star")
                        .foregroundStyle(favorites.isFavorite(selected.relativePath, workspaceID: workspaceID) ? RunnirTheme.warning : RunnirTheme.secondaryForeground)
                }
                .buttonStyle(.borderless).disabled(!favorites.isAvailable)
                .help(favorites.isFavorite(selected.relativePath, workspaceID: workspaceID) ? "Remove from favorites" : "Add to favorites; favorites come first")
                .accessibilityLabel(favorites.isFavorite(selected.relativePath, workspaceID: workspaceID) ? "Remove from favorites" : "Add to favorites")
                Button { openFile(selected) } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless).help("Open in the Workspace editor").accessibilityLabel("Edit")
            }
        }
    }

    @ViewBuilder private func latestRunSummary(_ file: LocalWorkflowFile) -> some View {
        if let run = latestRun(file.relativePath) {
            Button { openRun(run) } label: {
                HStack(spacing: 6) {
                    RunOutcomeIcon(outcome: run.outcome, size: 12)
                    Text(run.outcome.label).foregroundStyle(color(run.outcome))
                    Text("run #\(run.runNumber) · \(String(run.headSHA.prefix(7)))").font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(RunnirTheme.secondaryForeground)
                    if let created = run.createdAt {
                        Text(created, format: .relative(presentation: .named)).foregroundStyle(RunnirTheme.secondaryForeground)
                    }
                }.font(.system(size: 12))
            }.buttonStyle(.plain).help("Open this run")
        } else if session?.githubAccess == .ok, remote(file.relativePath) == nil {
            Text("Not on GitHub yet").font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                .help("This workflow file is not on GitHub's default branch, or has not run")
        } else if session?.githubAccess == .ok {
            Text("No runs yet").font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
        }
    }

    private func color(_ outcome: CoreRunOutcome) -> Color {
        switch outcome {
        case .succeeded: RunnirTheme.success
        case .failed: RunnirTheme.destructive
        case .running, .queued: RunnirTheme.info
        default: RunnirTheme.secondaryForeground
        }
    }

    // MARK: Pipeline

    private var jobsKey: String {
        guard let selected, let run = latestRun(selected.relativePath) else { return selected?.relativePath ?? "" }
        return "\(run.id)-\(run.runAttempt)-\(run.status)-\(run.updatedAt?.timeIntervalSince1970 ?? 0)"
    }

    private func loadJobs() async {
        runJobs = nil
        guard let hub, let selected, let run = latestRun(selected.relativePath) else { return }
        let result = await hub.jobs(workspaceID: workspaceID, runID: run.id)
        guard !Task.isCancelled else { return }
        runJobs = result
    }

    @ViewBuilder private var pipeline: some View {
        if let selected {
            let definition = session?.workflows.first { $0.id == selected.relativePath }
            let columns = PipelineLayout.columns(definition?.jobs ?? [])
            let run = latestRun(selected.relativePath)
            VStack(alignment: .leading, spacing: 10) {
                if let error = definition?.parseError {
                    Label("The workflow could not be read: \(error)", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(RunnirTheme.warning)
                } else if columns.isEmpty {
                    Text(session == nil ? "Jobs appear once Runnir Core has read this repository." : "This workflow has no jobs.")
                        .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                } else {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                                if index > 0 {
                                    Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(RunnirTheme.mutedForeground)
                                        .padding(.top, 12).accessibilityHidden(true)
                                }
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(column, id: \.id) { job in jobChip(job, run: run) }
                                }
                            }
                        }
                    }.scrollIndicators(.hidden)
                    pipelineNote(run: run)
                }
            }
        }
    }

    private func jobChip(_ job: CoreJob, run: CoreWorkflowRun?) -> some View {
        let matched = runJobs.map { PipelineLayout.runJobs(for: job, in: $0.items) } ?? []
        let outcome = PipelineLayout.outcome(matched)
        return HStack(spacing: 8) {
            if let outcome { RunOutcomeIcon(outcome: outcome, size: 12) } else {
                Image(systemName: "circle").font(.system(size: 12)).foregroundStyle(RunnirTheme.mutedForeground)
                    .accessibilityLabel("Not run")
            }
            Text(job.name.isEmpty ? job.id : job.name).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 12)
            TimelineView(.periodic(from: .now, by: outcome == .running ? 1 : 3600)) { context in
                if let duration = PipelineLayout.duration(matched, now: context.date) {
                    Text(PipelineLayout.format(duration)).font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                }
            }
        }
        .padding(.horizontal, 12).frame(width: 190, height: 36)
        .background(RunnirTheme.surface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(outcome == .failed ? RunnirTheme.destructive : RunnirTheme.border))
        .help(job.needs.isEmpty ? job.id : "\(job.id) needs \(job.needs.joined(separator: ", "))")
    }

    @ViewBuilder private func pipelineNote(run: CoreWorkflowRun?) -> some View {
        if run == nil {
            Label("Jobs from the working tree file. Their status appears after the workflow runs on GitHub.", systemImage: "info.circle")
                .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
        } else if let jobs = runJobs, jobs.access != .ok {
            Label("The jobs of the latest run could not be read from GitHub.", systemImage: "exclamationmark.triangle")
                .font(.system(size: 11)).foregroundStyle(RunnirTheme.warning)
        } else {
            Label("Job status from the latest run on GitHub; columns follow the jobs' needs in the working tree file.", systemImage: "info.circle")
                .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
        }
    }

    // MARK: Runs and presets

    private var recentRuns: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(title: "RECENT RUNS")
                Spacer()
                Button("All runs", action: openRuns).buttonStyle(.link).font(.system(size: 12)).disabled(session?.runs.isEmpty ?? true)
            }
            DesignDivider()
            if let session, session.githubRepository != nil {
                RecentRunsList(session: session, github: github, hub: hub, limit: 5, open: openRun)
            } else {
                UnavailableFeature(title: "No runs available", detail: "This working tree has no GitHub remote.", symbol: "play.circle")
            }
        }
    }

    private var runManually: some View {
        let available = session?.githubAccess == .ok
        let rows: [(DispatchPreset, CoreGitHubWorkflow)] = (session?.remoteWorkflows ?? []).flatMap { workflow in
            presets.presets(workspaceID: workspaceID, workflowPath: workflow.path).map { ($0, workflow) }
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(title: "RUN MANUALLY")
                Spacer()
                Button("New...") { runWorkflow(nil, nil) }.buttonStyle(.link).font(.system(size: 12)).disabled(!available)
            }
            DesignDivider()
            if rows.isEmpty {
                Text(available ? "Presets you save in Run Workflow appear here." : "Running workflows needs access to the repository on GitHub.")
                    .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground).padding(.vertical, 6)
            }
            ForEach(rows, id: \.0.id) { preset, workflow in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preset.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(presetDetail(preset, workflow: workflow)).font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button("Run") { runWorkflow(workflow.id, preset.id) }
                        .buttonStyle(DesignButtonStyle()).disabled(!available || workflow.state != "active")
                        .help("Review and start \(workflow.name) with this preset")
                }.padding(.vertical, 4)
                DesignDivider()
            }
        }
    }

    private func presetDetail(_ preset: DispatchPreset, workflow: CoreGitHubWorkflow) -> String {
        let inputs = preset.inputs.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        return ([workflow.name, preset.ref] + inputs).joined(separator: " · ")
    }

    private func staleBanner(_ session: RepositorySession) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(RunnirTheme.warning)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(session.githubAccess == .unavailable ? "GitHub can't be reached. Showing runs from" : "GitHub is rate-limiting requests. Showing runs from")
                    if let loaded = session.githubLoadedAt { Text(loaded, format: .relative(presentation: .named)) }
                }.font(.system(size: 13, weight: .medium))
                Text("Runs and the pipeline may be out of date. Running workflows is unavailable until GitHub answers again.")
                    .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
            }
            Spacer(minLength: 8)
            Button("Try Again") { Task { await hub?.loadGitHubActivity(workspaceID: workspaceID) } }.buttonStyle(DesignButtonStyle())
        }
        .padding(14).background(RunnirTheme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}
