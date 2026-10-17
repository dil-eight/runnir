import Foundation

// MARK: Seams

/// A live connection to a running Core.
protocol CoreConnection: Sendable {
    var service: any CoreServicing { get }
    func close() async
}

protocol CoreConnecting: Sendable {
    func connect(socketPath: String) async throws -> any CoreConnection
}

/// The Core child process. The supervisor owns it; closing our end of its
/// stdin also stops it, so it cannot outlive a crashed app.
protocol CoreProcessHandle: Sendable {
    var processIdentifier: Int32 { get }
    /// Suspends until the process exits and returns its termination status.
    func waitForExit() async -> Int32
    /// Asks for a graceful stop and force-kills after a grace period.
    func terminate() async
    /// Synchronous request to stop, for app termination.
    func terminateNow()
}

protocol CoreProcessLaunching: Sendable {
    func launch(socketPath: String) throws -> any CoreProcessHandle
}

// MARK: State

enum CoreSupervisorError: Error, Equatable, Sendable {
    case helperUnavailable
    /// Another Core already holds the instance lock (helper exit status 3).
    case alreadyRunning
    case timedOut
    case incompatibleProtocol(Int)
    case launchFailed
    case processExited(Int32)
}

enum CoreLossReason: Equatable, Sendable {
    case processExited(Int32)
}

enum CoreConnectionState: Equatable, Sendable {
    case stopped
    case starting
    case running(CoreHealth)
    /// The Core went away while running. Call `recover()` to restart it.
    case lost(CoreLossReason)
    case failed(CoreSupervisorError)
}

// MARK: Supervisor

