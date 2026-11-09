import AppKit
import Foundation
import Testing
@testable import Runnir

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LocalRunTests {
    static let ci = ".github/workflows/ci.yml"

    private func plan(blockers: [String] = []) -> CoreLocalRunPlan {
        var plan = CoreLocalRunPlan.oneLane(Self.ci, name: "CI", jobs: [
            CoreLocalRunJob(id: "lint", runsOn: ["ubuntu-latest"], image: "catthehacker/ubuntu:act-latest", support: .supported, selected: true),
            CoreLocalRunJob(id: "ios", runsOn: ["macos-latest"], support: .unsupported, reason: "Not supported locally: macOS runner", selected: true),
        ])
        plan.blockers = blockers
        plan.cpus = 4
        plan.memoryBytes = 8 << 30
        plan.timeoutSeconds = 1800
        plan.actVersion = "0.2.89"
        plan.engineName = "OrbStack"
        plan.engineContext = "orbstack"
        return plan
    }

    private func prepared(confirmation: String? = "local_1", blockers: [String] = []) -> CorePreparedLocalRun {
        CorePreparedLocalRun(readiness: FakeCore.readyTools, plan: plan(blockers: blockers), confirmationID: confirmation, expiresAt: Date())
    }

    private func output(lines: ClosedRange<UInt64>?, phase: CoreLocalRunPhase = .running, state: CoreExecutionState = .running,
                        discarded: Bool = false, jobs: [CoreLocalRunJobStatus] = [], cleanup: String? = nil) -> CoreLocalRunOutput {
        let made = lines.map { range in range.map { CoreLocalRunLine(sequence: $0, workflowID: Self.ci, jobID: $0 % 2 == 0 ? "lint" : "", text: "line \($0)", isError: false) } } ?? []
        return CoreLocalRunOutput(executionID: "exec_1", repositoryID: "repo", state: state, phase: phase, lines: made,
                                  discarded: discarded, lastSequence: lines?.upperBound ?? 0, jobs: jobs, plan: plan(),
                                  startedAt: Date(), finishedAt: phase == .finished ? Date() : nil,
                                  exitCode: phase == .finished ? 0 : nil, message: nil, cleanupProblem: cleanup)
    }

    @Test func newRunListsJobsFromThePlan() {
        let run = LocalRunModel(executionID: "exec_1", workspaceID: UUID(), plan: plan())
        #expect(run.jobs.map(\.state) == [.waiting, .unsupported])
        #expect(run.selectedJobID.flatMap(run.job)?.jobID == "lint")
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
                         jobs: [CoreLocalRunJobStatus(workflowID: Self.ci, id: "lint", state: .succeeded),
                                CoreLocalRunJobStatus(workflowID: Self.ci, id: "ios", state: .unsupported)],
                         cleanup: "Cleanup failed"))
        #expect(run.isFinished)
        #expect(run.state == .succeeded)
        #expect(run.exitCode == 0)
        #expect(run.cleanupProblem == "Cleanup failed")
        #expect(run.jobs.first { $0.jobID == "lint" }?.state == .succeeded)
        #expect(run.lanes.map(\.lane.workflowID) == [Self.ci] && run.lanes.first?.jobs.count == 2)
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

    @Test func runningJobTimeCountsToNow() {
        let start = Date(timeIntervalSince1970: 0)
        let running = CoreLocalRunJobStatus(id: "lint", state: .running, startedAt: start)
        #expect(LocalRunText.jobSubtitle(running, now: start.addingTimeInterval(29)) == "Running · 00:29")
        #expect(LocalRunText.jobSubtitle(running, now: start.addingTimeInterval(52)) == "Running · 00:52")
        let done = CoreLocalRunJobStatus(id: "lint", state: .failed, startedAt: start, finishedAt: start.addingTimeInterval(51))
        #expect(LocalRunText.jobSubtitle(done, now: start.addingTimeInterval(300)) == "Failed · 00:51")
        #expect(LocalRunText.jobSubtitle(CoreLocalRunJobStatus(id: "ios", state: .unsupported, reason: "Not supported locally: macOS runner"),
                                         now: start) == "Not supported locally: macOS runner")
    }

    @Test func elapsedTimeFormat() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(LocalRunText.elapsed(from: start, to: start.addingTimeInterval(42)) == "00:42")
        #expect(LocalRunText.elapsed(from: start, to: start.addingTimeInterval(3725)) == "1:02:05")
    }

    // MARK: Through the hub

    /// A ready hub with one open workspace, backed by the provider's fake Core.
    private func hub(_ configure: (FakeCore) -> Void = { _ in }) async -> (CoreHub, UUID, FakeCore) {
        await makeWorkspaceHub(configure)
    }

    @Test func reviewNeedsTrustAndStartsOnce() async throws {
        let (hub, workspace, fake) = await hub { $0.preparedLocalRun = prepared() }
        let review = LocalRunReviewModel(workspaceID: workspace, hub: hub, useInstalledAct: { true })
        await review.prepare()
        #expect(review.prepared?.confirmationID == "local_1")
        #expect(review.scenario?.title == "Merge into main", "the Core's default scenario is kept")
        #expect(fake.localRunRequests.first?.installed == true)
        #expect(fake.localRunRequests.first?.scenario == nil && fake.localRunRequests.first?.selection == nil)
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

    @Test func jobsOnThisMacAreConfirmedApartFromTrust() async {
        var withMac = prepared()
        var plan = withMac.plan
        plan.hostJobs = ["CI › app"]
        withMac = CorePreparedLocalRun(readiness: withMac.readiness, plan: plan, confirmationID: "local_1", expiresAt: Date())
        let (hub, workspace, _) = await hub { $0.preparedLocalRun = withMac }
        let review = LocalRunReviewModel(workspaceID: workspace, hub: hub)
        await review.prepare()
        review.trusted = true
        #expect(review.hostJobs == ["CI › app"] && !review.canRun)
        review.hostConfirmed = true
        #expect(review.canRun)
        // The same jobs planned again keep the answer.
        await review.prepare()
        #expect(review.hostConfirmed)
    }

    @Test func changedLimitsPlanTheRunAgainAndAskForTheConfirmationAgain() async {
        let (hub, workspace, fake) = await hub { $0.preparedLocalRun = prepared() }
        let review = LocalRunReviewModel(workspaceID: workspace, hub: hub)
        await review.prepare()
        review.trusted = true
        let asked = CoreLocalRunLimits(cpus: 6, memoryBytes: 6 << 30, timeoutSeconds: 3600)
        await review.change(limits: asked)
        #expect(!review.trusted, "a new plan is confirmed again")
        #expect(fake.localRunLimits.map(\.limits) == [nil, asked])
        #expect(fake.localRunLimits.last?.reset == false)
        await review.resetLimits()
        #expect(fake.localRunLimits.last?.limits == nil && fake.localRunLimits.last?.reset == true)
        // Planning again for another reason keeps the reset.
        await review.prepare()
        #expect(fake.localRunLimits.last?.reset == true)
    }

    @Test func limitsAreWordedAsTheReviewShowsThem() {
        #expect(LocalRunText.duration(seconds: 1800) == "30 min")
        #expect(LocalRunText.duration(seconds: 3600) == "1 h")
        #expect(LocalRunText.duration(seconds: 5400) == "1 h 30 min")
        var plan = CoreLocalRunPlan()
        plan.cpus = 1
        plan.memoryBytes = 2 << 30
        plan.timeoutSeconds = 7200
        #expect(LocalRunText.limits(plan).hasPrefix("1 CPU · ") && LocalRunText.limits(plan).hasSuffix("· 2 h timeout"))
    }

    @Test func limitStepsStopAtTheirBounds() {
        #expect(LimitSteps.cpus(4, by: 1, max: 8) == 5)
        #expect(LimitSteps.cpus(8, by: 1, max: 8) == 8)
        #expect(LimitSteps.cpus(1, by: -1, max: 8) == 1)
        #expect(LimitSteps.cpus(16, by: 1, max: 0) == 17, "an engine that did not say caps nothing")
        let gib: UInt64 = 1 << 30
        #expect(LimitSteps.memory(4 * gib, by: 1, max: 8 * gib) == 4 * gib + 512 << 20)
        #expect(LimitSteps.memory(gib, by: -1, max: 8 * gib) == gib)
        // 5.85 GB, between steps: down to 5.5, up to the engine's 5.85.
        let engine = UInt64(5.85 * Double(gib))
        #expect(LimitSteps.memory(engine, by: -1, max: engine) == 5 * gib + 512 << 20)
        #expect(LimitSteps.memory(5 * gib + 512 << 20, by: 1, max: engine) == engine)
        #expect(LimitSteps.timeout(1800, by: 1) == 2100)
        #expect(LimitSteps.timeout(300, by: -1) == 300)
        #expect(LimitSteps.timeout(6 * 3600, by: 1) == 6 * 3600)
    }

    @Test func startPassesValuesToTheCore() async throws {
        let (hub, workspace, fake) = await hub { $0.preparedLocalRun = prepared() }
        fake.localOutputs = [output(lines: nil, phase: .finished, state: .succeeded)]
        let result = await hub.startLocalRun(workspaceID: workspace, prepared: prepared(),
                                             secrets: ["NPM_TOKEN": "s3cr3t"], variables: ["REGION": "eu"])
        guard case .started = result else { Issue.record("not started"); return }
        #expect(fake.confirmedValues.first?.secrets == ["NPM_TOKEN": "s3cr3t"])
        #expect(fake.confirmedValues.first?.variables == ["REGION": "eu"])
    }

    @Test func envFileIsReadByTheAppAndParsedByTheCore() async throws {
        let file = CoreEnvFile(entries: [CoreEnvEntry(name: "A", value: "1", encrypted: false, line: 1)], problems: [])
        let (hub, _, fake) = await hub { $0.envFile = file }
        let directory = temporaryFolder()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let env = directory.appendingPathComponent(".env")
        try Data("A=1\n".utf8).write(to: env)
        #expect(await hub.readEnvFile(url: env) == .read(file))
        #expect(fake.parsedContents == [Data("A=1\n".utf8)])

        fake.envFileError = .invalidArgument("the file is not UTF-8 text")
        #expect(await hub.readEnvFile(url: env) == .failed("The file is not UTF-8 text."))

        let large = directory.appendingPathComponent("large.env")
        try Data(repeating: 65, count: 1 << 20 + 1).write(to: large)
        #expect(await hub.readEnvFile(url: large) == .failed("The file is larger than 1 MiB."))
        #expect(await hub.readEnvFile(url: directory) == .failed("Runnir can't read this file."))
        #expect(fake.parsedContents.count == 2)
    }

    @Test func theRepositorysEnvFilesComeFromTheCore() async throws {
        let files = [CoreRepositoryEnvFile(path: ".env", ignored: false), CoreRepositoryEnvFile(path: "apps/web/.env.local", ignored: true)]
        let (hub, workspace, fake) = await hub { $0.repositoryEnvFiles = files }
        #expect(await hub.envFiles(workspaceID: workspace) == files)
        #expect(fake.envFilesRepositories == [try #require(hub.session(for: workspace)?.coreID)])

        fake.repositoryEnvFiles = nil
        #expect(await hub.envFiles(workspaceID: workspace) == nil)
        #expect(await hub.envFiles(workspaceID: UUID()) == nil)
    }

    private func valuesPlan() -> CorePreparedLocalRun {
        var plan = plan()
        plan.secrets = ["NPM_TOKEN", "OTHER"]
        plan.variables = ["REGION"]
        return CorePreparedLocalRun(readiness: FakeCore.readyTools, plan: plan, confirmationID: "local_1", expiresAt: Date())
    }

    @Test func runSendsSavedAndEnteredValuesForPlanNames() async throws {
        let (hub, workspace, fake) = await hub { $0.preparedLocalRun = valuesPlan() }
        let token = LocalRunValueKey(kind: .secret, name: "NPM_TOKEN")
        let region = LocalRunValueKey(kind: .variable, name: "REGION")
        let store = InMemoryLocalRunValueStore(values: [workspace: [token: "saved", region: "eu",
                                                                     LocalRunValueKey(kind: .secret, name: "UNRELATED"): "x"]])
        let review = LocalRunReviewModel(workspaceID: workspace, hub: hub, values: store)
        await review.prepare()
        #expect(review.saved == [token, region])
        #expect(review.missing == [LocalRunValueKey(kind: .secret, name: "OTHER")])
        #expect(review.accessSummary == "2 passed, 1 empty. Workflow steps can read these values and send them over the network")
        review.entered[region] = "us"
        review.trusted = true
        fake.localOutputs = [output(lines: nil, phase: .finished, state: .succeeded)]
        _ = try #require(await review.run())
        #expect(fake.confirmedValues.first?.secrets == ["NPM_TOKEN": "saved"])
        #expect(fake.confirmedValues.first?.variables == ["REGION": "us"])
        #expect(try await store.value(workspaceID: workspace, key: region) == "eu")
    }

    @Test func aJobInAnEnvironmentTakesItsValuesBeforeTheRepositorys() async throws {
        var plan = valuesPlan().plan
        plan.environment = "production"
        let prepared = CorePreparedLocalRun(readiness: FakeCore.readyTools, plan: plan, confirmationID: "local_1", expiresAt: Date())
        let (hub, workspace, fake) = await hub { $0.preparedLocalRun = prepared }
        let token = LocalRunValueKey(kind: .secret, name: "NPM_TOKEN")
        let region = LocalRunValueKey(kind: .variable, name: "REGION")
        let other = LocalRunValueKey(kind: .secret, name: "OTHER")
        let store = InMemoryLocalRunValueStore(values: [workspace: [token: "repository", token.in("production"): "production",
                                                                     region: "eu", region.in("staging"): "staging"]])
        let review = LocalRunReviewModel(workspaceID: workspace, hub: hub, values: store)
        await review.prepare()
        #expect(review.saved == [token, region])
        #expect(review.fromEnvironment == [token])
        review.entered[other] = "typed"
        review.saveEntered = true
        review.trusted = true
        fake.localOutputs = [output(lines: nil, phase: .finished, state: .succeeded)]
        _ = try #require(await review.run())
        #expect(fake.confirmedValues.first?.secrets == ["NPM_TOKEN": "production", "OTHER": "typed"])
        #expect(fake.confirmedValues.first?.variables == ["REGION": "eu"])
        // Entered values are saved for the job's environment.
        #expect(try await store.value(workspaceID: workspace, key: other.in("production")) == "typed")
        #expect(try await store.value(workspaceID: workspace, key: other) == nil)
    }

    @Test func aRunWhoseEnvironmentAnExpressionPicksTakesTheChosenValues() async throws {
        var plan = valuesPlan().plan
        plan.environmentChoice = "deploy picks its environment with an expression, known only when it runs."
        plan.environments = ["production", "staging"]
        let prepared = CorePreparedLocalRun(readiness: FakeCore.readyTools, plan: plan, confirmationID: "local_1", expiresAt: Date())
        let (hub, workspace, fake) = await hub { $0.preparedLocalRun = prepared }
        let token = LocalRunValueKey(kind: .secret, name: "NPM_TOKEN")
        let region = LocalRunValueKey(kind: .variable, name: "REGION")
        let other = LocalRunValueKey(kind: .secret, name: "OTHER")
        let store = InMemoryLocalRunValueStore(values: [workspace: [token.in("production"): "production", region: "eu"]])
        let review = LocalRunReviewModel(workspaceID: workspace, hub: hub, values: store)
        await review.prepare()
        // The Repository's values until the user chooses.
        #expect(review.choosesEnvironment && review.environment == nil)
        #expect(review.saved == [region] && review.missing == [token, other])
        #expect(review.emptyCount(with: nil) == 2 && review.emptyCount(with: "production") == 1 && review.emptyCount(with: "staging") == 2)

        await review.choose("production")
        #expect(review.environment == "production" && review.saveEnteredTitle == "Save entered values to production")
        #expect(review.saved == [token, region] && review.fromEnvironment == [token])
        review.entered[other] = "typed"
        review.saveEntered = true
        review.trusted = true
        fake.localOutputs = [output(lines: nil, phase: .finished, state: .succeeded)]
        _ = try #require(await review.run())
        #expect(fake.confirmedValues.first?.secrets == ["NPM_TOKEN": "production", "OTHER": "typed"])
        #expect(try await store.value(workspaceID: workspace, key: other.in("production")) == "typed")
    }

    @Test func enteredValuesAreSavedWhenAsked() async throws {
        let (hub, workspace, fake) = await hub { $0.preparedLocalRun = valuesPlan() }
        let store = InMemoryLocalRunValueStore()
        let review = LocalRunReviewModel(workspaceID: workspace, hub: hub, values: store)
        await review.prepare()
        let other = LocalRunValueKey(kind: .secret, name: "OTHER")
        review.entered[other] = "typed"
        review.saveEntered = true
        review.trusted = true
        fake.localOutputs = [output(lines: nil, phase: .finished, state: .succeeded)]
        _ = try #require(await review.run())
        #expect(try await store.value(workspaceID: workspace, key: other) == "typed")
        #expect(fake.confirmedValues.first?.secrets == ["OTHER": "typed"])
    }

    @Test func aFailedSaveOfEnteredValuesStartsNothing() async throws {
        let (hub, workspace, fake) = await hub { $0.preparedLocalRun = valuesPlan() }
        let store = InMemoryLocalRunValueStore()
        await store.setFailSaves(true)
        let review = LocalRunReviewModel(workspaceID: workspace, hub: hub, values: store)
        await review.prepare()
        review.entered[LocalRunValueKey(kind: .secret, name: "OTHER")] = "typed"
        review.saveEntered = true
        review.trusted = true
        #expect(await review.run() == nil)
        #expect(review.error?.hasPrefix("Keychain did not save the entered values, so the run did not start.") == true)
        #expect(fake.confirmedLocalRuns.isEmpty)
    }

    @Test func runWaitsForSavedValuesToBeRead() async throws {
        let (hub, workspace, fake) = await hub { $0.preparedLocalRun = valuesPlan() }
        let store = GatedValueStore(values: [LocalRunValueKey(kind: .secret, name: "NPM_TOKEN"): "saved"])
        let review = LocalRunReviewModel(workspaceID: workspace, hub: hub, values: store)
        review.trusted = true
        let preparing = Task { await review.prepare() }
        #expect(await eventually { review.prepared != nil })
        #expect(review.isPreparing && !review.canRun)
        await store.open()
        await preparing.value
        #expect(review.canRun)
        fake.localOutputs = [output(lines: nil, phase: .finished, state: .succeeded)]
        _ = try #require(await review.run())
        #expect(fake.confirmedValues.first?.secrets == ["NPM_TOKEN": "saved"])
    }

    @Test func refusedKeychainReadCountsAsMissing() async {
        let (hub, workspace, _) = await hub { $0.preparedLocalRun = valuesPlan() }
        let token = LocalRunValueKey(kind: .secret, name: "NPM_TOKEN")
        let store = InMemoryLocalRunValueStore(values: [workspace: [token: "saved"]])
        await store.setFailReads(true)
        let review = LocalRunReviewModel(workspaceID: workspace, hub: hub, values: store)
        await review.prepare()
        #expect(review.refused == [token])
        #expect(review.missing.contains(token))
    }

    @Test func savedValuesAreReadOncePerReview() async throws {
        let (hub, workspace, fake) = await hub { $0.preparedLocalRun = valuesPlan() }
        let token = LocalRunValueKey(kind: .secret, name: "NPM_TOKEN")
        let region = LocalRunValueKey(kind: .variable, name: "REGION")
        let store = InMemoryLocalRunValueStore(values: [workspace: [token: "saved", region: "eu"]])
        let review = LocalRunReviewModel(workspaceID: workspace, hub: hub, values: store)
        await review.prepare()
        await review.prepare()
        review.trusted = true
        fake.localOutputs = [output(lines: nil, phase: .finished, state: .succeeded)]
        _ = try #require(await review.run())
        #expect(await store.reads == 2)
        #expect(fake.confirmedValues.first?.secrets == ["NPM_TOKEN": "saved"])
        #expect(fake.confirmedValues.first?.variables == ["REGION": "eu"])
    }

    @Test func runWithoutNamesSaysNothingIsRead() async {
        let (hub, workspace, _) = await hub { $0.preparedLocalRun = prepared() }
        let review = LocalRunReviewModel(workspaceID: workspace, hub: hub)
        await review.prepare()
        #expect(review.runKeys.isEmpty)
        #expect(review.accessSummary == "None read by the ticked jobs. GitHub token and host environment are not passed")
    }

    @Test func blockedPlanCannotRun() async {
        let (hub, workspace, fake) = await hub { $0.preparedLocalRun = prepared(confirmation: nil, blockers: ["OrbStack is not running or does not answer."]) }
        let review = LocalRunReviewModel(workspaceID: workspace, hub: hub)
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
        let review = LocalRunReviewModel(workspaceID: workspace, hub: hub)
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
        let review = LocalRunReviewModel(workspaceID: workspace, hub: hub)
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
        let review = LocalRunReviewModel(workspaceID: workspace, hub: hub)
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

    @Test func secondRunIsRefusedWhileOneIsGoing() async throws {
        let (hub, workspace, fake) = await hub {
            $0.preparedLocalRun = prepared()
            $0.localOutputs = [output(lines: 1...1)]
        }
        let first = LocalRunReviewModel(workspaceID: workspace, hub: hub)
        let second = LocalRunReviewModel(workspaceID: workspace, hub: hub)
        await first.prepare()
        await second.prepare()
        first.trusted = true
        second.trusted = true
        let run = try #require(await first.run())
        #expect(await second.run() == nil)
        #expect(second.error == "A local run of this workspace is still going. Stop it before starting another.")
        #expect(fake.confirmedLocalRuns.count == 1)
        #expect(hub.session(for: workspace)?.localRun === run)
        run.stopFollowing()
    }

    // MARK: Quitting and closing during a run

    @Test func stopPromptsSayWhatStops() {
        let one = LocalRunStopPrompt(action: .quit, runs: ["ci.yml in mobile-app"])
        #expect(one.title == "Quit Runnir and stop the local run?")
        #expect(one.detail == "ci.yml in mobile-app is still going. Quitting stops it and removes its containers. Runnir does not resume runs.")
        #expect(one.confirmTitle == "Stop and Quit")
        let two = LocalRunStopPrompt(action: .quit, runs: ["CI in a", "release.yml in b"])
        #expect(two.title == "Quit Runnir and stop 2 local runs?")
        #expect(two.detail.contains("are still going. Quitting stops them and removes their containers."))
        #expect(LocalRunStopPrompt(action: .closeWindow, runs: ["CI in a"]).confirmTitle == "Stop Run and Close")
        #expect(LocalRunStopPrompt(action: .switchWorkspace, runs: ["CI in a"]).title == "Switch workspaces and stop the local run?")
    }

    @Test func stopAlertKeepsTheRunOnEscapeAndSpace() {
        let alert = LocalRunStopPrompt.alert(for: LocalRunStopPrompt(action: .quit, runs: ["CI in a"]))
        #expect(alert.buttons.map(\.title) == ["Stop and Quit", "Cancel"])
        #expect(alert.buttons[0].hasDestructiveAction)
        #expect(alert.buttons[1].keyEquivalent == "\u{1b}")
        #expect(alert.window.initialFirstResponder === alert.buttons[1])
        // macOS keeps Return off a destructive button even though its key
        // equivalent still reads "\r": the alert does not handle it.
        alert.layout()
        let returnKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: alert.window.windowNumber, context: nil, characters: "\r",
                                         charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
        #expect(returnKey.map { alert.window.performKeyEquivalent(with: $0) } == false)
    }

    /// A hub with workspace /repo/a open in `window` and a run going in it.
    private func runningHub(window: UUID) async throws -> (CoreHub, UUID, LocalRunModel) {
        let provider = FakeProvider()
        provider.core.preparedLocalRun = prepared()
        provider.core.localOutputs = [output(lines: 1...1)]
        let hub = CoreHub(provider: provider)
        hub.startMonitoring()
        provider.ready()
        _ = await eventually { hub.status == .ready(version: "fake") }
        let workspace = UUID()
        hub.attach(windowID: window, workspaceID: workspace, path: "/repo/a")
        _ = await eventually { hub.session(for: workspace)?.phase == .ready }
        let review = LocalRunReviewModel(workspaceID: workspace, hub: hub)
        await review.prepare()
        review.trusted = true
        let run = try #require(await review.run())
        return (hub, workspace, run)
    }

    @Test func onlyTheWorkspacesLastWindowStopsItsRun() async throws {
        let first = UUID()
        let (hub, workspace, run) = try await runningHub(window: first)
        #expect(hub.localRunEnding(withWindow: first) === run)
        #expect(hub.activeLocalRuns.count == 1)
        #expect(hub.describe(run) == "CI in a")

        let second = UUID()
        hub.attach(windowID: second, workspaceID: workspace, path: "/repo/a")
        #expect(hub.localRunEnding(withWindow: first) == nil)
        #expect(hub.localRunEnding(withWindow: second) == nil)
        #expect(hub.localRunEnding(withWindow: UUID()) == nil)
        run.stopFollowing()
    }

    @Test func quittingAndClosingAskWhileARunIsGoing() async throws {
        let window = UUID()
        let (hub, _, run) = try await runningHub(window: window)
        let desktop = DesktopCoordinator(core: hub)
        var asked: [LocalRunStopPrompt] = []
        desktop.confirmStoppingLocalRuns = { asked.append($0); return false }

        #expect(!desktop.confirmQuitStopsLocalRuns())
        #expect(!desktop.shouldClose(window))
        #expect(asked == [LocalRunStopPrompt(action: .quit, runs: ["CI in a"]),
                          LocalRunStopPrompt(action: .closeWindow, runs: ["CI in a"])])

        desktop.confirmStoppingLocalRuns = { _ in true }
        #expect(desktop.confirmQuitStopsLocalRuns())
        run.stopFollowing()
    }

    @Test func nothingIsStoppedWhenTheCoreIsGone() async throws {
        let window = UUID()
        let provider = FakeProvider()
        provider.core.preparedLocalRun = prepared()
        provider.core.localOutputs = [output(lines: 1...1)]
        let hub = CoreHub(provider: provider)
        hub.startMonitoring()
        provider.ready()
        _ = await eventually { hub.status == .ready(version: "fake") }
        let workspace = UUID()
        hub.attach(windowID: window, workspaceID: workspace, path: "/repo/a")
        _ = await eventually { hub.session(for: workspace)?.phase == .ready }
        let review = LocalRunReviewModel(workspaceID: workspace, hub: hub)
        await review.prepare()
        review.trusted = true
        let run = try #require(await review.run())
        #expect(hub.activeLocalRuns.count == 1)

        provider.emit(.lost(.processExited(9)))
        _ = await eventually { hub.status == .lost }
        // The run's last report says running, but no Core is left to stop it.
        #expect(!run.isFinished)
        #expect(hub.activeLocalRuns.isEmpty)
        #expect(hub.localRunEnding(withWindow: window) == nil)
        run.stopFollowing()
    }

    @Test func quittingWithoutARunDoesNotAsk() async {
        let (hub, _, _) = await hub()
        let desktop = DesktopCoordinator(core: hub)
        var asked = false
        desktop.confirmStoppingLocalRuns = { _ in asked = true; return false }
        #expect(desktop.confirmQuitStopsLocalRuns())
        #expect(!asked)
    }
}

