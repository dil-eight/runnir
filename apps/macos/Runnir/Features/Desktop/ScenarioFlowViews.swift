import SwiftUI

/// The pipeline of the change on the Overview (S03): the scenario picker, a
/// row per workflow the scenario starts (its name, newest run and trigger on
/// the left, its jobs in columns by needs on the right), the chained ones
/// after their source, the workflows run by hand, and those not in the
/// scenario with the reason.
struct ScenarioFlowView: View {
    @Bindable var model: ScenarioFlowModel
    let session: RepositorySession?
    let hub: CoreHub?
    let favorites: WorkflowFavorites
    /// The workflow to point at, kept by the window: set by the global search.
    let selectedPath: String?
    let openRun: (CoreWorkflowRun) -> Void
    let openFile: (String) -> Void
    @State private var showingSkipped = true
    /// What starting a manual job did, by workflow path.
    @State private var manualMessages: [String: String] = [:]
    @State private var startingJobID: String?

    static let headerWidth: CGFloat = 300

    private var workspaceID: UUID { model.workspaceID }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 14)
            DesignDivider()
            content
        }
    }

    // MARK: Scenario

    private var header: some View {
        HStack(spacing: 14) {
            Menu {
                ForEach(ScenarioFlowModel.groups(model.flow?.scenarios ?? []), id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.scenarios, id: \.self) { scenario in
                            Button(scenario.title) { model.choose(scenario) }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(model.scenario?.title ?? "Scenario").font(.system(size: 15, weight: .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(RunnirTheme.secondaryForeground)
                }
            }
            .menuStyle(.button).buttonStyle(.plain).pointerStyle(.link).menuIndicator(.hidden).fixedSize()
            .disabled((model.flow?.scenarios ?? []).isEmpty)
            .help("What happens to this branch's change: a pull request, a push, a merge, a tag, a manual start, the schedule")
            .accessibilityLabel("Scenario")
            if let text = model.flow.flatMap({ ScenarioFlowModel.changesText($0.changes) }) {
                Text(text).font(.system(size: 13)).foregroundStyle(RunnirTheme.secondaryForeground).lineLimit(1)
            }
            Spacer(minLength: 8)
            if model.isLoading { ProgressView().controlSize(.small) }
        }
    }

    @ViewBuilder private var content: some View {
        if let flow = model.flow {
            if flow.scenario == nil {
                note("None of the workflows reacts to a pull request, a push, a tag, a manual start or the schedule.")
            }
            let scenarioLanes = flow.lanes.filter { $0.kind != .byHand }
            let byHand = flow.lanes.filter { $0.kind == .byHand }
            ForEach(scenarioLanes) { lane in
                laneRow(lane)
                DesignDivider()
            }
            if !byHand.isEmpty {
                runByHandRule.padding(.top, 18)
                ForEach(byHand) { lane in
                    laneRow(lane)
                    DesignDivider()
                }
            }
            if !flow.skipped.isEmpty { skipped(flow.skipped) }
            if flow.scenario != nil {
                Label("Statuses are the newest saved run of each workflow in this scenario; columns follow the jobs' needs in the working tree file.",
                      systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground).padding(.top, 12)
            }
        } else if model.unavailable {
            note("The scenario appears once Runnir Core has read this repository.")
        } else {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Planning the scenario\u{2026}") }
                .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground).padding(.vertical, 16)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground).padding(.vertical, 16)
    }

    // MARK: A lane

    private func laneRow(_ lane: CoreFlowLane) -> some View {
        HStack(alignment: .top, spacing: 24) {
            laneHeader(lane).frame(width: Self.headerWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal) { jobColumns(lane) }.scrollIndicators(.hidden)
                if let message = manualMessages[lane.path] {
                    Label(message, systemImage: "play.circle")
                        .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground).textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 16).padding(.horizontal, 8)
        .background(selectedPath == lane.path ? RunnirTheme.selected.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .id(lane.path)
    }

    private func laneHeader(_ lane: CoreFlowLane) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if lane.kind == .chained {
                Label("after \(lane.after)", systemImage: "arrow.turn.down.right")
                    .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(RunnirTheme.border))
                    .padding(.bottom, 2)
            }
            HStack(spacing: 6) {
                Button { openFile(lane.path) } label: {
                    Text(lane.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }
                .buttonStyle(.hit).help("Open \(lane.path) in the Workspace editor")
                let favorite = favorites.isFavorite(lane.path, workspaceID: workspaceID)
                Button { favorites.toggle(lane.path, workspaceID: workspaceID) } label: {
                    Image(systemName: favorite ? "star.fill" : "star").font(.system(size: 10))
                        .foregroundStyle(favorite ? RunnirTheme.warning : RunnirTheme.mutedForeground)
                }
                .buttonStyle(.hit).disabled(!favorites.isAvailable)
                .help(favorite ? "Remove from favorites" : "Add to favorites")
                .accessibilityLabel(favorite ? "Remove from favorites" : "Add to favorites")
            }
            statusLine(lane)
            Text(lane.why).font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground).lineLimit(2)
            if !lane.statusesFrom.isEmpty {
                Label("Statuses are from \(lane.statusesFrom), not the commit checked out", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(RunnirTheme.warning)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RunnirTheme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    .padding(.top, 4)
            }
            if !lane.parseError.isEmpty {
                Label("The file has a problem: \(lane.parseError)", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(RunnirTheme.warning).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func statusLine(_ lane: CoreFlowLane) -> some View {
        if let run = lane.run {
            Button { openRun(run) } label: {
                HStack(spacing: 5) {
                    RunOutcomeIcon(outcome: run.outcome, size: 11)
                    Text("\(run.outcome.label) #\(run.runNumber)")
                    if let created = run.createdAt {
                        Text("\u{00B7}")
                        Text(created, format: .relative(presentation: .named))
                    }
                }
                .font(.system(size: 12)).foregroundStyle(RunOutcomeIcon.color(run.outcome))
            }
            .buttonStyle(.hit).help("Open this run")
        } else {
            Label("Not run in this scenario yet", systemImage: "circle")
                .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
        }
    }

    // MARK: Jobs

    private func jobColumns(_ lane: CoreFlowLane) -> some View {
        let columns = ScenarioFlowModel.columns(lane.jobs)
        return HStack(alignment: .top, spacing: 10) {
            if columns.isEmpty {
                Text(lane.parseError.isEmpty ? "This workflow has no jobs." : "Jobs are not shown while the file has a problem.")
                    .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground).padding(.top, 8)
            }
            ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                if index > 0 {
                    Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(RunnirTheme.mutedForeground)
                        .padding(.top, 12).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(column) { job in node(job, lane: lane) }
                }
            }
        }
    }

    private func remote(_ path: String) -> CoreGitHubWorkflow? {
        session?.remoteWorkflows.first { $0.path == path }
    }

    private func node(_ job: CoreFlowJob, lane: CoreFlowLane) -> some View {
        let laneJobs = lane.jobs.map(\.job)
        let read = lane.run.flatMap { model.jobs[$0.id] }
        let matched = read.map { PipelineLayout.runJobs(for: job.job, in: $0.items, among: laneJobs) } ?? []
        let outcome = job.skipped.isEmpty ? PipelineLayout.outcome(matched) : nil
        let workflow = remote(lane.path)
        let workflowRuns = workflow.map { remote in session?.runs.filter { $0.workflowID == remote.id } ?? [] } ?? []
        let start = session?.githubAccess == .ok && job.skipped.isEmpty
            ? ManualJobStart.of(job.job, matched: matched, run: lane.run, workflowRuns: workflowRuns, workflow: workflow,
                                defaultBranch: session?.githubDetails?.defaultBranch) : nil
        return HStack(spacing: 8) {
            if !job.skipped.isEmpty {
                Image(systemName: "minus.circle").font(.system(size: 12)).foregroundStyle(RunnirTheme.mutedForeground)
                    .accessibilityLabel("Does not run in this scenario")
            } else if let outcome {
                RunOutcomeIcon(outcome: outcome, size: 12)
            } else {
                Image(systemName: "circle").font(.system(size: 12)).foregroundStyle(RunnirTheme.mutedForeground)
                    .accessibilityLabel("Not run")
            }
            if !job.environment.isEmpty {
                Image(systemName: "hand.raised").font(.system(size: 10)).foregroundStyle(RunnirTheme.secondaryForeground)
                    .accessibilityLabel("Deploys to \(job.environment)")
            }
            Text(ScenarioFlowModel.title(job)).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 10)
            if let start {
                manualButton(start, job: job, lane: lane)
            } else {
                TimelineView(.periodic(from: .now, by: outcome == .running ? 1 : 3600)) { context in
                    if let duration = PipelineLayout.duration(matched, now: context.date) {
                        Text(PipelineLayout.format(duration)).font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                    }
                }
            }
        }
        .padding(.horizontal, 12).frame(width: 200, height: 36)
        .background(RunnirTheme.surface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(outline(job, outcome: outcome),
                                                            style: StrokeStyle(lineWidth: 1, dash: job.condition.isEmpty ? [] : [4, 3])))
        .opacity(job.skipped.isEmpty ? 1 : 0.5)
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .clickable().onTapGesture { if let run = lane.run { openRun(run) } }
        .help(hint(job, matched: matched, read: read, start: start))
    }

    private func outline(_ job: CoreFlowJob, outcome: CoreRunOutcome?) -> Color {
        if outcome == .failed { return RunnirTheme.destructive }
        if !job.condition.isEmpty { return RunnirTheme.secondaryForeground.opacity(0.6) }
        return RunnirTheme.border
    }

    private func hint(_ job: CoreFlowJob, matched: [CoreRunJob], read: CoreGitHubResult<CoreRunJob>?, start: ManualJobStart?) -> String {
        if !job.skipped.isEmpty { return "Does not run in this scenario: \(job.skipped)" }
        var lines: [String] = []
        if !job.condition.isEmpty { lines.append("Depends on a condition: \(job.condition)") }
        if !job.environment.isEmpty { lines.append("Deploys to \(job.environment); GitHub may wait for an approval") }
        if !job.uses.isEmpty { lines.append("Calls \(job.uses)") }
        lines.append(PipelineLayout.hint(for: job.job, matched: matched, readFailed: read.map { $0.access != .ok } ?? false, now: Date(), start: start))
        return lines.joined(separator: "\n")
    }

    private func manualButton(_ start: ManualJobStart, job: CoreFlowJob, lane: CoreFlowLane) -> some View {
        let name = ScenarioFlowModel.title(job)
        return Button {
            guard let hub, startingJobID == nil else { return }
            startingJobID = job.id
            Task {
                if let message = await ManualJobRunner.start(start, jobName: name, workflowName: lane.name, workspaceID: workspaceID, hub: hub) {
                    manualMessages[lane.path] = message
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
        .help(start.buttonHelp(jobName: name))
        .accessibilityLabel(start.buttonHelp(jobName: name))
    }

    // MARK: Run by hand, and what the scenario leaves out

    private var runByHandRule: some View {
        HStack(spacing: 10) {
            Text("RUN BY HAND").font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(RunnirTheme.secondaryForeground)
            Text("started manually, outside the scenario").font(.system(size: 12)).foregroundStyle(RunnirTheme.mutedForeground)
            Rectangle().fill(RunnirTheme.border).frame(height: 1)
        }
    }

    private func skipped(_ workflows: [CoreSkippedWorkflow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { showingSkipped.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(showingSkipped ? 90 : 0))
                    Text("Not in this scenario (\(workflows.count))").font(.system(size: 13))
                }
                .foregroundStyle(RunnirTheme.secondaryForeground).padding(.vertical, 12).contentShape(Rectangle())
            }
            .buttonStyle(.hit)
            if showingSkipped {
                ForEach(workflows) { workflow in
                    HStack(alignment: .firstTextBaseline, spacing: 24) {
                        Button { openFile(workflow.path) } label: {
                            Text(workflow.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        }
                        .buttonStyle(.hit).help("Open \(workflow.path) in the Workspace editor")
                        .padding(.leading, 18).frame(width: Self.headerWidth, alignment: .leading)
                        Text(workflow.reason).font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8).padding(.horizontal, 8)
                    DesignDivider()
                }
            }
        }
        .padding(.top, 6)
    }
}
