import Foundation
import Testing
@testable import Runnir

// MARK: Fakes

private actor FakeHealth {
    var failuresBeforeSuccess: Int
    var protocolVersion: Int
    var calls = 0
    let processID: Int32
    var hangs = false
    func setHangs(_ value: Bool) { hangs = value }
    init(failuresBeforeSuccess: Int = 0, protocolVersion: Int = 1, processID: Int32 = 0) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
        self.protocolVersion = protocolVersion
        self.processID = processID
    }
    func next() throws -> CoreHealth {
        calls += 1
        if failuresBeforeSuccess > 0 {
            failuresBeforeSuccess -= 1
            throw CoreServiceError.unavailable
        }
        return CoreHealth(coreVersion: "test", protocolVersion: protocolVersion, openRepositoryCount: 0, residentMemoryBytes: 1, processID: processID)
    }
}

private struct FakeService: CoreServicing {
    let health: FakeHealth
    func healthCheck() async throws -> CoreHealth {
        if await health.hangs {
            // A peer that accepts the call and never answers.
            try await Task.sleep(for: .seconds(60))
        }
        return try await health.next()
    }
    func openRepository(path: String, workspaceID: UUID?) async throws -> CoreRepository { throw CoreServiceError.unavailable }
    func workspaceActivity(repositoryID: String, limit: Int) async throws -> CoreWorkspaceActivity { throw CoreServiceError.unavailable }
    func refreshWorkspaceActivity(repositoryID: String, wait: Bool, limit: Int) async throws -> CoreWorkspaceActivity { throw CoreServiceError.unavailable }
    func storageUsage(workspaceIDs: [UUID]) async throws -> CoreStorageUsage { throw CoreServiceError.unavailable }
    func clearWorkspaceCache(workspaceIDs: [UUID]) async throws -> [CoreWorkspaceStorage] { throw CoreServiceError.unavailable }
    func deleteWorkspaceData(workspaceID: UUID) async throws { throw CoreServiceError.unavailable }
    func setStoragePreferences(keepJobLogs: Bool, deleteKeptLogs: Bool) async throws { throw CoreServiceError.unavailable }
    func refreshRepository(id: String) async throws -> CoreRepository { throw CoreServiceError.unavailable }
    func closeRepository(id: String) async throws { throw CoreServiceError.unavailable }
    func listWorkflows(repositoryID: String) async throws -> [CoreWorkflow] { throw CoreServiceError.unavailable }
    func startWorkflow(repositoryID: String, workflowID: String, ref: String?) async throws -> CoreExecution { throw CoreServiceError.unavailable }
    func validateWorkflows(repositoryID: String, workflowID: String?) async throws -> CoreValidationReport { throw CoreServiceError.unavailable }
    func events(repositoryIDs: [String]) -> AsyncThrowingStream<CoreEvent, any Error> {
        AsyncThrowingStream { $0.finish(throwing: CoreServiceError.unavailable) }
    }
    func setGitHubCredential(_ token: String?, server: GitHubServerRef) async throws -> CoreGitHubCredentialKind? { nil }
    func checkGitHubToken(_ token: String, server: GitHubServerRef) async throws -> CoreGitHubTokenCheck { .failed(.unavailable) }
    func listGitHubRepositories(server: String) async throws -> CoreGitHubAccount { .failed(.ok) }
    func githubOrigins(paths: [String]) async throws -> [String: GitHubRepositoryRef] { [:] }
    func listPullRequests(server: String, closedSince: Date) async throws -> CorePullRequests { .failed(.ok) }
    func listGitHubWorkflows(target: CoreGitHubTarget) async throws -> CoreGitHubResult<CoreGitHubWorkflow> { CoreGitHubResult(access: .ok, items: []) }
    func listWorkflowRuns(target: CoreGitHubTarget, branch: String?, limit: Int) async throws -> CoreGitHubResult<CoreWorkflowRun> { CoreGitHubResult(access: .ok, items: []) }
    func listRunJobs(repositoryID: String, runID: Int64) async throws -> CoreGitHubResult<CoreRunJob> { CoreGitHubResult(access: .ok, items: []) }
    func gitHubRepository(target: CoreGitHubTarget) async throws -> CoreGitHubRepository { .failed(.ok) }
    func listGitHubRefs(target: CoreGitHubTarget) async throws -> CoreGitHubRefs { CoreGitHubRefs(access: .ok, defaultBranch: "main", branches: ["main"], tags: []) }
    func describeWorkflowDispatch(target: CoreGitHubTarget, workflowPath: String, ref: String) async throws -> CoreDispatchDefinition {
        CoreDispatchDefinition(access: .ok, dispatchable: false, inputs: [], parseError: nil)
    }
    func prepareWorkflowDispatch(target: CoreGitHubTarget, workflowID: Int64, ref: String, inputs: [String: String]) async throws -> CorePreparedDispatch {
        CorePreparedDispatch(access: .ok, dispatchID: nil, expiresAt: nil, problems: [], workflowPath: "")
    }
    func confirmWorkflowDispatch(dispatchID: String) async throws -> CoreDispatchResult { throw CoreServiceError.unavailable }
    func jobLog(repositoryID: String, jobID: Int64) async throws -> CoreJobLog { throw CoreServiceError.unavailable }
    func prepareRunAction(repositoryID: String, runID: Int64, action: CoreRunAction) async throws -> CorePreparedRunAction { throw CoreServiceError.unavailable }
    func confirmRunAction(actionID: String) async throws -> CoreRunActionResult { throw CoreServiceError.unavailable }
    func toolReadiness(refresh: Bool) async throws -> CoreToolReadiness { throw CoreServiceError.unavailable }
    func prepareLocalRun(repositoryID: String, workflowID: String, jobID: String?, event: String?,
                         useInstalledAct: Bool) async throws -> CorePreparedLocalRun { throw CoreServiceError.unavailable }
    func confirmLocalRun(confirmationID: String) async throws -> CoreExecution { throw CoreServiceError.unavailable }
    func localRunOutput(executionID: String, after: UInt64) async throws -> CoreLocalRunOutput { throw CoreServiceError.unavailable }
    func cancelExecution(executionID: String) async throws { throw CoreServiceError.unavailable }
    func saveWorkflowFile(repositoryID: String, workflowID: String, content: String, baseSHA256: String,
                          overwrite: Bool) async throws -> CoreWorkflowSave { throw CoreServiceError.unavailable }
    func createWorkflowFile(repositoryID: String, fileName: String, content: String) async throws -> String { throw CoreServiceError.unavailable }
    func renameWorkflowFile(repositoryID: String, workflowID: String, newFileName: String) async throws -> String { throw CoreServiceError.unavailable }
}

