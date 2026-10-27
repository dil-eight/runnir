import Foundation

/// The Overview's scenario (S03, B31): the pipeline of the change as the
/// Core plans it, the scenario picked, and the jobs of each lane's run.
@MainActor
@Observable
final class ScenarioFlowModel {
    let workspaceID: UUID
    @ObservationIgnored private let hub: CoreHub
    private(set) var flow: CoreFlow?
    private(set) var isLoading = false
    /// The Core did not answer the last request.
    private(set) var unavailable = false
    /// The scenario picked; nil is the Core's default.
    private(set) var chosen: CoreScenario?
    /// The jobs of each lane's run, by run id.
    private(set) var jobs: [Int64: CoreGitHubResult<CoreRunJob>] = [:]
    /// Which report of a run its jobs were read for, by run id.
    @ObservationIgnored private var jobsRead: [Int64: String] = [:]

    init(hub: CoreHub, workspaceID: UUID) {
        self.hub = hub
        self.workspaceID = workspaceID
    }

    /// The scenario shown: the one picked, else the default the Core planned.
    var scenario: CoreScenario? { flow?.scenario ?? chosen }

    func choose(_ scenario: CoreScenario) {
        chosen = scenario
    }

    /// Plans the scenario again (the files, the runs or the pick changed) and
    /// reads the jobs of runs that are new or changed.
    func load() async {
        isLoading = true
        let result = await hub.flow(workspaceID: workspaceID, scenario: chosen)
        isLoading = false
        guard let result else {
            unavailable = true
            return
        }
        unavailable = false
        flow = result
        await loadJobs(result.lanes.compactMap(\.run))
    }

    private func loadJobs(_ runs: [CoreWorkflowRun]) async {
        let wanted = runs.filter { jobsRead[$0.id] != Self.report($0) }
        guard !wanted.isEmpty else { return }
        let hub = self.hub
        let workspaceID = self.workspaceID
        let read = await withTaskGroup(of: (CoreWorkflowRun, CoreGitHubResult<CoreRunJob>).self) { group in
            for run in wanted {
                group.addTask { (run, await hub.jobs(workspaceID: workspaceID, runID: run.id)) }
            }
            var out: [(CoreWorkflowRun, CoreGitHubResult<CoreRunJob>)] = []
            for await item in group { out.append(item) }
            return out
        }
        for (run, result) in read {
            jobs[run.id] = result
            jobsRead[run.id] = Self.report(run)
        }
    }

    private static func report(_ run: CoreWorkflowRun) -> String {
        "\(run.runAttempt)-\(run.status)-\(run.updatedAt?.timeIntervalSince1970 ?? 0)"
    }

    // MARK: What the view shows

    /// A lane's jobs in columns by their needs, as the Core laid them out.
    static func columns(_ jobs: [CoreFlowJob]) -> [[CoreFlowJob]] {
        guard let last = jobs.map(\.column).max() else { return [] }
        var columns = Array(repeating: [CoreFlowJob](), count: last + 1)
        for job in jobs { columns[max(0, job.column)].append(job) }
        return columns.filter { !$0.isEmpty }
    }

    /// The node's title: its name, the matrix size, ×n for one only a run knows.
    static func title(_ job: CoreFlowJob) -> String {
        let name = job.name.isEmpty || job.name.contains("${{") ? job.id : job.name
        switch job.matrix {
        case 2...: return "\(name) ×\(job.matrix)"
        case -1: return "\(name) ×n"
        default: return name
        }
    }

    /// The line beside the scenario: what the paths filters were read against.
    static func changesText(_ changes: CoreFlowChanges) -> String? {
        guard changes.applies else { return nil }
        guard changes.known else { return changes.note.isEmpty ? nil : changes.note }
        let files = changes.count == 1 ? "1 file" : "\(changes.count) files"
        return "\(files) changed against \(changes.against)"
    }

    /// Scenarios grouped as the picker lists them.
    static func groups(_ scenarios: [CoreScenario]) -> [(title: String, scenarios: [CoreScenario])] {
        let order: [(CoreScenario.Kind, String)] = [(.pullRequest, "Pull request"), (.push, "Push"), (.merge, "Merge into"),
                                                    (.tag, "Tag"), (.manual, "Manual"), (.schedule, "Schedule")]
        return order.compactMap { kind, title in
            let items = scenarios.filter { $0.kind == kind }
            return items.isEmpty ? nil : (title, items)
        }
    }
}
