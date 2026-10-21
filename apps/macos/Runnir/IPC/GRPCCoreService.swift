import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import SwiftProtobuf

/// One live gRPC channel to a Core over a Unix domain socket.
final class GRPCCoreConnection: CoreConnection, @unchecked Sendable {
    private typealias Client = Runnir_Core_V1_RunnirCore.Client<HTTP2ClientTransport.Posix>

    let service: any CoreServicing
    private let grpcClient: GRPCClient<HTTP2ClientTransport.Posix>
    private let runTask: Task<Void, Never>

    init(socketPath: String, clientSecret: String) throws {
        let transport = try HTTP2ClientTransport.Posix(
            target: .unixDomainSocket(path: socketPath),
            transportSecurity: .plaintext
        )
        let grpcClient = GRPCClient(transport: transport, interceptors: [ClientSecretInterceptor(secret: clientSecret)])
        self.grpcClient = grpcClient
        self.runTask = Task { try? await grpcClient.runConnections() }
        self.service = GRPCCoreService(client: Runnir_Core_V1_RunnirCore.Client(wrapping: grpcClient))
    }

    /// Open event streams would keep a graceful shutdown waiting forever, so
    /// give it a moment and then cancel the connection outright.
    func close() async {
        grpcClient.beginGracefulShutdown()
        let task = runTask
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await task.value }
            group.addTask { try? await Task.sleep(for: .seconds(1)); task.cancel() }
            await group.next()
            group.cancelAll()
        }
        task.cancel()
    }
}

struct GRPCCoreConnector: CoreConnecting {
    func connect(socketPath: String, clientSecret: String) async throws -> any CoreConnection {
        try GRPCCoreConnection(socketPath: socketPath, clientSecret: clientSecret)
    }
}

/// Adds the per-launch client secret to every call.
struct ClientSecretInterceptor: ClientInterceptor {
    let secret: String

    func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingClientRequest<Input>,
        context: ClientContext,
        next: (StreamingClientRequest<Input>, ClientContext) async throws -> StreamingClientResponse<Output>
    ) async throws -> StreamingClientResponse<Output> {
        var request = request
        request.metadata.replaceOrAddString("Bearer \(secret)", forKey: "authorization")
        return try await next(request, context)
    }
}

struct GRPCCoreService: CoreServicing {
    fileprivate let client: Runnir_Core_V1_RunnirCore.Client<HTTP2ClientTransport.Posix>

    /// Every unary call has a deadline so a stuck peer cannot hang the caller.
    /// Health is short because the supervisor polls it; scans may take longer.
    static let healthTimeout: Duration = .seconds(2)
    static let callTimeout: Duration = .seconds(30)

    private static func options(_ timeout: Duration) -> CallOptions {
        var options = CallOptions.defaults
        options.timeout = timeout
        return options
    }

    func healthCheck() async throws -> CoreHealth {
        let response = try await call { try await client.healthCheck(.init(), options: Self.options(Self.healthTimeout)) }
        return CoreHealth(
            coreVersion: response.coreVersion,
            protocolVersion: Int(response.protocolVersion),
            openRepositoryCount: Int(response.openRepositoryCount),
            residentMemoryBytes: response.residentMemoryBytes,
            processID: Int32(truncatingIfNeeded: response.processID)
        )
    }

    func openRepository(path: String) async throws -> CoreRepository {
        let response = try await call { try await client.openRepository(.with { $0.path = path }, options: Self.options(Self.callTimeout)) }
        return Self.map(response.repository)
    }

    func refreshRepository(id: String) async throws -> CoreRepository {
        let response = try await call { try await client.refreshRepository(.with { $0.repositoryID = id }, options: Self.options(Self.callTimeout)) }
        return Self.map(response.repository)
    }

    func closeRepository(id: String) async throws {
        _ = try await call { try await client.closeRepository(.with { $0.repositoryID = id }, options: Self.options(Self.callTimeout)) }
    }