/// Saved values whose reads wait until `open()`, as a Keychain asking for
/// access would.
private actor GatedValueStore: LocalRunValueStoring {
    private let values: [LocalRunValueKey: String]
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(values: [LocalRunValueKey: String]) { self.values = values }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }

    func keys(workspaceID: UUID) async throws -> Set<LocalRunValueKey> { Set(values.keys) }
    func value(workspaceID: UUID, key: LocalRunValueKey) async throws -> String? {
        if !isOpen { await withCheckedContinuation { waiting.append($0) } }
        return values[key]
    }
    func save(workspaceID: UUID, key: LocalRunValueKey, value: String) async throws {}
    func remove(workspaceID: UUID, key: LocalRunValueKey) async throws {}
    func removeAll(workspaceID: UUID) async throws {}
}

extension CoreLocalRunPlan {
    /// A plan of one workflow in the "Merge into main" scenario.
    static func oneLane(_ workflowID: String, name: String = "", event: String = "push", jobs: [CoreLocalRunJob]) -> CoreLocalRunPlan {
        let scenario = CoreScenario(kind: .merge, target: "main", title: "Merge into main")
        return CoreLocalRunPlan(scenarios: [scenario], scenario: scenario, lanes: [
            CoreLocalRunLane(workflowID: workflowID, workflowName: name, kind: .direct, event: event, why: event,
                             selected: jobs.contains(where: \.selected), jobs: jobs),
        ])
    }
}

