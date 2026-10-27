import SwiftUI

// MARK: Graph of a run

/// A run drawn as its workflow file draws it: the jobs in the order they
/// run, each with the jobs GitHub ran for it. Pure, so it can be tested.
enum RunGraph {
    struct Node: Identifiable, Equatable {
        /// The workflow job's id.
        let id: String
        let name: String
        /// The jobs of the run that belong to it: several for a matrix.
        let jobs: [CoreRunJob]

        var title: String { jobs.count > 1 ? "\(name) ×\(jobs.count)" : name }
        var outcome: CoreRunOutcome? { PipelineLayout.outcome(jobs) }
    }

    struct Layout: Equatable {
        var columns: [[Node]]
        /// Jobs of the run that no job of the file claims: those of a called
        /// workflow with another name, or named by an expression.
        var others: [CoreRunJob]
    }

    /// nil without jobs from the file: the run is then listed as GitHub gives it.
    static func layout(workflow: [CoreJob], runJobs: [CoreRunJob]) -> Layout? {
        guard !workflow.isEmpty else { return nil }
        var claimed = Set<Int64>()
        var nodes: [String: Node] = [:]
        for job in workflow {
            let matched = PipelineLayout.runJobs(for: job, in: runJobs, among: workflow)
            matched.forEach { claimed.insert($0.id) }
            // A name set by an expression has no text to show before the run.
            let name = job.name.isEmpty || job.name.contains("${{") ? job.id : job.name
            nodes[job.id] = Node(id: job.id, name: name, jobs: matched)
        }
        let columns = PipelineLayout.columns(workflow).map { column in column.compactMap { nodes[$0.id] } }
        return Layout(columns: columns, others: runJobs.filter { !claimed.contains($0.id) })
    }

    /// What a job without a run job of its own is: still to come while the
    /// run goes on, otherwise it did not run.
    static func absentOutcome(runActive: Bool) -> CoreRunOutcome { runActive ? .queued : .skipped }

    /// The job a click on a node opens: its first failed one, else its first.
    static func jobToOpen(_ node: Node) -> CoreRunJob? {
        node.jobs.first { $0.outcome == .failed } ?? node.jobs.first
    }

    /// Where a run stands, for the line under the graph: the first failed
    /// job and step of a run that failed, or the job and step in progress.
    static func focus(_ jobs: [CoreRunJob], runActive: Bool) -> (job: CoreRunJob, step: CoreRunStep?, failed: Bool)? {
        if runActive {
            guard let job = jobs.first(where: { $0.outcome == .running }) ?? jobs.first(where: { $0.outcome == .queued }) else { return nil }
            return (job, job.steps.first { $0.outcome == .running }, false)
        }
        guard let job = jobs.first(where: { $0.outcome == .failed }) else { return nil }
        return (job, job.steps.first { $0.outcome == .failed }, true)
    }
}

// MARK: The layer's state

/// What the run inspector and the log layer over it share: the jobs and the
/// workflow file of the run shown, and whether a job's log is open.
@MainActor
@Observable
final class RunLayerModel {
    private(set) var runID: Int64?
    var jobs: CoreGitHubResult<CoreRunJob>?
    var jobsStale = false
    var workflow: CoreRunWorkflow?
    var isOpen = false
    /// The layer fills the whole section instead of floating over it.
    var expanded = false
    var jobID: Int64?
    var step: Int64?
    /// Cancel and re-run, which the inspector's buttons and the jobs' re-run buttons share.
    let actions: RunActionModel

    init(hub: CoreHub, workspaceID: UUID) {
        actions = RunActionModel(hub: hub, workspaceID: workspaceID)
    }

    var selectedJob: CoreRunJob? { jobs?.items.first { $0.id == jobID } }

    /// A run was selected: nothing of the one before stays loaded or open.
    func show(run id: Int64) {
        guard runID != id else { return }
        runID = id
        jobs = nil
        jobsStale = false
        workflow = nil
        jobID = nil
        step = nil
        isOpen = false
        expanded = false
    }

    func open(_ job: CoreRunJob, step: Int64? = nil) {
        jobID = job.id
        self.step = step ?? LogFilter.defaultStep(job)
        isOpen = true
    }

    func close() {
        isOpen = false
        expanded = false
    }

    /// A reload of the jobs keeps what is open when the job is still there.
    func apply(jobs reloaded: (jobs: CoreGitHubResult<CoreRunJob>, stale: Bool)) {
        jobs = reloaded.jobs
        jobsStale = reloaded.stale
        if !reloaded.jobs.items.contains(where: { $0.id == jobID }) {
            jobID = nil
            step = nil
            if isOpen { close() }
        }
    }
}

// MARK: The graph in the inspector