    func listWorkflows(repositoryID: String) async throws -> [CoreWorkflow] {
        let response = try await call { try await client.listWorkflows(.with { $0.repositoryID = repositoryID }, options: Self.options(Self.callTimeout)) }
        return response.workflows.map { workflow in
            CoreWorkflow(
                id: workflow.id,
                name: workflow.name,
                triggers: workflow.triggers,
                jobs: workflow.jobs.map { CoreJob(id: $0.id, name: $0.name, needs: $0.needs) },
                parseError: workflow.parseError.isEmpty ? nil : workflow.parseError
            )
        }
    }

    func validateWorkflows(repositoryID: String, workflowID: String?) async throws -> CoreValidationReport {
        let response = try await call {
            try await client.validateWorkflows(.with {
                $0.repositoryID = repositoryID
                $0.workflowID = workflowID ?? ""
            }, options: Self.options(Self.callTimeout))
        }
        return CoreValidationReport(
            workflows: response.workflows.map { workflow in
                CoreWorkflowValidation(
                    workflowID: workflow.workflowID,
                    diagnostics: workflow.diagnostics.map {
                        CoreWorkflowDiagnostic(line: Int($0.line), column: Int($0.column), kind: $0.kind, message: $0.message)
                    },
                    problem: workflow.problem.isEmpty ? nil : workflow.problem,
                    truncated: workflow.truncated
                )
            },
            validator: response.validator,
            configProblem: response.configProblem.isEmpty ? nil : response.configProblem
        )
    }

    func startWorkflow(repositoryID: String, workflowID: String, ref: String?) async throws -> CoreExecution {
        let response = try await call {
            try await client.startWorkflow(.with {
                $0.repositoryID = repositoryID
                $0.workflowID = workflowID
                $0.ref = ref ?? ""
            }, options: Self.options(Self.callTimeout))
        }
        return CoreExecution(id: response.executionID, repositoryID: response.repositoryID, state: Self.map(response.state))
    }

    func saveWorkflowFile(repositoryID: String, workflowID: String, content: String, baseSHA256: String,
                          overwrite: Bool) async throws -> CoreWorkflowSave {
        var options = Self.options(Self.callTimeout)
        options.maxRequestMessageBytes = 4 << 20
        let response = try await call {
            try await client.saveWorkflowFile(.with {
                $0.repositoryID = repositoryID
                $0.workflowID = workflowID
                $0.content = content
                $0.baseSha256 = baseSHA256
                $0.overwrite = overwrite
            }, options: options)
        }
        return CoreWorkflowSave(sha256: response.sha256, conflict: response.conflict)
    }

    func createWorkflowFile(repositoryID: String, fileName: String, content: String) async throws -> String {
        var options = Self.options(Self.callTimeout)
        options.maxRequestMessageBytes = 4 << 20
        let response = try await call {
            try await client.createWorkflowFile(.with {
                $0.repositoryID = repositoryID
                $0.fileName = fileName
                $0.content = content
            }, options: options)
        }
        return response.workflowID
    }

    func renameWorkflowFile(repositoryID: String, workflowID: String, newFileName: String) async throws -> String {
        let response = try await call {
            try await client.renameWorkflowFile(.with {
                $0.repositoryID = repositoryID
                $0.workflowID = workflowID
                $0.newFileName = newFileName
            }, options: Self.options(Self.callTimeout))
        }
        return response.workflowID
    }

    func setGitHubCredential(_ token: String?) async throws {
        if let token {
            _ = try await call { try await client.setGitHubCredential(.with { $0.token = token }, options: Self.options(Self.callTimeout)) }
        } else {
            _ = try await call { try await client.clearGitHubCredential(.init(), options: Self.options(Self.callTimeout)) }
        }
    }

    func githubOrigins(paths: [String]) async throws -> [String: String] {
        let response = try await call {
            try await client.getGitHubOrigins(.with { $0.paths = paths }, options: Self.options(Self.callTimeout))
        }
        return Dictionary(response.origins.map { ($0.path, $0.githubRepository) }, uniquingKeysWith: { first, _ in first })
    }