/// Ticking jobs: a job brings what it needs, unticking takes what needs it.
@Suite struct LocalRunTicksTests {
    private let lane = CoreLocalRunLane(workflowID: "ci.yml", jobs: [
        CoreLocalRunJob(id: "lint", support: .supported),
        CoreLocalRunJob(id: "test", support: .supported, needs: ["lint"]),
        CoreLocalRunJob(id: "deploy", support: .supported, needs: ["test"]),
        CoreLocalRunJob(id: "docs", support: .supported),
        CoreLocalRunJob(id: "ios", support: .unsupported, needs: ["lint"]),
    ])

    @Test func tickingAJobTicksWhatItNeeds() {
        #expect(LocalRunTicks.tick("deploy", in: lane, []) == ["deploy", "test", "lint"])
        #expect(LocalRunTicks.tick("docs", in: lane, ["lint"]) == ["docs", "lint"])
    }

    @Test func untickingAJobUnticksWhatNeedsIt() {
        #expect(LocalRunTicks.untick("lint", in: lane, ["lint", "test", "deploy", "docs"]) == ["docs"])
        #expect(LocalRunTicks.untick("deploy", in: lane, ["lint", "test", "deploy"]) == ["lint", "test"])
    }

    @Test func aWorkflowsCheckboxTicksAllThatCanRunOrNone() {
        #expect(LocalRunTicks.state(of: lane, []) == .off)
        #expect(LocalRunTicks.state(of: lane, ["lint"]) == .mixed)
        let all = LocalRunTicks.toggle(lane, [])
        #expect(all == ["lint", "test", "deploy", "docs"], "a job no local image runs is left out")
        #expect(LocalRunTicks.state(of: lane, all) == .on)
        #expect(LocalRunTicks.toggle(lane, all).isEmpty)
        #expect(LocalRunTicks.toggle(lane, ["lint"]).isEmpty, "a partly ticked workflow is unticked")
        #expect(!LocalRunTicks.tickable(CoreLocalRunLane(workflowID: "x.yml", parseError: "The file has 1 syntax error.")))
    }

