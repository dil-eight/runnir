import Foundation
import Observation

/// Starts a local run an MCP client asks for, as Run Locally does: the same
/// plan from the Core, the saved values, one run per workspace
/// (docs/superpowers/specs/2026-11-09-mcp-full-control-design.md). The user
/// is asked in the window only before macOS jobs run without the sandbox.
/// macOS jobs run only when the client names them.
@MainActor
struct McpLocalRunStarter {
    let hub: CoreHub
    let values: any LocalRunValueStoring
    /// The MCP request the run answers.
    let requestID: String
    let promptLifetime: Duration
    /// Claims the request in the Core before the run starts; false when its
    /// client no longer waits, so nothing starts.
    let claim: @MainActor () async -> Bool
    /// Shows the prompt in the window; false when another one shows.
    let show: (McpUnsandboxedPrompt) -> Bool
    /// Takes the prompt down, if it still shows.
    let hide: (McpUnsandboxedPrompt) -> Void

    static let gone = "The call stopped waiting before the run could start; nothing ran."

    func start(_ asked: CoreMcpLocalRunStart, client: String, workspace: WorkspaceRecord, windowID: UUID) async -> CoreMcpAnswer {
        if let current = hub.session(for: workspace.id)?.localRun, !current.isFinished {
            return .refusal("A local run of \(workspace.name) is still going (\(current.executionID)). "
                + "Wait for it with runnir_get_local_run, or stop it with runnir_stop_local_run.")
        }
        let review = LocalRunReviewModel(workspaceID: workspace.id, scenario: asked.scenario, hub: hub, values: values)
        await review.prepare()
        guard review.prepared != nil else { return .refusal(review.error ?? "Runnir Core did not plan the run.") }
        var named: Set<String> = []
        if !asked.workflows.isEmpty {
            switch Self.selection(asked.workflows, in: review.lanes) {
            case .success(let chosen):
                named = chosen.macOSJobs
                await review.select(chosen.selection)
            case .failure(let refusal): return .refusal(refusal.reason)
            }
            guard review.prepared != nil else { return .refusal(review.error ?? "Runnir Core did not plan the run.") }
        }
        if asked.macosWithoutSandbox {
            guard !review.hostJobs.isEmpty else {
                return .refusal("No macOS job is in this run, so there is nothing to run without the sandbox. Name the macOS jobs in workflows.")
            }
            await review.setUnsandboxed(true)
        }
        guard let plan = review.prepared?.plan else { return .refusal(review.error ?? "Runnir Core did not plan the run.") }
        if !plan.blockers.isEmpty {
            return .refusal("Runnir can't start this run: " + plan.blockers.joined(separator: " "))
        }
        let unnamed = plan.lanes.flatMap { lane in
            lane.jobs.filter { $0.selected && $0.support == .host && !named.contains(Self.key(lane.workflowID, $0.id)) }.map(\.id)
        }
        if !unnamed.isEmpty {
            return .refusal("This run would also run \(unnamed.joined(separator: ", ")) on this Mac. macOS jobs run only when named: name them in workflows.")
        }
        if !plan.lanes.contains(where: { $0.jobs.contains(where: \.selected) }) {
            return .refusal("Nothing in this scenario can run here. runnir_plan_scenario shows what it starts.")
        }
        if review.choosesEnvironment, let environment = asked.environment {
            guard let match = plan.environments.first(where: { $0.caseInsensitiveCompare(environment) == .orderedSame }) else {
                return .refusal("This run can take the values of \(plan.environments.joined(separator: ", ")) or the Repository's, not \(environment).")
            }
            await review.choose(match)
        }
        let missing = review.missing
        if !missing.isEmpty, !asked.allowMissingValues {
            let set = review.environment.map { "\($0) (or the Repository)" } ?? "the Repository"
            return .refusal("These values of the run are empty: \(missing.map(Self.name).joined(separator: ", ")). "
                + "Save them into \(set) with runnir_set_values, or pass allow_missing_values to run without them.")
        }
        if review.runsUnsandboxed {
            let prompt = McpUnsandboxedPrompt(requestID: requestID, client: client, workspace: workspace, windowID: windowID, jobs: plan.hostJobs)
            guard show(prompt) else { return .refusal("Runnir is already asking about another run; answer that first, then try again.") }
            let expiry = Task { [promptLifetime] in
                try? await Task.sleep(for: promptLifetime)
                if !Task.isCancelled { prompt.expire() }
            }
            let confirmed = await prompt.decision()
            expiry.cancel()
            hide(prompt)
            guard confirmed else { return .refusal(prompt.outcome ?? "Not run.") }
            guard await claim() else { return .refusal(Self.gone) }
            // The Core keeps a confirmation two minutes and the prompt waits
            // up to five: plan again for a fresh one, and run only the jobs
            // the user said yes to.
            await review.prepare()
            guard let fresh = review.prepared?.plan, fresh.blockers.isEmpty, fresh.hostUnsandboxed,
                  fresh.hostJobs == plan.hostJobs,
                  LocalRunTicks.selection(of: fresh.lanes) == LocalRunTicks.selection(of: plan.lanes) else {
                return .refusal(review.error ?? "The run changed while Runnir asked about it, so nothing ran. Ask again.")
            }
        }
        review.hostConfirmed = true
        review.trusted = true
        guard await claim() else { return .refusal(Self.gone) }
        guard let run = await review.run(startedBy: client) else { return .refusal(review.error ?? "The run did not start.") }
        let empty = Set(missing)
        return .started(CoreMcpLocalRunStarted(workspace: workspace.name, executionID: run.executionID,
                                               passed: review.runKeys.filter { !empty.contains($0) }.map(Self.name),
                                               empty: missing.map(Self.name), environment: review.environment))
    }