    func listGitHubRepositories() async throws -> CoreGitHubAccount {
        // Up to 1,000 repositories over several GitHub pages.
        var options = Self.options(.seconds(60))
        options.maxResponseMessageBytes = 8 << 20
        let response = try await call { try await client.listGitHubRepositories(.init(), options: options) }
        return CoreGitHubAccount(
            access: Self.map(response.status),
            installations: response.installations.map(Self.map),
            repositories: response.repositories.map {
                CoreGitHubAccountRepository(fullName: $0.fullName, owner: $0.owner, name: $0.name, description: $0.description_p,
                                            visibility: $0.visibility, defaultBranch: $0.defaultBranch, htmlURL: URL(string: $0.htmlURL),
                                            pushedAt: $0.hasPushedAt ? $0.pushedAt.date : nil, archived: $0.archived, fork: $0.fork,
                                            canPush: $0.canPush, installationID: $0.installationID)
            },
            truncated: response.truncated)
    }

    func listGitHubWorkflows(target: CoreGitHubTarget) async throws -> CoreGitHubResult<CoreGitHubWorkflow> {
        let response = try await call {
            try await client.listGitHubWorkflows(.with {
                switch target {
                case .repository(let id): $0.repositoryID = id
                case .named(let name): $0.githubRepository = name
                }
            }, options: Self.options(Self.callTimeout))
        }
        return CoreGitHubResult(access: Self.map(response.status), items: response.workflows.map {
            CoreGitHubWorkflow(id: $0.id, name: $0.name, path: $0.path, state: $0.state, htmlURL: URL(string: $0.htmlURL))
        })
    }

    func gitHubRepository(target: CoreGitHubTarget) async throws -> CoreGitHubRepository {
        let response = try await call {
            try await client.getGitHubRepository(.with {
                switch target {
                case .repository(let id): $0.repositoryID = id
                case .named(let name): $0.githubRepository = name
                }
            }, options: Self.options(Self.callTimeout))
        }
        return CoreGitHubRepository(access: Self.map(response.status), fullName: response.fullName, visibility: response.visibility,
                                    defaultBranch: response.defaultBranch, htmlURL: URL(string: response.htmlURL),
                                    canPush: response.canPush, installation: response.hasInstallation ? Self.map(response.installation) : nil)
    }

    static func map(_ installation: Runnir_Core_V1_GitHubInstallation) -> CoreGitHubInstallation {
        CoreGitHubInstallation(id: installation.id, account: installation.account, accountType: installation.accountType,
                               repositorySelection: installation.repositorySelection, htmlURL: URL(string: installation.htmlURL),
                               missingPermissions: installation.missingPermissions, suspended: installation.suspended)
    }

    func listWorkflowRuns(target: CoreGitHubTarget, branch: String?, limit: Int) async throws -> CoreGitHubResult<CoreWorkflowRun> {
        let response = try await call {
            try await client.listWorkflowRuns(.with {
                switch target {
                case .repository(let id): $0.repositoryID = id
                case .named(let name): $0.githubRepository = name
                }
                $0.branch = branch ?? ""
                $0.limit = UInt32(clamping: max(0, min(limit, 100)))
            }, options: Self.options(Self.callTimeout))
        }
        return CoreGitHubResult(access: Self.map(response.status), items: response.runs.map(Self.map))
    }

    static func map(_ run: Runnir_Core_V1_WorkflowRun) -> CoreWorkflowRun {
        CoreWorkflowRun(
            id: run.id, workflowID: run.workflowID, name: run.name, displayTitle: run.displayTitle,
            runNumber: run.runNumber, event: run.event, status: run.status,
            conclusion: run.conclusion.isEmpty ? nil : run.conclusion, branch: run.branch, headSHA: run.headSha,
            actor: run.actor.isEmpty ? nil : run.actor, htmlURL: URL(string: run.htmlURL),
            createdAt: run.hasCreatedAt ? run.createdAt.date : nil,
            updatedAt: run.hasUpdatedAt ? run.updatedAt.date : nil,
            runAttempt: max(1, run.runAttempt)
        )
    }

