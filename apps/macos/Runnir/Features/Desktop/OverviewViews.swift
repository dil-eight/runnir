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
    /// name, a matrix variant such as "build (ubuntu, 18)", or a job of a
    /// called workflow such as "release / publish". A name set by an
    /// expression ("Build ${{ matrix.os }}") is known only up to the
    /// expression, so it takes the run jobs starting with that part that no
    /// other job of `jobs` names.
    static func runJobs(for job: CoreJob, in runJobs: [CoreRunJob], among jobs: [CoreJob] = []) -> [CoreRunJob] {
        let stem = job.name.range(of: "${{").map { job.name[..<$0.lowerBound].trimmingCharacters(in: .whitespaces) } ?? ""
        return runJobs.filter { run in
            names(job, run)
                || (!stem.isEmpty && run.name.hasPrefix(stem) && !jobs.contains { $0.id != job.id && names($0, run) })
        }
    }

    private static func names(_ job: CoreJob, _ run: CoreRunJob) -> Bool {
        [job.name, job.id].contains { name in
            !name.isEmpty && !name.contains("${{")
                && (run.name == name || run.name.hasPrefix(name + " (") || run.name.hasPrefix(name + " / "))
        }
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

    /// What hovering a job of the pipeline says: its status in the latest
    /// run, and the jobs it needs.
    static func hint(for job: CoreJob, matched: [CoreRunJob], readFailed: Bool, now: Date, start: ManualJobStart? = nil) -> String {
        var lines: [String] = []
        let byHand = "Runs only when started by hand" + (job.manualInputs.isEmpty ? "" : " with \(ManualJobStart.describe(job.manualInputs))")
        switch start {
        case .approve:
            lines.append("Waiting for your approval to deploy · ▶ approves it")
        case .dispatch(_, let ref, _):
            lines.append("\(byHand) · ▶ starts it on \(ref)")
        case nil:
            if job.manual { lines.append(byHand) }
        }
        if let outcome = outcome(matched) {
            switch outcome {
            case .skipped:
                lines.append("Skipped in the latest run: its condition was not met, or a job it needs did not succeed")
            case .queued:
                lines.append("Queued")
            default:
                let time = duration(matched, now: now).map { " · \(format($0))" } ?? ""
                lines.append(outcome.label + time)
            }
        } else if readFailed {
            lines.append("Status unknown: the latest run's jobs could not be read from GitHub")
        } else {
            lines.append("Not in the latest run")
        }
        if !job.needs.isEmpty { lines.append("Needs \(job.needs.joined(separator: ", "))") }
        return lines.joined(separator: "\n")
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
/// pipeline, recent runs, presets to run by hand, and what this Mac saved.
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
    /// The selected workflow's path, kept by the window.
    @Binding var selectedPath: String?
    @State private var runJobs: CoreGitHubResult<CoreRunJob>?
    /// The run `runJobs` belongs to; jobs stay shown while the same run reloads.
    @State private var runJobsRunID: Int64?
    /// What starting a manual job did, by workflow path, shown under that
    /// workflow's pipeline.
    @State private var manualJobMessages: [String: String] = [:]
    /// The manual job being started; its ▶ waits meanwhile.
    @State private var startingJobID: String?

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

    private func runs(_ path: String) -> [CoreWorkflowRun] {
        guard let remote = remote(path) else { return [] }
        return session?.runs.filter { $0.workflowID == remote.id } ?? []
    }

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
                if let savings = session?.savings, !savings.isEmpty { SavingsSection(savings: savings) }
                if let problem = favorites.problem {
                    Label(problem, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(RunnirTheme.warning)
                }
            }.padding(.horizontal, 28).padding(.vertical, 24)
        }
        .task(id: jobsKey) { await loadJobs() }
        // The presets file is read on first use; reading it here keeps the
        // view from loading it while it draws.
        .task { presets.prepare() }
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
                                Text((file.name as NSString).deletingPathExtension)
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
                .buttonStyle(.borderless).pointerStyle(.link).disabled(!favorites.isAvailable)
                .help(favorites.isFavorite(selected.relativePath, workspaceID: workspaceID) ? "Remove from favorites" : "Add to favorites; favorites come first")
                .accessibilityLabel(favorites.isFavorite(selected.relativePath, workspaceID: workspaceID) ? "Remove from favorites" : "Add to favorites")
                Button { openFile(selected) } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless).pointerStyle(.link).help("Open in the Workspace editor").accessibilityLabel("Edit")
            }
        }
    }

    @ViewBuilder private func latestRunSummary(_ file: LocalWorkflowFile) -> some View {
        if let run = latestRun(file.relativePath) {
            Button { openRun(run) } label: {
                HStack(spacing: 6) {
                    RunOutcomeIcon(outcome: run.outcome, size: 12)
                    Text(run.outcome.label).foregroundStyle(color(run.outcome))
                    Text(RunPresentation.summary(run)).font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(RunnirTheme.secondaryForeground)
                    if let created = run.createdAt {
                        Text(created, format: .relative(presentation: .named)).foregroundStyle(RunnirTheme.secondaryForeground)
                    }
                }.font(.system(size: 12))
            }.buttonStyle(.hit).help("Open this run")
        } else if session?.githubAccess == .ok, remote(file.relativePath) == nil {
            Text("Not on GitHub yet").font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                .help("This workflow file is not on GitHub's default branch, or has not run")
        } else if session?.githubAccess == .ok {
            Text("No recent runs").font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                .help("None of the runs Runnir read from GitHub belongs to this workflow")
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
        guard let hub, let selected, let run = latestRun(selected.relativePath) else {
            runJobs = nil
            runJobsRunID = nil
            return
        }
        // A newer report of the same run keeps the jobs on screen until the
        // new ones arrive; another run starts empty.
        if runJobsRunID != run.id { runJobs = nil }
        let result = await hub.jobs(workspaceID: workspaceID, runID: run.id)
        guard !Task.isCancelled else { return }
        runJobs = result
        runJobsRunID = run.id
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
                                    ForEach(column, id: \.id) { job in
                                        jobChip(job, among: definition?.jobs ?? [], workflowName: definition?.name ?? selected.name)
                                    }
                                }
                            }
                        }
                    }.scrollIndicators(.hidden)
                    pipelineNote(run: run)
                    if let message = manualJobMessages[selected.relativePath] {
                        Label(message, systemImage: "play.circle")
                            .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func jobChip(_ job: CoreJob, among jobs: [CoreJob], workflowName: String) -> some View {
        let matched = runJobs.map { PipelineLayout.runJobs(for: job, in: $0.items, among: jobs) } ?? []
        let outcome = PipelineLayout.outcome(matched)
        let path = selected?.relativePath ?? ""
        let start = session?.githubAccess == .ok
            ? ManualJobStart.of(job, matched: matched, run: latestRun(path), workflowRuns: runs(path), workflow: remote(path),
                                defaultBranch: session?.githubDetails?.defaultBranch) : nil
        return HStack(spacing: 8) {
            if let outcome { RunOutcomeIcon(outcome: outcome, size: 12) } else {
                Image(systemName: "circle").font(.system(size: 12)).foregroundStyle(RunnirTheme.mutedForeground)
                    .accessibilityLabel("Not run")
            }
            Text(job.name.isEmpty ? job.id : job.name).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 12)
            if let start {
                manualButton(start, job: job, workflowName: workflowName, path: path)
            } else {
                TimelineView(.periodic(from: .now, by: outcome == .running ? 1 : 3600)) { context in
                    if let duration = PipelineLayout.duration(matched, now: context.date) {
                        Text(PipelineLayout.format(duration)).font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                    }
                }
            }
        }
        .padding(.horizontal, 12).frame(width: 190, height: 36)
        .background(RunnirTheme.surface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(outcome == .failed ? RunnirTheme.destructive : RunnirTheme.border))
        .help(PipelineLayout.hint(for: job, matched: matched, readFailed: runJobs.map { $0.access != .ok } ?? false, now: Date(), start: start))
    }

    private func manualButton(_ start: ManualJobStart, job: CoreJob, workflowName: String, path: String) -> some View {
        Button {
            guard let hub, startingJobID == nil else { return }
            startingJobID = job.id
            Task {
                if let message = await ManualJobRunner.start(start, jobName: job.name.isEmpty ? job.id : job.name,
                                                             workflowName: workflowName, workspaceID: workspaceID, hub: hub) {
                    manualJobMessages[path] = message
                }
                startingJobID = nil
            }
        } label: {
            if startingJobID == job.id {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "play.fill").font(.system(size: 10)).foregroundStyle(RunnirTheme.primary)
                    .frame(width: 22, height: 22).background(RunnirTheme.primary.opacity(0.16), in: Circle())
            }
        }
        .buttonStyle(.hit).disabled(startingJobID != nil)
        .help(start.buttonHelp(jobName: job.name.isEmpty ? job.id : job.name))
        .accessibilityLabel(start.buttonHelp(jobName: job.name.isEmpty ? job.id : job.name))
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
                Button("All runs", action: openRuns).buttonStyle(.link).pointerStyle(.link).font(.system(size: 12)).disabled(session?.runs.isEmpty ?? true)
            }
            DesignDivider()
            if let session, session.githubRepository != nil {
                RecentRunsList(session: session, github: github, hub: hub, limit: 5, showsAccessNotice: false, open: openRun)
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
        let shared = RepositoryPresetRow.rows(presets: session?.launchPresets ?? [], remoteWorkflows: session?.remoteWorkflows ?? [],
                                              readError: session?.launchPresetsError)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(title: "RUN MANUALLY")
                Spacer()
                Button("New...") { runWorkflow(nil, nil) }.buttonStyle(.link).pointerStyle(.link).font(.system(size: 12)).disabled(!available)
            }
            DesignDivider()
            // Reading works, but starting waits for an owner's approval or
            // for write access: said where workflows are started.
            if available, let repository = session?.githubRepository,
               let blocker = GitHubAccessHelp.blocker(for: .run, repository: repository, details: session?.githubDetails) {
                GitHubAccessNotice(help: blocker, style: .note, github: github).padding(.vertical, 6)
            }
            if !shared.isEmpty {
                presetGroup("IN THIS REPOSITORY", symbol: "folder.badge.gearshape", source: ".runnir/launches")
                ForEach(shared) { row in
                    sharedRow(row, available: available)
                    DesignDivider()
                }
                presetGroup("ON THIS MAC", symbol: "laptopcomputer", source: nil)
            }
            if rows.isEmpty {
                Text(available ? "Presets you save in Run Workflow appear here." : "Running workflows needs access to the repository on GitHub.")
                    .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground).padding(.vertical, 6)
            }
            ForEach(rows, id: \.0.id) { preset, workflow in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preset.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(DispatchPreset.detail(workflow: workflow.name, ref: preset.ref, inputs: preset.inputs))
                            .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button("Run") { runWorkflow(workflow.id, preset.id) }
                        .buttonStyle(DesignButtonStyle()).disabled(!available || workflow.state != "active")
                        .help("Review and start \(workflow.name) with this preset")
                }.padding(.vertical, 4)
                DesignDivider()
            }
            if !shared.isEmpty {
                Label("Repository presets are shared through Git. Runnir reads them and never changes them.", systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(RunnirTheme.mutedForeground).padding(.top, 4)
            }
        }
    }

    private func presetGroup(_ title: String, symbol: String, source: String?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(title).fontWeight(.semibold).tracking(0.6)
            Spacer(minLength: 8)
            if let source { Text(source).font(.system(size: 11, design: .monospaced)) }
        }
        .font(.system(size: 10)).foregroundStyle(RunnirTheme.mutedForeground).padding(.top, 8)
    }

    @ViewBuilder private func sharedRow(_ row: RepositoryPresetRow, available: Bool) -> some View {
        switch row {
        case .preset(let preset, let workflow):
            let declared = session?.workflows.first { $0.id == preset.workflowPath }?.dispatchInputs ?? []
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(RepositoryPresetRow.detail(preset, workflow: workflow, declared: declared, available: available))
                        .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button("Run") {
                    if let workflow { runWorkflow(workflow.id, CoreLaunchPreset.presetID(workspaceID: workspaceID, path: preset.path)) }
                }
                .buttonStyle(DesignButtonStyle()).disabled(!RepositoryPresetRow.canRun(workflow: workflow, available: available))
                .help(workflow.map { "Review and start \($0.name) with this preset" } ?? "This workflow is not on GitHub yet")
            }.padding(.vertical, 4)
        case .problem(let preset):
            problemRow(title: preset.fileName, detail: preset.problem ?? "")
        case .unreadable(let reason):
            problemRow(title: ".runnir/launches", detail: "Repository presets could not be read. \(reason)")
        }
    }

    private func problemRow(title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(RunnirTheme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(1)
                Text(detail).font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 6)
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

/// What this Mac saved the workspace: one tile per kind the Core counted, so
/// a new kind adds a tile.
struct SavingsSection: View {
    let savings: [CoreSaving]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "SAVED")
            DesignDivider()
            HStack(alignment: .top, spacing: 12) {
                ForEach(savings, id: \.kind) { tile($0) }
                Spacer(minLength: 0)
            }.padding(.top, 4)
        }
    }

    private func tile(_ saving: CoreSaving) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(SavingText.title(saving)).font(.system(size: 11, weight: .medium)).foregroundStyle(RunnirTheme.secondaryForeground)
            Text(SavingText.amount(minutes: saving.minutes)).font(.system(size: 22, weight: .semibold)).monospacedDigit()
            Text(SavingText.detail(saving)).font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground).lineLimit(1)
        }
        .padding(12).frame(width: 220, alignment: .leading)
        .background(RunnirTheme.surface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(RunnirTheme.border))
        .accessibilityElement(children: .combine)
        .help(SavingText.help(saving))
    }
}

/// The words for one saving total on the Overview.
enum SavingText {
    static func title(_ saving: CoreSaving) -> String {
        switch saving.kind {
        case .localRuns: "Local runs"
        }
    }

    /// "42 min", "2 h", "3 h 12 min".
    static func amount(minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) min"
    }

    static func detail(_ saving: CoreSaving) -> String {
        switch saving.kind {
        case .localRuns: "GitHub Actions minutes · \(saving.count) \(saving.count == 1 ? "run" : "runs")"
        }
    }

    static func help(_ saving: CoreSaving) -> String {
        let since = saving.since.map { " Counted since \($0.formatted(date: .abbreviated, time: .omitted))." } ?? ""
        switch saving.kind {
        case .localRuns:
            return "What GitHub would have billed for the jobs of local runs that succeeded or failed on this Mac: "
                + "each job's time rounded up to a whole minute. Cancelled runs are not counted." + since
        }
    }
}
