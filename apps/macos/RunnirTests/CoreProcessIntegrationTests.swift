import Darwin
import Foundation
import Testing
@testable import Runnir

/// Runs the real bundled Core and the real gRPC client.
@Suite(.timeLimit(.minutes(1)))
struct CoreProcessIntegrationTests {
    private static func makeSupervisor() -> (CoreProcessSupervisor, socket: String) {
        let dir = "/tmp/rn" + String(UUID().uuidString.prefix(8))
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let socket = dir + "/core.sock"
        let supervisor = CoreProcessSupervisor(
            launcher: ProcessCoreLauncher(executableURL: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/runnir-core")),
            connector: GRPCCoreConnector(),
            socketPath: socket,
            healthTimeout: .seconds(10)
        )
        return (supervisor, socket)
    }

    /// Core processes serving this socket, found by command line.
    private static func coreProcesses(socket: String) -> [Int32] {
        let ps = Process()
        let pipe = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,command="]
        ps.standardOutput = pipe
        try? ps.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            guard line.contains("runnir-core serve"), line.contains(socket) else { return nil }
            return Int32(line.split(separator: " ", maxSplits: 1).first ?? "")
        }
    }

    private static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    private static func tempRepository() throws -> String {
        let dir = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: URL(fileURLWithPath: "/tmp"), create: true)
        let workflows = dir.appendingPathComponent(".github/workflows")
        try FileManager.default.createDirectory(at: workflows, withIntermediateDirectories: true)
        try "name: CI\non: push\njobs:\n  build: {}\n".write(to: workflows.appendingPathComponent("ci.yml"), atomically: true, encoding: .utf8)
        return dir.resolvingSymlinksInPath().path
    }

    @Test
    func theRealCoreValidatesWorkflowsWithActionlint() async throws {
        let (supervisor, _) = Self.makeSupervisor()
        try await supervisor.start()
        let service = try await supervisor.service()
        // "jobs: build: {}" has no runs-on; actionlint reports it.
        let repository = try await service.openRepository(path: try Self.tempRepository())
        let report = try await service.validateWorkflows(repositoryID: repository.id, workflowID: nil)
        #expect(report.validator.hasPrefix("actionlint v"))
        let ci = try #require(report.validation(for: ".github/workflows/ci.yml"))
        #expect(ci.problem == nil)
        #expect(!ci.diagnostics.isEmpty)
        #expect(ci.diagnostics.allSatisfy { $0.line > 0 && !$0.kind.isEmpty })
        await supervisor.stop()
    }

    @Test
    func theRealCoreFindsTheBundledActAndReviewsALocalRun() async throws {
        let (supervisor, _) = Self.makeSupervisor()
        try await supervisor.start()
        let service = try await supervisor.service()
        let readiness = try await service.toolReadiness(refresh: true)
        #expect(readiness.bundledAct.state == .found)
        #expect(readiness.bundledAct.version == readiness.testedActVersion)
        #expect(readiness.bundledAct.path.hasSuffix("Contents/Helpers/act"))
        // With Docker installed, its context shows the Core got the user's home.
        if ["/usr/local/bin/docker", "/opt/homebrew/bin/docker"].contains(where: FileManager.default.isExecutableFile(atPath:)) {
            #expect(readiness.dockerCLI.state == .found)
            #expect(!readiness.engine.context.isEmpty)
        }

        // "jobs: build: {}" has no runs-on, which actionlint's parser reports
        // as a syntax error: the plan is blocked and has no confirmation.
        let repository = try await service.openRepository(path: try Self.tempRepository())
        let prepared = try await service.prepareLocalRun(repositoryID: repository.id, workflowID: ".github/workflows/ci.yml",
                                                         jobID: nil, event: nil, useInstalledAct: false, limits: nil, resetLimits: false)
        #expect(prepared.confirmationID == nil)
        #expect(!prepared.plan.blockers.isEmpty)
        #expect(prepared.plan.blockers.contains { $0.contains("syntax error") })
        #expect(prepared.plan.actVersion == readiness.bundledAct.version)
        await supervisor.stop()
    }

    @Test
    func oneCoreServesRepositoriesAndSurvivesRepeatedStarts() async throws {
        let (supervisor, socket) = Self.makeSupervisor()
        try await supervisor.start()
        try await supervisor.start()
        #expect(Self.coreProcesses(socket: socket).count == 1)

        let service = try await supervisor.service()
        var ids: [String] = []
        for _ in 0..<10 {
            let repository = try await service.openRepository(path: try Self.tempRepository())
            ids.append(repository.id)
        }
        #expect(Set(ids).count == 10)
        #expect(try await service.healthCheck().openRepositoryCount == 10)
        // Reopening is idempotent and a tenth Core never appears.
        let again = try await service.openRepository(path: try Self.tempRepository())
        #expect(!ids.contains(again.id))
        #expect(Self.coreProcesses(socket: socket).count == 1)

        let workflows = try await service.listWorkflows(repositoryID: ids[0])
        #expect(workflows.first?.name == "CI")

        let pids = Self.coreProcesses(socket: socket)
        await supervisor.stop()
        #expect(await eventuallyAsync { !Self.isAlive(pids[0]) })
        #expect(!FileManager.default.fileExists(atPath: socket))
    }

    @Test
    func streamsEventsFromTheCore() async throws {
        let (supervisor, _) = Self.makeSupervisor()
        try await supervisor.start()
        let service = try await supervisor.service()
        var events = service.events(repositoryIDs: []).makeAsyncIterator()
        #expect(try await events.next()?.kind == .ready)
        let repository = try await service.openRepository(path: try Self.tempRepository())
        let event = try await events.next()
        #expect(event?.kind == .repositoryOpened)
        #expect(event?.repositoryID == repository.id)
        await supervisor.stop()
    }

    @Test
    func recoversAfterTheCoreIsKilled() async throws {
        let (supervisor, socket) = Self.makeSupervisor()
        try await supervisor.start()
        let first = try #require(Self.coreProcesses(socket: socket).first)

        kill(first, SIGKILL)
        #expect(await eventuallyAsync { if case .lost = await supervisor.state { true } else { false } })
        await #expect(throws: CoreServiceError.unavailable) { _ = try await supervisor.service() }

        try await supervisor.recover()
        let second = try #require(Self.coreProcesses(socket: socket).first)
        #expect(second != first)
        #expect(Self.coreProcesses(socket: socket).count == 1)
        let repository = try await supervisor.service().openRepository(path: try Self.tempRepository())
        #expect(!repository.id.isEmpty)
        await supervisor.stop()
    }

    @Test
    func aSecondSupervisorOnTheSameSocketIsRefused() async throws {
        let (first, socket) = Self.makeSupervisor()
        try await first.start()
        let second = CoreProcessSupervisor(
            launcher: ProcessCoreLauncher(executableURL: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/runnir-core")),
            connector: GRPCCoreConnector(),
            socketPath: socket,
            healthTimeout: .seconds(10)
        )
        await #expect(throws: CoreSupervisorError.alreadyRunning) { try await second.start() }
        #expect(Self.coreProcesses(socket: socket).count == 1)
        // The first Core is untouched by the refused attempt.
        #expect(try await first.service().healthCheck().protocolVersion == 1)
        await first.stop()
    }

    @Test
    func aClientWithoutTheLaunchSecretIsRefused() async throws {
        let (supervisor, socket) = Self.makeSupervisor()
        try await supervisor.start()
        let intruder = try await GRPCCoreConnector().connect(socketPath: socket, clientSecret: String(repeating: "0", count: 64))
        // Health stays open; everything else needs the secret.
        #expect(try await intruder.service.healthCheck().protocolVersion == 1)
        await #expect(throws: CoreServiceError.self) {
            _ = try await intruder.service.openRepository(path: try Self.tempRepository())
        }
        await intruder.close()
        // The app's own connection keeps working and can hand over a token.
        let service = try await supervisor.service()
        try await service.setGitHubCredential("ghu_test_token")
        _ = try await service.openRepository(path: try Self.tempRepository())
        try await service.setGitHubCredential(nil)
        await supervisor.stop()
    }

    @Test
    func theCoreExitsWhenTheParentSideClosesStdin() async throws {
        let (supervisor, socket) = Self.makeSupervisor()
        try await supervisor.start()
        let pid = try #require(Self.coreProcesses(socket: socket).first)
        supervisor.terminateImmediately()
        #expect(await eventuallyAsync { !Self.isAlive(pid) })
        await supervisor.stop()
    }
}

