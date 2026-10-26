import AppKit
import Foundation

/// How a job of the Overview pipeline is started by hand.
enum ManualJobStart: Equatable {
    /// The run waits for the user to approve a deployment; approving it lets
    /// the same run go on.
    case approve(runID: Int64, runNumber: Int64)
    /// The job runs only in a run started by hand: a new run of the workflow
    /// on `ref`, with the inputs the job's if fixes.
    case dispatch(workflowID: Int64, ref: String, inputs: [String: String])

    /// Which start, if any, a job's ▶ offers. A job of a run still going gets
    /// none, unless that run waits for this job's deployment to be approved.
    static func of(_ job: CoreJob, matched: [CoreRunJob], run: CoreWorkflowRun?, workflow: CoreGitHubWorkflow?) -> ManualJobStart? {
        guard let run else { return nil }
        if run.status == "waiting", matched.contains(where: { $0.status == "waiting" }) {
            return .approve(runID: run.id, runNumber: run.runNumber)
        }
        guard job.manual, let workflow, run.status == "completed", !run.branch.isEmpty else { return nil }
        return .dispatch(workflowID: workflow.id, ref: run.branch, inputs: job.manualInputs)
    }

    func buttonHelp(jobName: String) -> String {
        switch self {
        case .approve: "Approve the deployment so \(jobName) runs"
        case .dispatch: "Start \(jobName)"
        }
    }

    /// The inputs as the confirmation names them: "environment: production".
    static func describe(_ inputs: [String: String]) -> String {
        inputs.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
    }
}

/// Starts a manual job after the user confirms, and says what happened.
@MainActor
enum ManualJobRunner {
    /// Asks the question of a confirmation; true to go on.
    typealias Ask = @MainActor (_ title: String, _ detail: String, _ button: String) -> Bool

    static func start(_ start: ManualJobStart, jobName: String, workflowName: String, workspaceID: UUID, hub: CoreHub,
                      ask: Ask = ManualJobRunner.askInAlert,
                      confirmOwner: @MainActor (String) async -> OwnerConfirmation = { await OwnerConfirmation.ifEnabled(reason: $0) }) async -> String? {
        switch start {
        case .dispatch(let workflowID, let ref, let inputs):
            let with = inputs.isEmpty ? "" : " with \(ManualJobStart.describe(inputs))"
            guard ask("Run \(workflowName) on \(ref)?",
                      "\(jobName) runs in a new run of \(workflowName)\(with). Other inputs keep their defaults.", "Run") else { return nil }
            switch await confirmOwner("start \u{201C}\(workflowName)\u{201D} on \(ref)") {
            case .confirmed: break
            case .declined: return nil
            case .unavailable(let reason): return "Not started: manual runs are set to be confirmed with Touch ID, but this Mac can't ask. \(reason)"
            }
            let prepared = await hub.prepareDispatch(workspaceID: workspaceID, workflowID: workflowID, ref: ref, inputs: inputs)
            if prepared.access != .ok { return "Not started. " + DispatchFormModel.describe(prepared.access) }
            if !prepared.problems.isEmpty { return "Not started: " + prepared.problems.joined(separator: " ") }
            guard let dispatchID = prepared.dispatchID else { return "Not started." }
            guard let result = await hub.confirmDispatch(workspaceID: workspaceID, dispatchID: dispatchID) else {
                return "Not started: the confirmation expired. Try again."
            }
            if let rejection = result.rejection { return "GitHub refused to start \(workflowName): \(rejection)" }
            if result.access != .ok {
                return DispatchFormModel.describe(result.access) + " \(workflowName) may not have started; check Runs before trying again."
            }
            await hub.loadGitHubActivity(workspaceID: workspaceID)
            return "Started \(workflowName) on \(ref)\(with)."
        case .approve(let runID, let runNumber):
            let prepared = await hub.prepareRunAction(workspaceID: workspaceID, runID: runID, action: .approveDeployments)
            if prepared.access != .ok { return RunActionModel.describe(prepared.access) }
            if !prepared.problems.isEmpty { return prepared.problems.joined(separator: " ") }
            guard let actionID = prepared.actionID else { return nil }
            let environments = ListFormatter.localizedString(byJoining: prepared.environments)
            guard ask("Approve the deployment to \(environments)?",
                      "Run #\(runNumber) of \(workflowName) waits for it; \(jobName) and the jobs after it go on.", "Approve") else { return nil }
            guard let result = await hub.confirmRunAction(workspaceID: workspaceID, actionID: actionID) else {
                return "Not approved: the confirmation expired. Try again."
            }
            if let rejection = result.rejection { return "GitHub refused the approval: \(rejection)" }
            if result.access != .ok { return RunActionModel.describe(result.access) }
            await hub.loadGitHubActivity(workspaceID: workspaceID)
            return "Approved the deployment to \(environments); run #\(runNumber) goes on."
        }
    }

    static func askInAlert(title: String, detail: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