    func listRunJobs(repositoryID: String, runID: Int64) async throws -> CoreGitHubResult<CoreRunJob> {
        let response = try await call {
            try await client.listRunJobs(.with {
                $0.repositoryID = repositoryID
                $0.runID = runID
            }, options: Self.options(Self.callTimeout))
        }
        return CoreGitHubResult(access: Self.map(response.status), items: response.jobs.map { job in
            CoreRunJob(
                id: job.id, name: job.name, status: job.status, conclusion: job.conclusion.isEmpty ? nil : job.conclusion,
                startedAt: job.hasStartedAt ? job.startedAt.date : nil,
                completedAt: job.hasCompletedAt ? job.completedAt.date : nil,
                htmlURL: URL(string: job.htmlURL),
                steps: job.steps.map { step in
                    CoreRunStep(number: step.number, name: step.name, status: step.status,
                                conclusion: step.conclusion.isEmpty ? nil : step.conclusion,
                                startedAt: step.hasStartedAt ? step.startedAt.date : nil,
                                completedAt: step.hasCompletedAt ? step.completedAt.date : nil)
                }
            )
        })
    }

    func listGitHubRefs(target: CoreGitHubTarget) async throws -> CoreGitHubRefs {
        let response = try await call {
            try await client.listGitHubRefs(.with {
                switch target {
                case .repository(let id): $0.repositoryID = id
                case .named(let name): $0.githubRepository = name
                }
            }, options: Self.options(Self.callTimeout))
        }
        return CoreGitHubRefs(access: Self.map(response.status), defaultBranch: response.defaultBranch,
                              branches: response.branches, tags: response.tags)
    }

    func describeWorkflowDispatch(target: CoreGitHubTarget, workflowPath: String, ref: String) async throws -> CoreDispatchDefinition {
        let response = try await call {
            try await client.describeWorkflowDispatch(.with {
                switch target {
                case .repository(let id): $0.repositoryID = id
                case .named(let name): $0.githubRepository = name
                }
                $0.workflowPath = workflowPath
                $0.ref = ref
            }, options: Self.options(Self.callTimeout))
        }
        return CoreDispatchDefinition(
            access: Self.map(response.status),
            dispatchable: response.dispatchable,
            inputs: response.inputs.map { input in
                let kind: CoreDispatchInputKind = switch input.type {
                case .boolean: .boolean
                case .choice: .choice
                case .number: .number
                case .environment: .environment
                default: .string
                }
                return CoreDispatchInput(name: input.name, description: input.description_p, kind: kind,
                                         required: input.required, defaultValue: input.defaultValue, options: input.options)
            },
            parseError: response.parseError.isEmpty ? nil : response.parseError
        )
    }

    func prepareWorkflowDispatch(target: CoreGitHubTarget, workflowID: Int64, ref: String, inputs: [String: String]) async throws -> CorePreparedDispatch {
        let response = try await call {
            try await client.prepareWorkflowDispatch(.with {
                switch target {
                case .repository(let id): $0.repositoryID = id
                case .named(let name): $0.githubRepository = name
                }
                $0.workflowID = workflowID
                $0.ref = ref
                $0.inputs = inputs
            }, options: Self.options(Self.callTimeout))
        }
        return CorePreparedDispatch(
            access: Self.map(response.status),
            dispatchID: response.dispatchID.isEmpty ? nil : response.dispatchID,
            expiresAt: response.hasExpiresAt ? response.expiresAt.date : nil,
            problems: response.problems,
            workflowPath: response.workflowPath
        )
    }

    func confirmWorkflowDispatch(dispatchID: String) async throws -> CoreDispatchResult {
        let response = try await call {
            try await client.confirmWorkflowDispatch(.with { $0.dispatchID = dispatchID }, options: Self.options(Self.callTimeout))
        }
        return CoreDispatchResult(
            access: Self.map(response.status),
            dispatchedAt: response.hasDispatchedAt ? response.dispatchedAt.date : nil,
            runID: response.runID == 0 ? nil : response.runID,
            rejection: response.rejection.isEmpty ? nil : response.rejection
        )
    }