private final class FakeConnection: CoreConnection, @unchecked Sendable {
    let service: any CoreServicing
    init(health: FakeHealth) { service = FakeService(health: health) }
    func close() async {}
}

private final class FakeConnector: CoreConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private let health: FakeHealth
    private(set) var connects = 0
    private(set) var secrets: [String] = []
    init(health: FakeHealth) { self.health = health }
    func connect(socketPath: String, clientSecret: String) async throws -> any CoreConnection {
        lock.withLock { connects += 1; secrets.append(clientSecret) }
        return FakeConnection(health: health)
    }
}

private final class FakeHandle: CoreProcessHandle, @unchecked Sendable {
    let processIdentifier: Int32
    private let lock = NSLock()
    private var status: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []
    private(set) var terminated = false
    private(set) var terminatedNow = false

    init(pid: Int32) { processIdentifier = pid }

    func exit(_ code: Int32) {
        lock.lock()
        status = code
        let pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending { waiter.resume(returning: code) }
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status { lock.unlock(); continuation.resume(returning: status) }
            else { waiters.append(continuation); lock.unlock() }
        }
    }

    func terminate() async {
        lock.withLock { terminated = true }
        exit(0)
    }

    func terminateNow() { lock.lock(); terminatedNow = true; lock.unlock() }
}

