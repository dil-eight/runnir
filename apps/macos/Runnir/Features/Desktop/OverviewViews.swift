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

    /// The jobs of a GitHub run that belong to one workflow job: the Core
    /// matches them by name (a matrix variant, a called workflow's job, a
    /// name set by an expression) and says which job each belongs to.
    static func runJobs(for job: CoreJob, in runJobs: [CoreRunJob]) -> [CoreRunJob] {
        runJobs.filter { $0.workflowJobID == job.id }
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

/// The Overview (S03): the pipeline of the branch's change in a scenario
/// (every workflow it starts, by lane), recent runs, presets to run by hand,
/// and what this Mac saved.
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
    /// The workflow to point at, kept by the window (the global search sets it).
    @Binding var selectedPath: String?
    /// The scenario and its plan, made once the Core is there.
    @State private var flow: ScenarioFlowModel?
    /// A job's log over the Overview, as on Runs, and the run it belongs to.
    @State private var logLayer: RunLayerModel?
    @State private var logRun: CoreWorkflowRun?

    /// GitHub could not be reached, so what is shown is the last data read.
    private var isStale: Bool {
        guard let session, session.githubLoadedAt != nil else { return false }
        switch session.githubAccess {
        case .unavailable, .rateLimited: return true
        default: return false
        }
    }

    /// What the plan depends on: the scenario picked, the files, the branch and the saved runs.
    private var flowKey: String {
        let workflows = (session?.workflows ?? []).map { "\($0.id):\($0.jobs.count):\($0.parseError ?? "")" }.joined(separator: ",")
        let newest = session?.runs.first.map { "\($0.id)-\($0.status)-\($0.updatedAt?.timeIntervalSince1970 ?? 0)" } ?? ""
        return [flow?.chosen?.title ?? "", session?.branch ?? "", workflows, newest, "\(session?.cachedRuns ?? 0)",
                "\(session?.phase == .ready)"].joined(separator: "|")
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if isStale, let session { staleBanner(session) }
                    if session?.githubRepository == nil || (session?.githubAccess != .ok && !isStale) {
                        GitHubLinkCard(repository: session?.githubRepository, coreReady: session?.phase == .ready, github: github,
                                       hub: hub, workspaceID: workspaceID)
                            .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
                    }
                    if files.files.isEmpty {
                        UnavailableFeature(title: files.isLoading ? "Reading workflows..." : "No workflows",
                                           detail: "Workflow files in .github/workflows of this working tree appear here.",
                                           symbol: "point.3.connected.trianglepath.dotted")
                    } else if let flow {
                        ScenarioFlowView(model: flow, session: session, hub: hub, favorites: favorites, selectedPath: selectedPath,
                                         openRun: openRun, openJob: openJob, openFile: { openFile(LocalWorkflowFile(relativePath: $0)) })
                            // Above the sections after it, which the scenario list may open over.
                            .zIndex(1)
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
            // The global search points at a workflow: its lane comes into view.
            .onChange(of: selectedPath, initial: true) { _, path in
                guard let path else { return }
                withAnimation { proxy.scrollTo(path, anchor: .center) }
            }
        }
        .overlay {
            if let logLayer, logLayer.isOpen, let logRun, let hub {
                RunLogLayer(model: logLayer, run: logRun, workspaceID: workspaceID, hub: hub)
            }
        }
        // The jobs of the open run, read again as it goes on, keep the layer current.
        .onChange(of: logRun.flatMap { flow?.jobs[$0.id] }) { _, jobs in
            if let jobs { logLayer?.apply(jobs: (jobs: jobs, stale: false)) }
        }
        .task(id: flowKey) {
            if flow == nil, let hub { flow = ScenarioFlowModel(hub: hub, workspaceID: workspaceID) }
            await flow?.load()
        }
        // The presets file is read on first use; reading it here keeps the
        // view from loading it while it draws.
        .task { presets.prepare() }
    }

    /// A job of a lane was clicked: its log opens over the Overview.
    private func openJob(_ run: CoreWorkflowRun, _ job: CoreRunJob, _ jobs: CoreGitHubResult<CoreRunJob>) {
        guard let hub else { return }
        let layer = logLayer ?? RunLayerModel(hub: hub, workspaceID: workspaceID)
        logLayer = layer
        layer.show(run: run.id)
        layer.apply(jobs: (jobs: jobs, stale: false))
        layer.open(job)
        logRun = session?.runs.first { $0.id == run.id } ?? run
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