    /// A log of up to 50,000 lines can exceed gRPC's default 4 MiB message
    /// limit on the wire, so this call allows more.
    func jobLog(repositoryID: String, jobID: Int64) async throws -> CoreJobLog {
        var options = Self.options(.seconds(150))
        options.maxRequestMessageBytes = 16 << 20
        options.maxResponseMessageBytes = 16 << 20
        let response = try await call {
            try await client.getJobLog(.with {
                $0.repositoryID = repositoryID
                $0.jobID = jobID
            }, options: options)
        }
        let availability: CoreJobLogAvailability = switch response.availability {
        case .expired: .expired
        case .notReady: .notReady
        default: .available
        }
        return CoreJobLog(
            access: Self.map(response.status), availability: availability,
            lines: response.lines.map { line in
                let kind: CoreLogLineKind = switch line.kind {
                case .error: .error
                case .warning: .warning
                case .notice: .notice
                case .command: .command
                case .group: .group
                case .endGroup: .endGroup
                case .debug: .debug
                default: .plain
                }
                return CoreLogLine(number: line.number, text: line.text, kind: kind, stepNumber: line.stepNumber)
            },
            truncated: response.truncated,
            stoppedEarly: response.stoppedEarly
        )
    }

    func prepareRunAction(repositoryID: String, runID: Int64, action: CoreRunAction) async throws -> CorePreparedRunAction {
        let response = try await call {
            try await client.prepareRunAction(.with {
                $0.repositoryID = repositoryID
                $0.runID = runID
                $0.action = switch action {
                case .cancel: .cancel
                case .rerun: .rerun
                case .rerunFailed: .rerunFailed
                }
            }, options: Self.options(Self.callTimeout))
        }
        return CorePreparedRunAction(
            access: Self.map(response.status),
            actionID: response.actionID.isEmpty ? nil : response.actionID,
            expiresAt: response.hasExpiresAt ? response.expiresAt.date : nil,
            problems: response.problems,
            run: response.hasRun ? Self.map(response.run) : nil
        )
    }

    func confirmRunAction(actionID: String) async throws -> CoreRunActionResult {
        let response = try await call {
            try await client.confirmRunAction(.with { $0.actionID = actionID }, options: Self.options(Self.callTimeout))
        }
        return CoreRunActionResult(
            access: Self.map(response.status),
            acceptedAt: response.hasAcceptedAt ? response.acceptedAt.date : nil,
            rejection: response.rejection.isEmpty ? nil : response.rejection
        )
    }

    // MARK: Local runs

    func toolReadiness(refresh: Bool) async throws -> CoreToolReadiness {
        // Checking the engine runs a few docker commands with their own timeouts.
        let response = try await call {
            try await client.getToolReadiness(.with { $0.refresh = refresh }, options: Self.options(.seconds(45)))
        }
        return Self.map(response.readiness)
    }

    func prepareLocalRun(repositoryID: String, workflowID: String, jobID: String?, event: String?,
                         useInstalledAct: Bool) async throws -> CorePreparedLocalRun {
        let response = try await call {
            try await client.prepareLocalRun(.with {
                $0.repositoryID = repositoryID
                $0.workflowID = workflowID
                $0.jobID = jobID ?? ""
                $0.event = event ?? ""
                $0.useInstalledAct = useInstalledAct
            }, options: Self.options(.seconds(90)))
        }
        return CorePreparedLocalRun(
            readiness: Self.map(response.readiness), plan: Self.map(response.plan),
            confirmationID: response.confirmationID.isEmpty ? nil : response.confirmationID,
            expiresAt: response.hasExpiresAt ? response.expiresAt.date : nil
        )
    }

    func confirmLocalRun(confirmationID: String) async throws -> CoreExecution {
        let response = try await call {
            try await client.confirmLocalRun(.with { $0.confirmationID = confirmationID }, options: Self.options(Self.callTimeout))
        }
        return CoreExecution(id: response.execution.executionID, repositoryID: response.execution.repositoryID,
                             state: Self.map(response.execution.state))
    }

