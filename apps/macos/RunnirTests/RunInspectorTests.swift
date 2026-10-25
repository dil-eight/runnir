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
    func aTakenConfirmationIsSentEvenIfTheDialogClosesFirst() async {
        let finished = run()
        let (hub, provider, workspace) = await rig(runs: [finished])
        let model = RunActionModel(hub: hub, workspaceID: workspace)
        await model.prepare(.rerun, for: finished)

        // The dialog button takes the confirmation synchronously; closing
        // the dialog right after must not discard it.
        let confirmed = model.takeConfirmation()
        #expect(confirmed?.action == .rerun)
        #expect(model.pending == nil)
        model.dismiss()
        #expect(model.takeConfirmation() == nil, "a confirmation is taken once")
        if let confirmed { await model.send(confirmed, current: finished) }
        #expect(provider.core.confirmedActions == ["action_1"])
    }

    @Test
    func aCancelIsFollowedUntilTheRunFinishesNotJustUntilItUpdates() async {
        let active = run(status: "in_progress", conclusion: nil, updated: Date(timeIntervalSince1970: 1_000))
        let (hub, provider, workspace) = await rig(runs: [active])
        // Jobs progressing change updated_at while the run keeps going.
        provider.core.setRuns(CoreGitHubResult(access: .ok, items: [run(status: "in_progress", conclusion: nil, updated: Date(timeIntervalSince1970: 1_050))]), for: "/repo/linked")
        #expect(await hub.followRunChange(workspaceID: workspace, from: active, action: .cancel) == nil)
        provider.core.setRuns(CoreGitHubResult(access: .ok, items: [run(status: "completed", conclusion: "cancelled", updated: Date(timeIntervalSince1970: 1_090))]), for: "/repo/linked")
        #expect(await hub.followRunChange(workspaceID: workspace, from: active, action: .cancel)?.conclusion == "cancelled")
    }

    @Test
    func aReRunShowsAsANewAttemptOrAnActiveRun() {
        let before = run(attempt: 1)
        #expect(!CoreHub.runShows(.rerunFailed, before: before, now: run(attempt: 1, updated: Date())))
        #expect(CoreHub.runShows(.rerunFailed, before: before, now: run(conclusion: "success", attempt: 2)))
        #expect(CoreHub.runShows(.rerun, before: before, now: run(status: "queued", conclusion: nil)))
        #expect(!CoreHub.runShows(.cancel, before: run(status: "in_progress", conclusion: nil), now: run(status: "in_progress", conclusion: nil, updated: Date())))
    }

    @Test
    func leavingTheRunStopsFollowingIt() async {
        let finished = run()
        let (hub, provider, workspace) = await rig(runs: [finished])
        hub.runLookupTimeout = .seconds(30)
        let model = RunActionModel(hub: hub, workspaceID: workspace)
        await model.prepare(.rerun, for: finished)
        await model.confirm(current: finished) // the run never changes
        #expect(model.phase == .requested(.rerun))
        model.stopFollowing()
        #expect(model.phase == .idle)
        try? await Task.sleep(for: .milliseconds(50))
        let calls = provider.core.runsCalls.count
        try? await Task.sleep(for: .milliseconds(150))
        #expect(provider.core.runsCalls.count == calls, "no more reloads after leaving")
    }

    @Test
    func aFailedReloadKeepsTheJobsShown() {
        let job = CoreRunJob(id: 1, name: "build", status: "in_progress", conclusion: nil, startedAt: nil, completedAt: nil, htmlURL: nil, steps: [])
        let loaded = CoreGitHubResult(access: .ok, items: [job])
        let limited = CoreGitHubResult<CoreRunJob>(access: .rateLimited(until: nil), items: [])
        let kept = LogFilter.reloadedJobs(previous: loaded, new: limited)
        #expect(kept.jobs == loaded && kept.stale)
        let first = LogFilter.reloadedJobs(previous: nil, new: limited)
        #expect(first.jobs == limited && !first.stale, "with nothing shown yet, the problem is shown")
        let fresh = LogFilter.reloadedJobs(previous: loaded, new: CoreGitHubResult(access: .ok, items: []))
        #expect(fresh.jobs.items.isEmpty && !fresh.stale)
    }

    @Test
    func readProblemsDoNotTalkAboutWriteAccess() {
        #expect(!RunActionModel.describeRead(.notVisible).contains("write"))
        // Not reaching the repository and lacking a permission are told apart.
        #expect(RunActionModel.describe(.notVisible).contains("Give Runnir Desktop access"))
        #expect(RunActionModel.describe(.permissionMissing).contains("lacks a permission"))
        #expect(RunActionModel.describeRead(.signedOut) == "Connect GitHub to see jobs and logs.")
        #expect(RunActionModel.describe(.tokenRejected).contains("Sign in again"))
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
        #expect(run(conclusion: "timed_out").canRerunFailedJobs)
        #expect(!run(conclusion: "startup_failure").canRerunFailedJobs, "a startup failure has no jobs to re-run")
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
    func theViewerShowsTheLast100LinesAndSaysHowManyThereAre() {
        let log = (19_204...21_776).map { line(Int64($0), "line \($0)", step: 2) }
        let shown = LogFilter.tail(log)
        #expect(shown.count == 100 && shown.first?.number == 21_677 && shown.last?.number == 21_776)
        #expect(LogFilter.scope(shown: 100, selected: log.count, lastNumber: 21_776, truncated: true, step: nil) == "Last 100 of \(21_776.formatted()) lines")
        #expect(LogFilter.scope(shown: 100, selected: 340, lastNumber: 21_776, truncated: false, step: "Archive") == "Last 100 of 340 lines · Archive")
        #expect(LogFilter.scope(shown: 100, selected: 340, lastNumber: 21_776, truncated: true, step: "Archive") == "Last 100 lines · Archive",
                "a step's earlier lines may be before what the Core read")
        #expect(LogFilter.scope(shown: 40, selected: 40, lastNumber: 40, truncated: false, step: nil) == nil, "a short log is shown whole")
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