private final class FakeLauncher: CoreProcessLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var handles: [FakeHandle] = []
    var launchError: CoreSupervisorError?
    var createsSocket = true
    var exitImmediately: Int32?
    var launches: Int { lock.lock(); defer { lock.unlock() }; return handles.count }

    private(set) var secrets: [String] = []

    func launch(socketPath: String, clientSecret: String) throws -> any CoreProcessHandle {
        if let launchError { throw launchError }
        lock.lock()
        secrets.append(clientSecret)
        let handle = FakeHandle(pid: Int32(1000 + handles.count))
        handles.append(handle)
        lock.unlock()
        if createsSocket { FileManager.default.createFile(atPath: socketPath, contents: nil) }
        if let code = exitImmediately { handle.exit(code) }
        return handle
    }
}

private func makeSocketPath() -> String {
    let dir = "/tmp/rn" + String(UUID().uuidString.prefix(8))
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir + "/core.sock"
}

private struct Rig {
    let supervisor: CoreProcessSupervisor
    let launcher: FakeLauncher
    let connector: FakeConnector
    let health: FakeHealth
    let socketPath: String

    init(failures: Int = 0, protocolVersion: Int = 1, processID: Int32 = 0, timeout: Duration = .seconds(2),
         liveness: Duration = .seconds(600)) {
        health = FakeHealth(failuresBeforeSuccess: failures, protocolVersion: protocolVersion, processID: processID)
        launcher = FakeLauncher()
        connector = FakeConnector(health: health)
        socketPath = makeSocketPath()
        supervisor = CoreProcessSupervisor(
            launcher: launcher, connector: connector, socketPath: socketPath,
            healthTimeout: timeout, pollInterval: .milliseconds(5),
            livenessInterval: liveness, livenessTimeout: .milliseconds(50), livenessFailureLimit: 2
        )
    }
}


// MARK: Tests

@Suite(.timeLimit(.minutes(1)))
struct CoreProcessSupervisorTests {
    @Test
    func startLaunchesOnceAndReportsHealth() async throws {
        let rig = Rig()
        let health = try await rig.supervisor.start()
        #expect(health.protocolVersion == 1)
        #expect(await rig.supervisor.state == .running(health))
        #expect(rig.launcher.launches == 1)
        _ = try await rig.supervisor.service()
        await rig.supervisor.stop()
    }