struct RunGraphView: View {
    @Bindable var model: RunLayerModel
    let run: CoreWorkflowRun

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 20) {
                header
                content
                focusLine
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let path = model.workflow?.path, !path.isEmpty {
                Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 13, weight: .semibold))
            } else {
                Text(run.name).font(.system(size: 13, weight: .semibold))
            }
            Text("at \(run.headSHA.prefix(7))\(jobCount)").font(.system(size: 12)).foregroundStyle(RunnirTheme.mutedForeground)
            Spacer(minLength: 8)
            Text("Select a job to read its log").font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
        }
    }

    private var jobCount: String {
        guard let count = model.jobs?.items.count, count > 0 else { return "" }
        return " · \(count) \(count == 1 ? "job" : "jobs")"
    }

    @ViewBuilder private var content: some View {
        switch model.jobs {
        case nil:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading jobs...") }
                .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
        case .some(let result) where result.access != .ok:
            Text(RunActionModel.describeRead(result.access))
                .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
        case .some(let result) where result.items.isEmpty:
            Text("This run has no jobs yet.").font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
        case .some(let result):
            if let workflow = model.workflow, workflow.access == .ok,
               let layout = RunGraph.layout(workflow: workflow.jobs, runJobs: result.items) {
                graph(layout)
            } else {
                flatList(result.items)
            }
            if model.jobsStale {
                Label("Could not reload from GitHub; showing the last jobs.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
            }
        }
    }

    private func graph(_ layout: RunGraph.Layout) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 8) {
                ForEach(Array(layout.columns.enumerated()), id: \.offset) { index, column in
                    if index > 0 {
                        Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(RunnirTheme.mutedForeground)
                    }
                    VStack(spacing: 8) {
                        ForEach(column) { node in nodeButton(node) }
                    }
                }
            }
            if !layout.others.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(title: "OTHER JOBS")
                    ForEach(layout.others) { job in jobNode(title: job.name, outcome: job.outcome, jobs: [job]) }
                }
            }
        }
    }

    /// The jobs as GitHub lists them, for a run whose workflow file could not
    /// be read at its commit, with the reason.
    private func flatList(_ items: [CoreRunJob]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let workflow = model.workflow {
                Label(workflow.problem.isEmpty
                      ? "Jobs are listed without their order: the workflow file could not be read at this commit."
                      : "Jobs are listed without their order. \(workflow.problem)", systemImage: "info.circle")
                    .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items) { job in jobNode(title: job.name, outcome: job.outcome, jobs: [job]) }
            }
        }
    }

    private func nodeButton(_ node: RunGraph.Node) -> some View {
        jobNode(title: node.title, outcome: node.outcome ?? RunGraph.absentOutcome(runActive: run.outcome.isActive), jobs: node.jobs)
    }

    private func jobNode(title: String, outcome: CoreRunOutcome, jobs: [CoreRunJob]) -> some View {
        let target = jobs.first { $0.outcome == .failed } ?? jobs.first
        return Button {
            if let target { model.open(target) }
        } label: {
            HStack(spacing: 8) {
                RunOutcomeIcon(outcome: outcome, size: 14)
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 6)
                Text(meta(outcome, jobs)).font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
            }
            .padding(.horizontal, 12).frame(width: 220, height: 36)
            .background(RunnirTheme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(outlineColor(outcome, selected: model.jobID != nil && jobs.contains { $0.id == model.jobID })))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.hit)
        .disabled(target == nil)
        .help(target == nil ? "This job has not started" : "Read the log of \(title)")
        .accessibilityLabel("\(title), \(outcome.label)")
        .contextMenu {
            if let target, !run.outcome.isActive, target.status == "completed" {
                Button("Re-run job") { Task { await model.actions.prepare(.rerunJob(id: target.id), for: run) } }
                    .disabled(model.actions.isBusy)
            }
        }
    }

    private func outlineColor(_ outcome: CoreRunOutcome, selected: Bool) -> Color {
        if selected { return RunnirTheme.primary }
        switch outcome {
        case .failed: return RunnirTheme.destructive
        case .running: return RunnirTheme.primary.opacity(0.7)
        default: return RunnirTheme.border
        }
    }

    private func meta(_ outcome: CoreRunOutcome, _ jobs: [CoreRunJob]) -> String {
        switch outcome {
        case .queued: return "waiting"
        case .skipped: return "skipped"
        case .running:
            return PipelineLayout.duration(jobs, now: Date()).map(PipelineLayout.format) ?? "running"
        default:
            return PipelineLayout.duration(jobs, now: Date()).map(PipelineLayout.format) ?? ""
        }
    }

    /// Under the graph: where the run failed, or where it is now, with the
    /// way into that log.
    @ViewBuilder private var focusLine: some View {
        if let items = model.jobs?.items,
           let focus = RunGraph.focus(items, runActive: run.outcome.isActive) {
            HStack(spacing: 12) {
                Image(systemName: focus.failed ? "xmark.circle.fill" : "arrow.triangle.2.circlepath")
                    .foregroundStyle(focus.failed ? RunnirTheme.destructive : RunnirTheme.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(focus.failed ? "Failed" : "Running") in \(focus.job.name)\(focus.step.map { " › \($0.name)" } ?? "")")
                        .font(.system(size: 13, weight: .semibold))
                    if run.outcome.isActive {
                        Text("The log follows the run.").font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                    }
                }
                Spacer(minLength: 8)
                Button(focus.failed ? "Open the log" : "Follow the log") { model.open(focus.job, step: focus.step?.number) }
                    .buttonStyle(DesignButtonStyle())
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background((focus.failed ? RunnirTheme.destructive : RunnirTheme.primary).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: 640)
        }
    }
}

