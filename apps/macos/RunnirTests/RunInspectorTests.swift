import Foundation
import Testing
@testable import Runnir

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RunInspectorTests {
    private func run(status: String = "completed", conclusion: String? = "failure", attempt: Int64 = 1,
                     updated: Date = Date(timeIntervalSince1970: 1_000)) -> CoreWorkflowRun {
        CoreWorkflowRun(id: 21, workflowID: 1, name: "CI", displayTitle: "Fix build", runNumber: 1482, event: "push",
                        status: status, conclusion: conclusion, branch: "main", headSHA: "a3f9c21ffff", actor: "eugene",
                        htmlURL: nil, createdAt: Date(timeIntervalSince1970: 500), updatedAt: updated, runAttempt: attempt)
    }

    private func rig(runs: [CoreWorkflowRun]) async -> (CoreHub, FakeProvider, UUID) {
        let provider = FakeProvider()
        let hub = CoreHub(provider: provider)
        hub.startMonitoring()
        provider.ready()
        hub.runLookupInterval = .milliseconds(10)
        hub.runLookupTimeout = .milliseconds(300)
        provider.core.setRuns(CoreGitHubResult(access: .ok, items: runs), for: "/repo/linked")
        let workspace = UUID()
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/linked")
        _ = await eventually { hub.session(for: workspace)?.githubAccess == .ok }
        return (hub, provider, workspace)
    }

    private func line(_ number: Int64, _ text: String, _ kind: CoreLogLineKind = .plain, step: Int64) -> CoreLogLine {
        CoreLogLine(number: number, text: text, kind: kind, stepNumber: step)
    }

    @Test
    func aConfirmedReRunIsSentOnceAndFollowedUntilTheRunChanges() async {
        let finished = run()
        let (hub, provider, workspace) = await rig(runs: [finished])
        provider.core.preparedRun = finished
        let model = RunActionModel(hub: hub, workspaceID: workspace)

        await model.prepare(.rerunFailed, for: finished)
        #expect(model.pending?.action == .rerunFailed)
        #expect(provider.core.confirmedActions.isEmpty, "preparing must not send anything")

        // GitHub starts attempt 2: the next reload shows the run queued again.
        provider.core.setRuns(CoreGitHubResult(access: .ok, items: [run(status: "queued", conclusion: nil, attempt: 2)]), for: "/repo/linked")
        await model.confirm(current: finished)
        #expect(provider.core.confirmedActions == ["action_1"])
        #expect(model.phase == .requested(.rerunFailed))
        #expect(await eventually { model.phase == .idle })
        #expect(hub.session(for: workspace)?.runs.first?.runAttempt == 2)

        await model.confirm(current: finished)
        #expect(provider.core.confirmedActions == ["action_1"], "a used confirmation is not sent again")
    }

    @Test
    func problemsAndRefusalsAreShownAndNothingIsSent() async {
        let finished = run()
        let (hub, provider, workspace) = await rig(runs: [finished])
        let model = RunActionModel(hub: hub, workspaceID: workspace)

        provider.core.runActionProblems = ["Run #1482 already finished (failure), so it cannot be cancelled."]
        await model.prepare(.cancel, for: finished)
        #expect(model.phase == .failed("Run #1482 already finished (failure), so it cannot be cancelled."))
        #expect(model.pending == nil && provider.core.confirmedActions.isEmpty)

        model.dismiss()
        provider.core.runActionProblems = []
        provider.core.runActionRejection = "Cannot cancel a workflow run that is completed."
        await model.prepare(.cancel, for: finished)
        await model.confirm(current: finished)
        #expect(model.phase == .failed("GitHub refused: Cannot cancel a workflow run that is completed."))
        #expect(!model.isBusy)
    }

    @Test
    func anAcceptedActionWithoutAVisibleChangeEndsWithANotice() async {
        let active = run(status: "in_progress", conclusion: nil)
        let (hub, _, workspace) = await rig(runs: [active])
        let model = RunActionModel(hub: hub, workspaceID: workspace)
        await model.prepare(.cancel, for: active)
        await model.confirm(current: active)
        #expect(await eventually {
            if case .notice = model.phase { return true }
            return false
        })
    }

    @Test
    func confirmationTextNamesTheRunAndTheNextAttempt() {
        let text = RunActionModel.confirmation(for: .rerunFailed, run: run(attempt: 2))
        #expect(text.title == "Re-run failed jobs of run #1482?")
        #expect(text.message.contains("CI on main · a3f9c21"))
        #expect(text.message.contains("attempt 3"))
        #expect(RunActionModel.confirmation(for: .cancel, run: run()).button == "Cancel Run")
    }

    @Test
    func reRunningFailedJobsNeedsAFailedOrCancelledRun() {
        #expect(run(conclusion: "failure").canRerunFailedJobs)
        #expect(run(conclusion: "cancelled").canRerunFailedJobs)
        #expect(!run(conclusion: "success").canRerunFailedJobs)
        #expect(!run(status: "in_progress", conclusion: nil).canRerunFailedJobs)
    }

    @Test
    func theLogShowsOneStepWithoutGroupEndsAndSearchesIgnoringCase() {
        let log = [
            line(1, "Set up job", step: 1),
            line(2, "Run xcodebuild archive", .group, step: 4),
            line(3, "", .endGroup, step: 4),
            line(4, "error: Provisioning profile expired 2026-10-09", .error, step: 4),
            line(5, "** ARCHIVE FAILED **", step: 4),
            line(6, "Post job cleanup: profile", step: 6),
        ]
        let archive = LogFilter.lines(log, step: 4)
        #expect(archive.map(\.number) == [2, 4, 5])
        #expect(LogFilter.lines(log, step: nil).count == 5)
        #expect(LogFilter.matches(archive, query: "PROFILE expired") == [4])
        #expect(LogFilter.matches(log, query: "profile") == [4, 6])
        #expect(LogFilter.matches(log, query: "   ").isEmpty)
    }

    @Test
    func theFirstFailedJobAndStepOpenFirst() {
        let steps = [
            CoreRunStep(number: 1, name: "Set up job", status: "completed", conclusion: "success"),
            CoreRunStep(number: 4, name: "Archive", status: "completed", conclusion: "failure"),
            CoreRunStep(number: 5, name: "Upload", status: "completed", conclusion: "skipped"),
        ]
        let lint = CoreRunJob(id: 1, name: "lint", status: "completed", conclusion: "success", startedAt: nil, completedAt: nil, htmlURL: nil, steps: [])
        let build = CoreRunJob(id: 2, name: "build-ios", status: "completed", conclusion: "failure", startedAt: nil, completedAt: nil, htmlURL: nil, steps: steps)
        #expect(LogFilter.defaultJob([lint, build])?.id == 2)
        #expect(LogFilter.defaultJob([lint])?.id == 1)
        #expect(LogFilter.defaultStep(build) == 4)
        #expect(LogFilter.defaultStep(lint) == nil)
    }

    @Test
    func durationsAreShortAndNeverNegative() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(RunDuration.text(from: start, to: start.addingTimeInterval(281)) == "4m 41s")
        #expect(RunDuration.text(from: start, to: start.addingTimeInterval(-5)) == nil)
        #expect(RunDuration.text(from: nil, to: start) == nil)
    }

    @Test
    func hubPassesTheJobLogThrough() async {
        let (hub, provider, workspace) = await rig(runs: [run()])
        provider.core.jobLogResult = CoreJobLog(access: .ok, availability: .expired, lines: [], truncated: false)
        #expect(await hub.jobLog(workspaceID: workspace, jobID: 7).availability == .expired)
        #expect(await hub.jobLog(workspaceID: UUID(), jobID: 7).access == .unavailable)
    }
}