    @Test
    func concurrentAndRepeatedStartsShareOneProcess() async throws {
        let rig = Rig()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { try await rig.supervisor.start() } }
            try await group.waitForAll()
        }
        try await rig.supervisor.start()
        #expect(rig.launcher.launches == 1)
        await rig.supervisor.stop()
    }

    @Test
    func retriesHealthCheckUntilReady() async throws {
        let rig = Rig(failures: 3)
        try await rig.supervisor.start()
        #expect(await rig.health.calls == 4)
        await rig.supervisor.stop()
    }

    @Test
    func timesOutAndStopsTheProcessWhenNeverHealthy() async {
        let rig = Rig(failures: .max, timeout: .milliseconds(150))
        await #expect(throws: CoreSupervisorError.timedOut) { try await rig.supervisor.start() }
        #expect(await rig.supervisor.state == .failed(.timedOut))
        #expect(rig.launcher.handles.first?.terminated == true)
    }

    @Test
    func rejectsIncompatibleProtocol() async {
        let rig = Rig(protocolVersion: 2)
        await #expect(throws: CoreSupervisorError.incompatibleProtocol(2)) { try await rig.supervisor.start() }
        #expect(rig.launcher.handles.first?.terminated == true)
    }

    @Test
    func missingHelperFails() async {
        let rig = Rig()
        rig.launcher.launchError = .helperUnavailable
        await #expect(throws: CoreSupervisorError.helperUnavailable) { try await rig.supervisor.start() }
        #expect(await rig.supervisor.state == .failed(.helperUnavailable))
    }

    @Test
    func duplicateInstanceIsReportedAndItsSocketIsLeftAlone() async throws {
        let rig = Rig(failures: .max)
        rig.launcher.exitImmediately = 3
        await #expect(throws: CoreSupervisorError.alreadyRunning) { try await rig.supervisor.start() }
        #expect(await rig.supervisor.state == .failed(.alreadyRunning))
        // The socket belongs to the other, live Core; the refused attempt must not remove it.
        #expect(FileManager.default.fileExists(atPath: rig.socketPath))
    }

    @Test
    func aCoreThatIsNotOurChildDoesNotCount() async {
        // Something else answers on the socket (another instance's Core).
        let rig = Rig(processID: 4242, timeout: .milliseconds(150))
        await #expect(throws: CoreSupervisorError.timedOut) { try await rig.supervisor.start() }
        #expect(await rig.supervisor.state == .failed(.timedOut))
    }

    @Test
    func acceptsTheCoreWhosePidMatchesOurChild() async throws {
        let rig = Rig(processID: 1000) // FakeLauncher's first child
        let health = try await rig.supervisor.start()
        #expect(health.processID == 1000)
        await rig.supervisor.stop()
    }

    @Test
    func detectsLossAndRecovers() async throws {
        let rig = Rig()
        try await rig.supervisor.start()
        rig.launcher.handles[0].exit(137)

        #expect(await eventuallyAsync { await rig.supervisor.state == .lost(.processExited(137)) })
        await #expect(throws: CoreServiceError.unavailable) { _ = try await rig.supervisor.service() }

        let health = try await rig.supervisor.recover()
        #expect(await rig.supervisor.state == .running(health))
        #expect(rig.launcher.launches == 2)
        await rig.supervisor.stop()
    }

    @Test
    func stopTerminatesAndAllowsRestart() async throws {
        let rig = Rig()
        try await rig.supervisor.start()
        await rig.supervisor.stop()
        #expect(await rig.supervisor.state == .stopped)
        #expect(rig.launcher.handles[0].terminated)
        await #expect(throws: CoreServiceError.unavailable) { _ = try await rig.supervisor.service() }

        try await rig.supervisor.start()
        #expect(rig.launcher.launches == 2)
        await rig.supervisor.stop()
    }

    @Test
    func stoppingDuringStartCancelsIt() async {
        let rig = Rig(failures: .max, timeout: .seconds(30))
        let starting = Task { try await rig.supervisor.start() }
        #expect(await eventuallyAsync { rig.launcher.launches == 1 })
        await rig.supervisor.stop()
        _ = try? await starting.value
        #expect(await rig.supervisor.state == .stopped)
        #expect(rig.launcher.handles[0].terminated)
    }

    @Test
    func publishesStateChanges() async throws {
        let rig = Rig()
        let stream = await rig.supervisor.states()
        let collector = Task { () -> [String] in
            var seen: [String] = []
            for await state in stream {
                switch state {
                case .stopped: seen.append("stopped")
                case .starting: seen.append("starting")
                case .running: seen.append("running")
                case .lost: seen.append("lost"); return seen
                case .failed: seen.append("failed"); return seen
                }
            }
            return seen
        }
        try await rig.supervisor.start()
        rig.launcher.handles[0].exit(9)
        #expect(await collector.value == ["stopped", "starting", "running", "lost"])
    }

    @Test
    func aHealthCheckThatNeverAnswersStillTimesOut() async {
        let rig = Rig(timeout: .milliseconds(300))
        await rig.health.setHangs(true)
        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: CoreSupervisorError.timedOut) { try await rig.supervisor.start() }
        #expect(clock.now - started < .seconds(3))
    }

    @Test
    func aSocketPathThatCannotFitFailsBeforeLaunching() async {
        let launcher = FakeLauncher()
        let health = FakeHealth()
        let supervisor = CoreProcessSupervisor(
            launcher: launcher, connector: FakeConnector(health: health),
            socketPath: "/tmp/" + String(repeating: "x", count: 120) + ".sock")
        await #expect(throws: CoreSupervisorError.socketPathTooLong) { try await supervisor.start() }
        #expect(launcher.launches == 0)
    }

    @Test
    func socketPathFallsBackToAShortName() {
        let short = URL(fileURLWithPath: "/tmp", isDirectory: true)
        #expect(CoreProcessSupervisor.socketPath(in: short) == "/tmp/runnir-core.sock")
        // 90 bytes: the long name no longer fits, the short one does.
        let deep = URL(fileURLWithPath: "/" + String(repeating: "d", count: 89), isDirectory: true)
        #expect(CoreProcessSupervisor.socketPath(in: deep).hasSuffix("/rc.sock"))
        #expect(CoreProcessSupervisor.socketPath(in: deep).utf8.count <= CoreProcessSupervisor.maxSocketPathBytes)
    }

    @Test
    func eachCopyOfTheAppGetsItsOwnSocket() {
        let debug = CoreProcessSupervisor.instanceTag(for: URL(fileURLWithPath: "/Users/me/DerivedData/Build/Products/Debug/Runnir.app"))
        let installed = CoreProcessSupervisor.instanceTag(for: URL(fileURLWithPath: "/Applications/Runnir.app"))
        #expect(debug != installed)
        #expect(debug == CoreProcessSupervisor.instanceTag(for: URL(fileURLWithPath: "/Users/me/DerivedData/Build/Products/Debug/Runnir.app/")))
        #expect(debug.count == 8)
        let tmp = URL(fileURLWithPath: "/tmp", isDirectory: true)
        #expect(CoreProcessSupervisor.socketPath(in: tmp, instance: debug) == "/tmp/runnir-core-\(debug).sock")
        let deep = URL(fileURLWithPath: "/" + String(repeating: "d", count: 80), isDirectory: true)
        #expect(CoreProcessSupervisor.socketPath(in: deep, instance: debug).hasSuffix("/rc-\(debug).sock"))
    }

    @Test
    func eachLaunchGetsAFreshSecretThatTheConnectionPresents() async throws {
        let rig = Rig()
        try await rig.supervisor.start()
        rig.launcher.handles[0].exit(9)
        #expect(await eventuallyAsync { if case .lost = await rig.supervisor.state { true } else { false } })
        try await rig.supervisor.recover()

        let launched = rig.launcher.secrets
        #expect(launched.count == 2)
        #expect(launched[0] != launched[1])
        #expect(launched.allSatisfy { $0.count == 64 && $0.allSatisfy(\.isHexDigit) })
        #expect(Set(rig.connector.secrets) == Set(launched))
        await rig.supervisor.stop()
    }

    @Test
    func terminateImmediatelyReachesTheRunningProcess() async throws {
        let rig = Rig()
        try await rig.supervisor.start()
        rig.supervisor.terminateImmediately()
        #expect(rig.launcher.handles[0].terminatedNow)
        await rig.supervisor.stop()
    }
}

