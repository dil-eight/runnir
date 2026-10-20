import Foundation
import Darwin

/// Launches the bundled helper with Foundation `Process`: no shell, a reduced
/// environment, and a stdin pipe whose closing stops the Core. Its standard
/// error goes to `logURL` when given; the Core never writes credentials there.
struct ProcessCoreLauncher: CoreProcessLaunching {
    let executableURL: URL
    var logURL: URL? = nil

    func launch(socketPath: String, clientSecret: String) throws -> any CoreProcessHandle {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw CoreSupervisorError.helperUnavailable
        }
        let process = Process()
        let stdin = Pipe()
        process.executableURL = executableURL
        process.arguments = ["serve", "--socket", socketPath, "--exit-on-stdin-eof", "--client-secret-stdin"]
        // TMPDIR keeps the Core's temporary files in the per-user temporary
        // directory; the reduced environment would otherwise leave Go on /tmp.
        // HOME lets the Core find the user's Docker contexts and its cache for
        // local runs; nothing else from the app's environment is passed on.
        process.environment = ["LANG": "C", "TMPDIR": FileManager.default.temporaryDirectory.path, "HOME": NSHomeDirectory()]
        process.currentDirectoryURL = executableURL.deletingLastPathComponent()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = logURL.flatMap(Self.openLog) ?? FileHandle.nullDevice

        let handle = ProcessCoreHandle(process: process, stdin: stdin)
        process.terminationHandler = { finished in handle.markExited(finished.terminationStatus) }
        do {
            try process.run()
        } catch {
            throw CoreSupervisorError.launchFailed
        }
        try? stdin.fileHandleForReading.close() // the child holds its own copy
        do {
            // The secret goes over the pipe; the write end then stays open so the
            // Core notices when this app goes away.
            try Self.writeSecret(clientSecret, to: stdin.fileHandleForWriting)
        } catch {
            handle.terminateNow()
            throw CoreSupervisorError.launchFailed
        }
        return handle
    }

    /// Starts a fresh log for this launch and keeps the previous one, which
    /// holds what a Core that just failed wrote. nil when it cannot be created.
    static func openLog(at url: URL) -> FileHandle? {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let previous = url.deletingPathExtension().appendingPathExtension("previous.log")
            if manager.fileExists(atPath: url.path) {
                try? manager.removeItem(at: previous)
                try? manager.moveItem(at: url, to: previous)
            }
            guard manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return nil }
            return try FileHandle(forWritingTo: url)
        } catch {
            return nil
        }
    }

    /// Writes the secret line. A child that already exited has closed its
    /// end; without F_SETNOSIGPIPE that write would raise SIGPIPE and end the
    /// app instead of failing the launch.
    static func writeSecret(_ secret: String, to handle: FileHandle) throws {
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        try handle.write(contentsOf: Data((secret + "\n").utf8))
    }
}

final class ProcessCoreHandle: CoreProcessHandle, @unchecked Sendable {
    private let process: Process
    private let stdin: Pipe
    private let gracePeriod: Duration
    private let lock = NSLock()
    private var exitStatus: Int32?
    private var waiters: [UUID: (Int32?) -> Void] = [:]

    init(process: Process, stdin: Pipe, gracePeriod: Duration = .seconds(3)) {
        self.process = process
        self.stdin = stdin
        self.gracePeriod = gracePeriod
    }

    var processIdentifier: Int32 { process.processIdentifier }

    /// Number of callers waiting for exit; for tests.
    var pendingWaiters: Int { lock.withLock { waiters.count } }

    func markExited(_ status: Int32) {
        lock.lock()
        exitStatus = status
        let pending = waiters.values
        waiters = [:]
        lock.unlock()
        try? stdin.fileHandleForWriting.close()
        for waiter in pending { waiter(status) }
    }

    func waitForExit() async -> Int32 {
        while true {
            if let status = await waitForExit(timeout: nil) { return status }
        }
    }

    /// Returns the exit status, or nil when `timeout` passes first. The timer
    /// resumes the same continuation, so a process that never exits cannot
    /// keep this call waiting.
    func waitForExit(timeout: Duration?) async -> Int32? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int32?, Never>) in
            let resume = OnceResume(continuation)
            lock.lock()
            if let exitStatus {
                lock.unlock()
                resume.resume(exitStatus)
                return
            }
            let id = UUID()
            waiters[id] = { resume.resume($0) }
            lock.unlock()
            if let timeout {
                let (seconds, attoseconds) = timeout.components
                let delay = Double(seconds) + Double(attoseconds) / 1e18
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                    // Drop the waiter so repeated timed waits do not pile up.
                    self?.lock.withLock { _ = self?.waiters.removeValue(forKey: id) }
                    resume.resume(nil)
                }
            }
        }
    }

    private var hasExited: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exitStatus != nil
    }

    func terminateNow() {
        guard !hasExited else { return }
        kill(process.processIdentifier, SIGTERM)
        try? stdin.fileHandleForWriting.close()
    }

    /// SIGTERM and stdin EOF first; SIGKILL if the Core is still running after
    /// the grace period.
    func terminate() async {
        guard !hasExited else { return }
        terminateNow()
        if await waitForExit(timeout: gracePeriod) == nil {
            kill(process.processIdentifier, SIGKILL)
            _ = await waitForExit()
        }
    }
}

/// Resumes a continuation at most once, whichever of exit or timeout comes first.
private final class OnceResume: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int32?, Never>?

    init(_ continuation: CheckedContinuation<Int32?, Never>) { self.continuation = continuation }

    func resume(_ value: Int32?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