    /// "secrets.API_KEY" or "vars.REGION", as a workflow reads it.
    static func name(_ key: LocalRunValueKey) -> String {
        (key.kind == .secret ? "secrets." : "vars.") + key.name
    }

    /// A job as `macOSJobs` names it.
    static func key(_ workflowID: String, _ jobID: String) -> String { workflowID + "\u{1F}" + jobID }

    /// The ticks the client named: each workflow by path, file name or name;
    /// its jobs by id, or every job that can run here except macOS jobs and
    /// the jobs that need one. A named job that needs a macOS job the client
    /// did not name is refused. `macOSJobs` are the macOS jobs it named
    /// (`key`).
    static func selection(_ asked: [(workflow: String, jobs: [String])], in lanes: [CoreLocalRunLane])
        -> Result<(selection: CoreLocalRunSelection, macOSJobs: Set<String>), McpRefusal> {
        var selection = CoreLocalRunSelection()
        var macOSJobs: Set<String> = []
        for lane in lanes { selection.jobs[lane.workflowID] = [] }
        for entry in asked {
            let wanted = entry.workflow.trimmingCharacters(in: .whitespaces)
            let matches = lanes.filter {
                $0.workflowID == wanted || $0.workflowID == ".github/workflows/" + wanted
                    || URL(fileURLWithPath: $0.workflowID).lastPathComponent == wanted
                    || $0.workflowName.caseInsensitiveCompare(wanted) == .orderedSame
            }
            guard matches.count == 1, let lane = matches.first else {
                let all = lanes.map(\.workflowID).joined(separator: ", ")
                return .failure(McpRefusal(matches.isEmpty ? "No workflow matches \(wanted). The workspace's workflows: \(all)."
                                                           : "Several workflows match \(wanted); give the path."))
            }
            guard lane.parseError.isEmpty else { return .failure(McpRefusal("\(lane.workflowID) does not parse: \(lane.parseError)")) }
            let host = Set(lane.jobs.filter { $0.support == .host }.map(\.id))
            var ticks: Set<String> = []
            if entry.jobs.isEmpty {
                for job in lane.jobs where LocalRunTicks.tickable(job) && job.support != .host {
                    let brought = LocalRunTicks.tick(job.id, in: lane, [])
                    if brought.isDisjoint(with: host) { ticks.formUnion(brought) }
                }
                guard !ticks.isEmpty else {
                    return .failure(McpRefusal("No job of \(lane.workflowID) can run here without being named; macOS jobs, and the jobs that need one, run only when named."))
                }
            }
            for id in entry.jobs {
                guard let job = lane.jobs.first(where: { $0.id == id }) else {
                    return .failure(McpRefusal("\(lane.workflowID) has no job \(id). Its jobs: \(lane.jobs.map(\.id).joined(separator: ", "))."))
                }
                guard LocalRunTicks.tickable(job) else {
                    return .failure(McpRefusal("The job \(id) cannot run here: \(job.reason.isEmpty ? "act does not support it" : job.reason)"))
                }
                ticks = LocalRunTicks.tick(id, in: lane, ticks)
            }
            let unnamed = ticks.intersection(host).subtracting(entry.jobs).sorted()
            guard unnamed.isEmpty else {
                return .failure(McpRefusal("The jobs named need \(unnamed.joined(separator: ", ")), which \(unnamed.count == 1 ? "runs" : "run") on this Mac. "
                    + "macOS jobs run only when named: name \(unnamed.count == 1 ? "it" : "them") too."))
            }
            macOSJobs.formUnion(ticks.intersection(host).map { key(lane.workflowID, $0) })
            selection.jobs[lane.workflowID, default: []].formUnion(ticks)
        }
        return .success((selection, macOSJobs))
    }
}

/// An MCP client's run of macOS jobs without the sandbox, shown over the
/// workspace window until the user runs or cancels it, or it expires.
@MainActor
@Observable
final class McpUnsandboxedPrompt: Identifiable {
    let id = UUID()
    /// The MCP request it answers.
    let requestID: String
    let client: String
    let workspace: WorkspaceRecord
    let windowID: UUID
    /// "CI › build-ios".
    let jobs: [String]
    /// Why it did not run, once decided.
    private(set) var outcome: String?
    @ObservationIgnored private var decided: Bool?
    @ObservationIgnored private var continuation: CheckedContinuation<Bool, Never>?

    init(requestID: String, client: String, workspace: WorkspaceRecord, windowID: UUID, jobs: [String]) {
        self.requestID = requestID
        self.client = McpClientName.display(client)
        self.workspace = workspace
        self.windowID = windowID
        self.jobs = jobs
    }

    func run() { finish(true, nil) }

    func cancel() { finish(false, "Cancelled in Runnir; nothing ran.") }

    func expire() { finish(false, "Nobody answered in Runnir within 5 minutes; nothing ran.") }

    /// The client no longer waits: the question comes down.
    func withdraw() { finish(false, McpLocalRunStarter.gone) }

    /// Waits for Run, Cancel or the end of the prompt's life.
    func decision() async -> Bool {
        if let decided { return decided }
        return await withCheckedContinuation { continuation = $0 }
    }

    private func finish(_ run: Bool, _ outcome: String?) {
        guard decided == nil else { return }
        decided = run
        self.outcome = outcome
        continuation?.resume(returning: run)
        continuation = nil
    }
}