    func localRunOutput(executionID: String, after: UInt64) async throws -> CoreLocalRunOutput {
        var options = Self.options(Self.callTimeout)
        // 5,000 lines of up to 4 KiB each can exceed gRPC's 4 MiB default.
        options.maxResponseMessageBytes = 32 << 20
        let response = try await call {
            try await client.getLocalRunOutput(.with {
                $0.executionID = executionID
                $0.afterSequence = after
            }, options: options)
        }
        let phase: CoreLocalRunPhase = switch response.phase {
        case .queued: .queued
        case .running: .running
        case .stopping: .stopping
        case .cleaningUp: .cleaningUp
        case .finished: .finished
        default: .unknown
        }
        return CoreLocalRunOutput(
            executionID: response.executionID, repositoryID: response.repositoryID,
            state: Self.map(response.state), phase: phase,
            lines: response.lines.map { CoreLocalRunLine(sequence: $0.sequence, jobID: $0.jobID, text: $0.text, isError: $0.error) },
            discarded: response.discarded, lastSequence: response.lastSequence,
            jobs: response.jobs.map { job in
                let state: CoreLocalJobState = switch job.state {
                case .waiting: .waiting
                case .running: .running
                case .succeeded: .succeeded
                case .failed: .failed
                case .skipped: .skipped
                case .unsupported: .unsupported
                case .cancelled: .cancelled
                case .notRun: .notRun
                default: .unknown
                }
                return CoreLocalRunJobStatus(id: job.id, name: job.name, state: state, reason: job.reason,
                                             startedAt: job.hasStartedAt ? job.startedAt.date : nil,
                                             finishedAt: job.hasFinishedAt ? job.finishedAt.date : nil)
            },
            plan: Self.map(response.plan),
            startedAt: response.hasStartedAt ? response.startedAt.date : nil,
            finishedAt: response.hasFinishedAt ? response.finishedAt.date : nil,
            exitCode: response.exitCode < 0 ? nil : Int(response.exitCode),
            message: response.message.isEmpty ? nil : response.message,
            cleanupProblem: response.cleanupProblem.isEmpty ? nil : response.cleanupProblem
        )
    }

    func cancelExecution(executionID: String) async throws {
        _ = try await call {
            try await client.cancelExecution(.with { $0.executionID = executionID }, options: Self.options(Self.callTimeout))
        }
    }

    static func map(_ state: Runnir_Core_V1_ToolState) -> CoreToolState {
        switch state {
        case .found: .found
        case .missing: .missing
        case .stopped: .stopped
        case .unsupported: .unsupported
        case .failed: .failed
        default: .unknown
        }
    }

    static func map(_ tool: Runnir_Core_V1_ToolStatus) -> CoreToolStatus {
        CoreToolStatus(state: map(tool.state), version: tool.version, path: tool.path, detail: tool.detail, untested: tool.untested)
    }

    static func map(_ readiness: Runnir_Core_V1_ToolReadiness) -> CoreToolReadiness {
        let engine = readiness.engine
        return CoreToolReadiness(
            bundledAct: map(readiness.bundledAct), installedAct: map(readiness.installedAct), dockerCLI: map(readiness.dockerCli),
            engine: CoreContainerEngine(state: map(engine.state), name: engine.name, context: engine.context, endpoint: engine.endpoint,
                                        local: engine.local, version: engine.version, architecture: engine.architecture,
                                        cpus: Int(engine.cpus), memoryBytes: engine.memoryBytes, detail: engine.detail),
            checkedAt: readiness.hasCheckedAt ? readiness.checkedAt.date : nil,
            testedActVersion: readiness.testedActVersion, minimumActVersion: readiness.minimumActVersion
        )
    }

