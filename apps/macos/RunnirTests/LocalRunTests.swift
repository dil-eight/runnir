import Foundation
import Testing
@testable import Runnir

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LocalRunTests {
    private func plan(blockers: [String] = []) -> CoreLocalRunPlan {
        CoreLocalRunPlan(workflowID: ".github/workflows/ci.yml", workflowName: "CI", events: ["push", "workflow_dispatch"], event: "push",
                         jobID: "lint",
                         jobs: [CoreLocalRunJob(id: "lint", runsOn: ["ubuntu-latest"], image: "catthehacker/ubuntu:act-latest", support: .supported),
                                CoreLocalRunJob(id: "ios", runsOn: ["macos-latest"], support: .unsupported, reason: "Not supported locally: macOS runner")],
                         blockers: blockers, cpus: 4, memoryBytes: 8 << 30, timeoutSeconds: 1800,
                         actVersion: "0.2.89", engineName: "OrbStack", engineContext: "orbstack")
    }

    private func prepared(confirmation: String? = "local_1", blockers: [String] = []) -> CorePreparedLocalRun {
        CorePreparedLocalRun(readiness: FakeCore.readyTools, plan: plan(blockers: blockers), confirmationID: confirmation, expiresAt: Date())
    }

    private func output(lines: ClosedRange<UInt64>?, phase: CoreLocalRunPhase = .running, state: CoreExecutionState = .running,
                        discarded: Bool = false, jobs: [CoreLocalRunJobStatus] = [], cleanup: String? = nil) -> CoreLocalRunOutput {
        let made = lines.map { range in range.map { CoreLocalRunLine(sequence: $0, jobID: $0 % 2 == 0 ? "lint" : "", text: "line \($0)", isError: false) } } ?? []
        return CoreLocalRunOutput(executionID: "exec_1", repositoryID: "repo", state: state, phase: phase, lines: made,
                                  discarded: discarded, lastSequence: lines?.upperBound ?? 0, jobs: jobs, plan: plan(),
                                  startedAt: Date(), finishedAt: phase == .finished ? Date() : nil,
                                  exitCode: phase == .finished ? 0 : nil, message: nil, cleanupProblem: cleanup)
    }

    @Test func newRunListsJobsFromThePlan() {
        let run = LocalRunModel(executionID: "exec_1", workspaceID: UUID(), plan: plan())
        #expect(run.jobs.map(\.state) == [.waiting, .unsupported])
        #expect(run.selectedJobID == "lint")
        #expect(!run.isFinished)
    }

    @Test func outputIsMergedOnceAndBounded() {
        let run = LocalRunModel(executionID: "exec_1", workspaceID: UUID(), plan: plan())
        run.apply(output(lines: 1...4))
        run.apply(output(lines: 3...6)) // overlapping answer: only 5 and 6 are new
        #expect(run.lines.map(\.sequence) == [1, 2, 3, 4, 5, 6])
        #expect(run.visibleLines.map(\.sequence) == [2, 4, 6])
        run.selectedJobID = nil
        #expect(run.visibleLines.count == 6)
        #expect(!run.discarded)

        run.apply(output(lines: 7...UInt64(LocalRunModel.maxLines + 10)))
        #expect(run.lines.count == LocalRunModel.maxLines)
        #expect(run.lines.last?.sequence == UInt64(LocalRunModel.maxLines + 10))
        #expect(run.discarded)
    }

    @Test func coreReportedDiscardIsShown() {
        let run = LocalRunModel(executionID: "exec_1", workspaceID: UUID(), plan: plan())
        run.apply(output(lines: 900...905, discarded: true))
        #expect(run.discarded)
    }

    @Test func finishedOutputEndsTheRun() {
        let run = LocalRunModel(executionID: "exec_1", workspaceID: UUID(), plan: plan())
        run.apply(output(lines: nil, phase: .finished, state: .succeeded,
                         jobs: [CoreLocalRunJobStatus(id: "lint", state: .succeeded), CoreLocalRunJobStatus(id: "ios", state: .unsupported)],
                         cleanup: "Cleanup failed"))
        #expect(run.isFinished)
        #expect(run.state == .succeeded)
        #expect(run.exitCode == 0)
        #expect(run.cleanupProblem == "Cleanup failed")
        #expect(run.job("lint")?.state == .succeeded)
    }

    @Test func installedActIsUsedOnlyWhenOptedInAndFound() {
        var readiness = FakeCore.readyTools
        #expect(readiness.act(useInstalled: true).installed == false)
        readiness.installedAct = CoreToolStatus(state: .found, version: "0.2.91", path: "/opt/homebrew/bin/act", untested: true)
        #expect(readiness.act(useInstalled: true).installed)
        #expect(readiness.act(useInstalled: false).status.version == "0.2.89")
    }

    @Test func sentencesAreCapitalizedAndClosed() {
        #expect(CoreHub.sentence("the workflow file changed after the review; review the run again")
                == "The workflow file changed after the review; review the run again.")
        #expect(CoreHub.sentence("Done.") == "Done.")
    }

    @Test func elapsedTimeFormat() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(LocalRunText.elapsed(from: start, to: start.addingTimeInterval(42)) == "00:42")
        #expect(LocalRunText.elapsed(from: start, to: start.addingTimeInterval(3725)) == "1:02:05")
    }

    // MARK: Through the hub

    /// A ready hub with one open workspace, backed by the provider's fake Core.
    private func hub(_ configure: (FakeCore) -> Void = { _ in }) async -> (CoreHub, UUID, FakeCore) {
        let provider = FakeProvider()
        configure(provider.core)
        let hub = CoreHub(provider: provider)
        hub.startMonitoring()
        provider.ready()
        _ = await eventually { hub.status == .ready(version: "fake") }
        let workspace = UUID()
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/a")
        _ = await eventually { hub.session(for: workspace)?.phase == .ready }
        return (hub, workspace, provider.core)
    }

    @Test func reviewNeedsTrustAndStartsOnce() async throws {
        let (hub, workspace, fake) = await hub { $0.preparedLocalRun = prepared() }
        let review = LocalRunReviewModel(workspaceID: workspace, workflowID: ".github/workflows/ci.yml",
                                         jobs: [CoreJob(id: "lint", name: "lint", needs: [])], jobID: "lint", hub: hub,
                                         useInstalledAct: { true })
        await review.prepare()
        #expect(review.prepared?.confirmationID == "local_1")
        #expect(review.event == "push")
        #expect(fake.localRunRequests.first?.installed == true)
        #expect(fake.localRunRequests.first?.jobID == "lint")
        #expect(!review.canRun)

        review.trusted = true
        #expect(review.canRun)
        fake.localOutputs = [output(lines: 1...2, phase: .finished, state: .succeeded)]
        let run = try #require(await review.run())
        #expect(fake.confirmedLocalRuns == ["local_1"])
        #expect(hub.session(for: workspace)?.localRun === run)
        #expect(await eventually { run.isFinished })
        #expect(run.lines.count == 2)
    }

    @Test func blockedPlanCannotRun() async {
        let (hub, workspace, fake) = await hub { $0.preparedLocalRun = prepared(confirmation: nil, blockers: ["OrbStack is not running or does not answer."]) }
        let review = LocalRunReviewModel(workspaceID: workspace, workflowID: ".github/workflows/ci.yml", jobs: [], hub: hub)
        await review.prepare()
        review.trusted = true
        #expect(!review.canRun)
        #expect(await review.run() == nil)
        #expect(fake.confirmedLocalRuns.isEmpty)
    }

    @Test func refusedConfirmationIsExplainedAndReviewedAgain() async {
        let (hub, workspace, fake) = await hub {
            $0.preparedLocalRun = prepared()
            $0.confirmLocalRunError = .failedPrecondition("the workflow file changed after the review; review the run again")
        }
        let review = LocalRunReviewModel(workspaceID: workspace, workflowID: ".github/workflows/ci.yml", jobs: [], hub: hub)
        await review.prepare()
        review.trusted = true
        #expect(await review.run() == nil)
        #expect(review.error == "The workflow file changed after the review; review the run again.")
        #expect(fake.localRunRequests.count == 2)
        #expect(hub.session(for: workspace)?.localRun == nil)
    }

    @Test func runForgottenByTheCoreIsMarkedUnknown() async throws {
        let (hub, workspace, _) = await hub {
            $0.preparedLocalRun = prepared()
            $0.localOutputError = .notFound
        }
        let review = LocalRunReviewModel(workspaceID: workspace, workflowID: ".github/workflows/ci.yml", jobs: [], hub: hub)
        await review.prepare()
        review.trusted = true
        let run = try #require(await review.run())
        #expect(await eventually { run.lostMessage != nil })
        #expect(run.isFinished)
    }

    @Test func stopAsksTheCoreOnce() async throws {
        let (hub, workspace, fake) = await hub {
            $0.preparedLocalRun = prepared()
            $0.localOutputs = [output(lines: 1...1)]
        }
        let review = LocalRunReviewModel(workspaceID: workspace, workflowID: ".github/workflows/ci.yml", jobs: [], hub: hub)
        await review.prepare()
        review.trusted = true
        let run = try #require(await review.run())
        await run.stop(hub: hub)
        await run.stop(hub: hub)
        #expect(fake.cancelledExecutions == ["exec_1"])
        #expect(run.stopRequested)
        run.stopFollowing()
    }

    @Test func toolsSettingsReadsAndRechecks() async {
        let (hub, _, fake) = await hub()
        let model = ToolsSettingsModel(hub: hub)
        await model.check(refresh: false)
        #expect(model.readiness?.engine.name == "OrbStack")
        #expect(fake.readinessRefreshes == 0)
        await model.check(refresh: true)
        #expect(fake.readinessRefreshes == 1)
        let offline = ToolsSettingsModel(hub: nil)
        await offline.check(refresh: false)
        #expect(offline.unavailable)
    }
}
