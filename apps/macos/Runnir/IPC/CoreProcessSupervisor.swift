import CryptoKit
import Foundation

// MARK: Seams

/// A live connection to a running Core.
protocol CoreConnection: Sendable {
    var service: any CoreServicing { get }
    func close() async
}

protocol CoreConnecting: Sendable {
    /// `clientSecret` is the per-launch secret every call presents.
    func connect(socketPath: String, clientSecret: String) async throws -> any CoreConnection
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
    /// Starts the Core and hands it `clientSecret` (on stdin, never argv or env).
    func launch(socketPath: String, clientSecret: String) throws -> any CoreProcessHandle
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
    /// The socket path does not fit a Unix socket address (103 bytes).
    case socketPathTooLong
}

enum CoreLossReason: Equatable, Sendable {
    case processExited(Int32)
    /// The process was alive but stopped answering health checks; it was stopped.
    case unresponsive
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
    private let livenessInterval: Duration
    private let livenessTimeout: Duration
    private let livenessFailureLimit: Int

    private(set) var state: CoreConnectionState = .stopped {
        didSet { if oldValue != state { for (_, continuation) in observers { continuation.yield(state) } } }
    }
    private var observers: [UUID: AsyncStream<CoreConnectionState>.Continuation] = [:]

    private var process: (any CoreProcessHandle)?
    private var connection: (any CoreConnection)?
    private var monitor: Task<Void, Never>?
    private var liveness: Task<Void, Never>?
    private var startTask: Task<CoreHealth, any Error>?
    private var generation = 0
    private var earlyExit: Int32?
    private var socketIsStale = false
    private nonisolated let quitHandle = QuitHandle()

    /// While running, the Core is asked for its health every
    /// `livenessInterval`; after `livenessFailureLimit` unanswered checks in a
    /// row it counts as lost and is stopped, so a hung process cannot keep the
    /// instance lock and block a restart.
    init(launcher: any CoreProcessLaunching,
         connector: any CoreConnecting,
         socketPath: String,
         healthTimeout: Duration = .seconds(5),
         pollInterval: Duration = .milliseconds(25),
         livenessInterval: Duration = .seconds(15),
         livenessTimeout: Duration = .seconds(3),
         livenessFailureLimit: Int = 2) {
        self.launcher = launcher
        self.connector = connector
        self.socketPath = socketPath
        self.healthTimeout = healthTimeout
        self.pollInterval = pollInterval
        self.livenessInterval = livenessInterval
        self.livenessTimeout = livenessTimeout
        self.livenessFailureLimit = max(1, livenessFailureLimit)
    }

    /// The app's supervisor: bundled helper, gRPC over a socket in the
    /// per-user temporary directory,
    /// and the Core's diagnostics in `logURL`.
    static func bundled() -> CoreProcessSupervisor {
        let bundle = Bundle.main.bundleURL
        return CoreProcessSupervisor(
            launcher: ProcessCoreLauncher(
                executableURL: bundle.appendingPathComponent("Contents/Helpers/runnir-core"),
                logURL: logURL,
                dataDirectory: try? RunnirSupportDirectory.url()
            ),
            connector: GRPCCoreConnector(),
            socketPath: socketPath(in: FileManager.default.temporaryDirectory, instance: instanceTag(for: bundle))
        )
    }

    /// Where the Core's standard error goes: ~/Library/Logs/Runnir/core.log.
    /// The previous launch's log is kept as core.previous.log.
    static let logURL: URL? = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Logs/Runnir/core.log")

    static let maxSocketPathBytes = 103