    @Test func aWorkflowsCheckboxLeavesJobsOnThisMacToTheirOwnTicks() {
        let mixed = CoreLocalRunLane(workflowID: "ci.yml", jobs: [
            CoreLocalRunJob(id: "lint", support: .supported),
            CoreLocalRunJob(id: "app", support: .host),
        ])
        #expect(LocalRunTicks.toggle(mixed, []) == ["lint"])
        #expect(LocalRunTicks.state(of: mixed, ["lint"]) == .on)
        #expect(LocalRunTicks.tickable(mixed.jobs[1]), "a job on this Mac is ticked by hand")
        let macOnly = CoreLocalRunLane(workflowID: "release.yml", jobs: [CoreLocalRunJob(id: "sign", support: .host)])
        #expect(LocalRunTicks.toggle(macOnly, []) == ["sign"])
    }

    @Test func aSelectionOfNothingStillSaysSo() {
        #expect(CoreLocalRunSelection(jobs: ["b.yml": [], "a.yml": []]).wire.map(\.0) == ["a.yml"])
        let wire = CoreLocalRunSelection(jobs: ["b.yml": ["z", "a"], "a.yml": []]).wire
        #expect(wire.count == 1 && wire[0].0 == "b.yml" && wire[0].1 == ["a", "z"])
    }

    @Test func runAgainAsksForTheRunsScenarioAndTicks() {
        let plan = CoreLocalRunPlan.oneLane("ci.yml", jobs: [CoreLocalRunJob(id: "lint", support: .supported, selected: true),
                                                             CoreLocalRunJob(id: "docs", support: .supported)])
        let again = LocalRunRequest.again(plan)
        #expect(again.scenario?.kind == .merge && again.selection?.jobs["ci.yml"] == ["lint"])
    }
}