@Suite(.timeLimit(.minutes(1)))
struct CoreLivenessTests {
    @Test
    func aCoreThatStopsAnsweringIsReportedLostAndStopped() async throws {
        let rig = Rig(liveness: .milliseconds(20))
        try await rig.supervisor.start()
        await rig.health.setHangs(true)
        #expect(await eventuallyAsync { await rig.supervisor.state == .lost(.unresponsive) })
        #expect(rig.launcher.handles[0].terminated, "the hung process is stopped so a restart can take the lock")
        await rig.health.setHangs(false)
        try await rig.supervisor.recover()
        #expect(rig.launcher.launches == 2)
        await rig.supervisor.stop()
    }

    @Test
    func aHealthyCoreStaysRunning() async throws {
        let rig = Rig(liveness: .milliseconds(10))
        try await rig.supervisor.start()
        // Wait for several liveness checks however slow the machine is.
        #expect(await eventuallyAsync { await rig.health.calls > 3 }, "health is checked while running")
        #expect(await rig.supervisor.state == .running(CoreHealth(coreVersion: "test", protocolVersion: 1, openRepositoryCount: 0,
                                                                   residentMemoryBytes: 1, processID: 0)))
        await rig.supervisor.stop()
    }
}

struct ProcessCoreHandleTests {
    @Test(.timeLimit(.minutes(1)))
    func terminateKillsAProcessThatIgnoresSIGTERMAndStdinEOF() async throws {
        let process = Process()
        let stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; while :; do sleep 1; done"]
        process.standardInput = stdin
        let handle = ProcessCoreHandle(process: process, stdin: stdin, gracePeriod: .milliseconds(300))
        process.terminationHandler = { handle.markExited($0.terminationStatus) }
        try process.run()
        // Let the shell install its trap before we signal it.
        try await Task.sleep(for: .milliseconds(200))

        let clock = ContinuousClock()
        let started = clock.now
        await handle.terminate()
        #expect(clock.now - started < .seconds(5))
        #expect(!process.isRunning)
        #expect(process.terminationReason == .uncaughtSignal)
    }