// MARK: The log layer

/// A job's steps and log in a layer over the runs list and the graph: it
/// floats over the dimmed section, can be expanded to fill it, and closes
/// with its button, Escape or a click outside.
struct RunLogLayer: View {
    @Bindable var model: RunLayerModel
    let run: CoreWorkflowRun
    let workspaceID: UUID
    let hub: CoreHub

    var body: some View {
        ZStack {
            if !model.expanded {
                // No hand pointer: a click outside the layer closes it.
                Color.black.opacity(0.45).onTapGesture { model.close() }
            }
            sheet.padding(model.expanded ? 0 : 28)
            // Escape closes the layer.
            Button("Close the log") { model.close() }
                .keyboardShortcut(.cancelAction).buttonStyle(.hit).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
    }

    private var sheet: some View {
        HStack(spacing: 0) {
            jobList.frame(width: 260)
            DesignDivider(vertical: true)
            if let job = model.selectedJob {
                JobLogView(job: job, step: model.step, workspaceID: workspaceID, hub: hub,
                           showWholeJob: { model.step = nil },
                           layer: LogLayerControls(expanded: model.expanded,
                                                   toggleExpanded: { model.expanded.toggle() }, close: { model.close() }))
                    .id(job.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(RunnirTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: model.expanded ? 0 : 12))
        .overlay(RoundedRectangle(cornerRadius: model.expanded ? 0 : 12).stroke(RunnirTheme.border))
        .shadow(color: .black.opacity(model.expanded ? 0 : 0.4), radius: 24, y: 10)
    }

    // MARK: Jobs and steps

    private var jobList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if let items = model.jobs?.items {
                    ForEach(items) { job in
                        jobRow(job)
                        if job.id == model.jobID {
                            ForEach(job.steps) { step in stepRow(step) }
                        }
                    }
                }
            }
            .padding(8)
        }
        .background(RunnirTheme.sidebar.opacity(0.5))
    }

    private func canRerun(_ job: CoreRunJob) -> Bool {
        !run.outcome.isActive && job.status == "completed"
    }

    private func rerun(_ job: CoreRunJob) {
        Task { await model.actions.prepare(.rerunJob(id: job.id), for: run) }
    }

    private func jobRow(_ job: CoreRunJob) -> some View {
        HStack(spacing: 2) {
            Button {
                if model.jobID == job.id {
                    model.step = nil
                } else {
                    model.jobID = job.id
                    model.step = LogFilter.defaultStep(job)
                }
            } label: {
                HStack(spacing: 8) {
                    RunOutcomeIcon(outcome: job.outcome, size: 13)
                    Text(job.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(timing(job.outcome, from: job.startedAt, to: job.completedAt))
                        .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                }
                .padding(.horizontal, 8).frame(maxWidth: .infinity).frame(height: 30).contentShape(Rectangle())
                .background(job.id == model.jobID && model.step == nil ? RunnirTheme.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.hit)
            .help(job.id == model.jobID ? "Show the whole job log" : "Show this job")
            if canRerun(job) {
                Button { rerun(job) } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.hit).disabled(model.actions.isBusy)
                .help("Re-run this job and the jobs that need it")
                .accessibilityLabel("Re-run job \(job.name)")
            }
        }
        .contextMenu {
            if canRerun(job) { Button("Re-run job") { rerun(job) }.disabled(model.actions.isBusy) }
        }
    }

    private func stepRow(_ step: CoreRunStep) -> some View {
        Button { model.step = step.number } label: {
            HStack(spacing: 8) {
                RunOutcomeIcon(outcome: step.outcome, size: 11)
                Text(step.name).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 6)
                Text(timing(step.outcome, from: step.startedAt, to: step.completedAt))
                    .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
            }
            .padding(.leading, 28).padding(.trailing, 8).frame(height: 26).contentShape(Rectangle())
            .background(step.number == model.step ? RunnirTheme.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.hit)
    }

    private func timing(_ outcome: CoreRunOutcome, from start: Date?, to end: Date?) -> String {
        switch outcome {
        case .running: "running"
        case .queued: "queued"
        case .skipped: "skipped"
        default: RunDuration.text(from: start, to: end) ?? ""
        }
    }
}

/// The layer's own controls in the log's header.
struct LogLayerControls {
    let expanded: Bool
    let toggleExpanded: () -> Void
    let close: () -> Void
}