/// Keeps exactly one Core process for the app: starts it, waits for a
/// successful `HealthCheck`, reports loss, and restarts it on request.
/// Closing a window never touches it; quitting stops it.
actor CoreProcessSupervisor {
    static let helperExitAlreadyRunning: Int32 = 3
    static let supportedProtocolVersion = 1

    private let launcher: any CoreProcessLaunching
    private let connector: any CoreConnecting
    private let socketPath: String
    private let healthTimeout: Duration
    private let pollInterval: Duration

    private(set) var state: CoreConnectionState = .stopped {
        didSet { if oldValue != state { for (_, continuation) in observers { continuation.yield(state) } } }
    }
    private var observers: [UUID: AsyncStream<CoreConnectionState>.Continuation] = [:]

    private var process: (any CoreProcessHandle)?
    private var connection: (any CoreConnection)?
    private var monitor: Task<Void, Never>?
    private var startTask: Task<CoreHealth, any Error>?
    private var generation = 0
    private var earlyExit: Int32?
    private var socketIsStale = false
    private nonisolated let quitHandle = QuitHandle()

    init(launcher: any CoreProcessLaunching,
         connector: any CoreConnecting,
         socketPath: String,
         healthTimeout: Duration = .seconds(5),
         pollInterval: Duration = .milliseconds(25)) {
        self.launcher = launcher
        self.connector = connector
        self.socketPath = socketPath
        self.healthTimeout = healthTimeout
        self.pollInterval = pollInterval
    }

    /// The app's supervisor: bundled helper, gRPC over a socket in the
    /// per-user temporary directory (inside the container when sandboxed).
    static func bundled() -> CoreProcessSupervisor {
        CoreProcessSupervisor(
            launcher: ProcessCoreLauncher(
                executableURL: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/runnir-core")
            ),
            connector: GRPCCoreConnector(),
            socketPath: FileManager.default.temporaryDirectory.appendingPathComponent("runnir-core.sock").path
        )
    }

    /// Emits the current state first, then every change.
    func states() -> AsyncStream<CoreConnectionState> {
        let (stream, continuation) = AsyncStream.makeStream(of: CoreConnectionState.self, bufferingPolicy: .bufferingNewest(8))
        let id = UUID()
        observers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    /// Starts the Core, or returns the health of the one already running.
    /// Concurrent callers share one start. From `.lost` or `.failed` it
    /// replaces the old process.
    @discardableResult
    func start() async throws -> CoreHealth {
        if case .running(let health) = state { return health }
        if let startTask { return try await startTask.value }
        let task = Task { try await self.performStart() }
        startTask = task
        defer { startTask = nil }
        return try await task.value
    }

    /// Restarts after `.lost` or `.failed`; the same as `start()`.
    @discardableResult
    func recover() async throws -> CoreHealth { try await start() }

    func stop() async {
        generation += 1
        if let startTask {
            startTask.cancel()
            _ = try? await startTask.value
        }
        await teardown()
        state = .stopped
    }

    /// The service for the running Core; throws when it is not available.
    func service() throws -> any CoreServicing {
        guard case .running = state, let connection else { throw CoreServiceError.unavailable }
        return connection.service
    }

    /// Stops the child without awaiting anything; for `applicationWillTerminate`.
    nonisolated func terminateImmediately() { quitHandle.terminate() }

    // MARK: Start

    private func performStart() async throws -> CoreHealth {
        generation += 1
        let current = generation
        await teardown()
        state = .starting
        earlyExit = nil
        if socketIsStale {
            // Our own previous Core exited, so its leftover socket is ours to remove.
            unlink(socketPath)
            socketIsStale = false
        }

        let handle: any CoreProcessHandle
        do {
            handle = try launcher.launch(socketPath: socketPath)
        } catch let error as CoreSupervisorError {
            return try await fail(error)
        } catch {
            return try await fail(.launchFailed)
        }
        process = handle
        quitHandle.set(handle)
        monitor = Task { [weak self] in
            let status = await handle.waitForExit()
            await self?.processExited(generation: current, status: status)
        }

        let clock = ContinuousClock()
        let deadline = clock.now + healthTimeout
        while true {
            if Task.isCancelled || current != generation {
                await teardown()
                throw CancellationError()
            }
            if let status = earlyExit {
                return try await fail(status == Self.helperExitAlreadyRunning ? .alreadyRunning : .processExited(status))
            }
            if connection == nil, FileManager.default.fileExists(atPath: socketPath) {
                connection = try? await connector.connect(socketPath: socketPath)
            }
            if let connection {
                let answer = try? await connection.service.healthCheck()
                // Only the child we launched counts. A different pid means the
                // socket still belongs to another Core, and our child is about to
                // exit with status 3.
                if let health = answer, health.processID == 0 || health.processID == handle.processIdentifier {
                    guard health.protocolVersion == Self.supportedProtocolVersion else {
                        return try await fail(.incompatibleProtocol(health.protocolVersion))
                    }
                    state = .running(health)
                    return health
                }
            }
            if clock.now >= deadline { return try await fail(.timedOut) }
            try? await Task.sleep(for: pollInterval)
        }
    }

    private func fail(_ error: CoreSupervisorError) async throws -> CoreHealth {
        let launched = process != nil
        await teardown()
        // After our own Core was stopped its socket is stale. If the helper
        // refused to start because another Core is live, the socket is theirs.
        socketIsStale = launched && error != .alreadyRunning
        state = .failed(error)
        throw error
    }

    private func processExited(generation exitedGeneration: Int, status: Int32) async {
        guard exitedGeneration == generation else { return }
        switch state {
        case .running:
            let old = connection
            connection = nil
            process = nil
            quitHandle.clear()
            socketIsStale = true
            state = .lost(.processExited(status))
            await old?.close()
        case .starting:
            earlyExit = status
        default:
            break
        }
    }

    private func teardown() async {
        monitor?.cancel()
        monitor = nil
        let oldConnection = connection
        let oldProcess = process
        connection = nil
        process = nil
        quitHandle.clear()
        await oldConnection?.close()
        await oldProcess?.terminate()
    }
}

/// Lets the app stop the child synchronously during termination, where the
/// actor cannot be awaited.
private final class QuitHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: (any CoreProcessHandle)?

    func set(_ new: any CoreProcessHandle) { lock.lock(); handle = new; lock.unlock() }
    func clear() { lock.lock(); handle = nil; lock.unlock() }
    func terminate() {
        lock.lock()
        let current = handle
        lock.unlock()
        current?.terminateNow()
    }
}