    @Test(.timeLimit(.minutes(1)))
    func waitWithTimeoutReturnsNilWhileRunningAndTheStatusAfterExit() async throws {
        let process = Process()
        let stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        process.standardInput = stdin
        let handle = ProcessCoreHandle(process: process, stdin: stdin)
        process.terminationHandler = { handle.markExited($0.terminationStatus) }
        try process.run()
        #expect(await handle.waitForExit(timeout: .milliseconds(100)) == nil)
        #expect(await handle.waitForExit(timeout: .milliseconds(100)) == nil)
        // Timed-out waits do not leave waiters behind.
        #expect(handle.pendingWaiters == 0)
        try stdin.fileHandleForWriting.close() // cat exits at EOF
        #expect(await handle.waitForExit() == 0)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ProcessCoreLauncherTests {
    /// The Core's standard error lands in the log, and the previous launch's
    /// log is kept beside it.
    @Test
    func theCoreWritesItsDiagnosticsToALogAndTheLastOneIsKept() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let helper = directory.appendingPathComponent("fake-core")
        try "#!/bin/sh\nread secret\necho \"run failed, tmp=$TMPDIR\" >&2\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let log = directory.appendingPathComponent("Logs/core.log")
        let launcher = ProcessCoreLauncher(executableURL: helper, logURL: log)

        for _ in 0..<2 {
            let handle = try launcher.launch(socketPath: directory.appendingPathComponent("s").path, clientSecret: String(repeating: "a", count: 64))
            _ = await handle.waitForExit()
        }
        let current = try String(contentsOf: log, encoding: .utf8)
        let previous = try String(contentsOf: directory.appendingPathComponent("Logs/core.previous.log"), encoding: .utf8)
        #expect(current.contains("failed") && previous.contains("failed"))
        #expect(current.contains("tmp=" + FileManager.default.temporaryDirectory.path), "the Core gets the app's temporary directory")
        #expect(!current.contains(String(repeating: "a", count: 64)), "the secret never reaches the log")
    }

    /// Writing the secret to a child that already went away must fail the
    /// launch, not raise SIGPIPE, which would end the test process (and the app).
    @Test
    func writingToAClosedPipeThrowsInsteadOfKillingTheApp() throws {
        let pipe = Pipe()
        try pipe.fileHandleForReading.close()
        #expect(throws: (any Error).self) {
            try ProcessCoreLauncher.writeSecret(String(repeating: "a", count: 64), to: pipe.fileHandleForWriting)
        }
    }
}