    /// Tells copies of the app apart (a Debug build, an installed release),
    /// so each runs its own Core instead of finding the other's socket taken.
    static func instanceTag(for bundleURL: URL) -> String {
        SHA256.hash(data: Data(bundleURL.standardizedFileURL.path.utf8))
            .prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// A socket path inside `directory` that fits a Unix socket address: the
    /// descriptive name when it fits, else a short one. A directory too deep
    /// for either yields the descriptive path, and the start fails clearly with
    /// `socketPathTooLong` instead of the Core exiting with a bare status.
    static func socketPath(in directory: URL, instance: String = "") -> String {
        let suffix = instance.isEmpty ? "" : "-" + instance
        for name in ["runnir-core\(suffix).sock", "rc\(suffix).sock"] {
            let path = directory.appendingPathComponent(name).path
            if path.utf8.count <= maxSocketPathBytes { return path }
        }
        return directory.appendingPathComponent("runnir-core\(suffix).sock").path
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
        guard socketPath.utf8.count <= Self.maxSocketPathBytes else { return try await fail(.socketPathTooLong) }
        if socketIsStale {
            // Our own previous Core exited, so its leftover socket is ours to remove.
            unlink(socketPath)
            socketIsStale = false
        }

        // A fresh secret per launch: only this app can use the Core it starts.
        let secret = Self.makeClientSecret()
        let handle: any CoreProcessHandle
        do {
            handle = try launcher.launch(socketPath: socketPath, clientSecret: secret)
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
                connection = try? await connector.connect(socketPath: socketPath, clientSecret: secret)
            }
            if let connection {
                let remaining = deadline - clock.now
                let answer = await Self.bounded(by: min(remaining, .seconds(2))) {
                    try? await connection.service.healthCheck()
                } ?? nil
                // Only the child we launched counts. A different pid means the
                // socket still belongs to another Core, and our child is about to
                // exit with status 3.
                if let health = answer, health.processID == 0 || health.processID == handle.processIdentifier {
                    guard health.protocolVersion == Self.supportedProtocolVersion else {
                        return try await fail(.incompatibleProtocol(health.protocolVersion))
                    }
                    state = .running(health)
                    startLiveness(generation: current, service: connection.service)
                    return health
                }
            }
            if clock.now >= deadline { return try await fail(.timedOut) }
            try? await Task.sleep(for: pollInterval)
        }
    }

    /// 32 random bytes as hex, from the system's cryptographic generator.
    static func makeClientSecret() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }

    /// Runs `operation` but gives up after `limit`, so one stuck call cannot
    /// stall the start loop past its deadline. The operation is cancelled on
    /// timeout; one that ignores cancellation keeps running detached.
    static func bounded<T: Sendable>(by limit: Duration, _ operation: @escaping @Sendable () async -> T) async -> T? {
        let gate = BoundedGate<T>()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            gate.install(continuation)
            let work = Task {
                let value = await operation()
                gate.resume(value)
            }
            Task {
                try? await Task.sleep(for: max(limit, .zero))
                if gate.resume(nil) { work.cancel() }
            }
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

    private func startLiveness(generation current: Int, service: any CoreServicing) {
        liveness?.cancel()
        let interval = livenessInterval, timeout = livenessTimeout, limit = livenessFailureLimit
        liveness = Task { [weak self] in
            var misses = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                let answered = await Self.bounded(by: timeout) { (try? await service.healthCheck()) != nil } ?? false
                misses = answered ? 0 : misses + 1
                if misses >= limit {
                    await self?.becameUnresponsive(generation: current)
                    return
                }
            }
        }
    }

    /// The Core stopped answering while its process lives: report it lost and
    /// stop the process, which also releases its instance lock.
    private func becameUnresponsive(generation current: Int) async {
        guard current == generation, case .running = state else { return }
        let oldConnection = connection
        let oldProcess = process
        liveness = nil
        connection = nil
        process = nil
        quitHandle.clear()
        socketIsStale = true
        state = .lost(.unresponsive)
        await oldConnection?.close()
        await oldProcess?.terminate()
    }

    private func processExited(generation exitedGeneration: Int, status: Int32) async {
        guard exitedGeneration == generation else { return }
        switch state {
        case .running:
            liveness?.cancel()
            liveness = nil
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
        liveness?.cancel()
        liveness = nil
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

/// Resumes a continuation once with whichever result arrives first.
private final class BoundedGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?

    func install(_ continuation: CheckedContinuation<T?, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    /// Returns true when this call delivered the result.
    @discardableResult
    func resume(_ value: T?) -> Bool {
        let pending = lock.withLock { () -> CheckedContinuation<T?, Never>? in
            let current = continuation
            continuation = nil
            return current
        }
        pending?.resume(returning: value)
        return pending != nil
    }
}