    static func map(_ plan: Runnir_Core_V1_LocalRunPlan) -> CoreLocalRunPlan {
        CoreLocalRunPlan(
            workflowID: plan.workflowID, workflowName: plan.workflowName, events: plan.events, event: plan.event, jobID: plan.jobID,
            jobs: plan.jobs.map { job in
                let support: CoreLocalJobSupport = switch job.support {
                case .supported: .supported
                case .unsupported: .unsupported
                default: .unknown
                }
                return CoreLocalRunJob(id: job.id, name: job.name, runsOn: job.runsOn, image: job.image, support: support, reason: job.reason)
            },
            images: plan.images.map { CoreLocalRunImage(reference: $0.reference, present: $0.present) },
            secrets: plan.secrets, notes: plan.notes, blockers: plan.blockers,
            cpus: Int(plan.cpus), memoryBytes: plan.memoryBytes, timeoutSeconds: Int(plan.timeoutSeconds),
            actVersion: plan.actVersion, installedAct: plan.installedAct, engineName: plan.engineName, engineContext: plan.engineContext
        )
    }

    static func map(_ status: Runnir_Core_V1_GitHubStatus) -> CoreGitHubAccess {
        switch status.access {
        case .ok: .ok
        case .noRemote: .noRemote
        case .signedOut: .signedOut
        case .tokenRejected: .tokenRejected
        case .notVisible: .notVisible
        case .permissionMissing: .permissionMissing
        case .rateLimited: .rateLimited(until: status.hasRetryAfter ? status.retryAfter.date : nil)
        default: .unavailable
        }
    }

    func events(repositoryIDs: [String]) -> AsyncThrowingStream<CoreEvent, any Error> {
        let client = client
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await client.subscribeEvents(.with { $0.repositoryIds = repositoryIDs }) { response in
                        for try await message in response.messages {
                            continuation.yield(Self.map(message))
                        }
                    }
                    continuation.finish(throwing: CoreServiceError.unavailable)
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Mapping

    private func call<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as CoreServiceError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.map(error)
        }
    }

    static func map(_ error: any Error) -> CoreServiceError {
        guard let rpc = error as? RPCError else { return .unavailable }
        switch rpc.code {
        case .notFound: return .notFound
        case .invalidArgument: return .invalidArgument(rpc.message)
        case .failedPrecondition: return .failedPrecondition(rpc.message)
        case .alreadyExists: return .alreadyExists(rpc.message)
        case .resourceExhausted: return .resourceExhausted
        case .permissionDenied: return .accessDenied
        case .deadlineExceeded: return .timedOut
        case .unavailable, .cancelled: return .unavailable
        default: return .remote(code: rpc.code.rawValue, message: rpc.message)
        }
    }

    static func map(_ repository: Runnir_Core_V1_Repository) -> CoreRepository {
        CoreRepository(
            id: repository.id,
            path: repository.path,
            branch: repository.branch,
            workflowCount: Int(repository.workflowCount),
            lastRefresh: repository.hasLastRefresh ? repository.lastRefresh.date : nil,
            githubRepository: repository.githubRepository.isEmpty ? nil : repository.githubRepository
        )
    }

    static func map(_ state: Runnir_Core_V1_ExecutionState) -> CoreExecutionState {
        switch state {
        case .queued: .queued
        case .running: .running
        case .succeeded: .succeeded
        case .failed: .failed
        case .cancelled: .cancelled
        default: .unspecified
        }
    }

    static func map(_ event: Runnir_Core_V1_CoreEvent) -> CoreEvent {
        let kind: CoreEventKind = switch event.type {
        case .coreReady: .ready
        case .repositoryOpened: .repositoryOpened
        case .repositoryRefreshed: .repositoryRefreshed
        case .repositoryClosed: .repositoryClosed
        case .workflowStarted: .workflowStarted
        case .workflowStatusChanged: .workflowStatusChanged
        case .workflowCompleted: .workflowCompleted
        case .workflowFailed: .workflowFailed
        case .coreError: .coreError
        default: .unknown
        }
        return CoreEvent(
            sequence: event.sequence,
            kind: kind,
            repositoryID: event.repositoryID.isEmpty ? nil : event.repositoryID,
            executionID: event.executionID.isEmpty ? nil : event.executionID,
            executionState: map(event.executionState),
            message: event.message.isEmpty ? nil : event.message,
            date: event.hasOccurredAt ? event.occurredAt.date : Date()
        )
    }
}
