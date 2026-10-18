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

    init(socketPath: String) throws {
        let transport = try HTTP2ClientTransport.Posix(
            target: .unixDomainSocket(path: socketPath),
            transportSecurity: .plaintext
        )
        let grpcClient = GRPCClient(transport: transport)
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
    func connect(socketPath: String) async throws -> any CoreConnection {
        try GRPCCoreConnection(socketPath: socketPath)
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
        case .resourceExhausted: return .resourceExhausted
        case .permissionDenied: return .accessDenied
        case .unavailable, .cancelled, .deadlineExceeded: return .unavailable
        default: return .remote(code: rpc.code.rawValue, message: rpc.message)
        }
    }

    static func map(_ repository: Runnir_Core_V1_Repository) -> CoreRepository {
        CoreRepository(
            id: repository.id,
            path: repository.path,
            branch: repository.branch,
            workflowCount: Int(repository.workflowCount),
            lastRefresh: repository.hasLastRefresh ? repository.lastRefresh.date : nil
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
