import Foundation
import Darwin

/// Launches the bundled helper with Foundation `Process`: no shell, a reduced
/// environment, and a stdin pipe whose closing stops the Core.
struct ProcessCoreLauncher: CoreProcessLaunching {
    let executableURL: URL

    func launch(socketPath: String) throws -> any CoreProcessHandle {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw CoreSupervisorError.helperUnavailable
        }
        let process = Process()
        let stdin = Pipe()
        process.executableURL = executableURL
        process.arguments = ["serve", "--socket", socketPath, "--exit-on-stdin-eof"]
        process.environment = ["LANG": "C"]
        process.currentDirectoryURL = executableURL.deletingLastPathComponent()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let handle = ProcessCoreHandle(process: process, stdin: stdin)
        process.terminationHandler = { finished in handle.markExited(finished.terminationStatus) }
        do {
            try process.run()
        } catch {
            throw CoreSupervisorError.launchFailed
        }
        try? stdin.fileHandleForReading.close() // the child holds its own copy
        return handle
    }
}

final class ProcessCoreHandle: CoreProcessHandle, @unchecked Sendable {
    private let process: Process
    private let stdin: Pipe
    private let lock = NSLock()
    private var exitStatus: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    init(process: Process, stdin: Pipe) {
        self.process = process
        self.stdin = stdin
    }

    var processIdentifier: Int32 { process.processIdentifier }

    func markExited(_ status: Int32) {
        lock.lock()
        exitStatus = status
        let pending = waiters
        waiters = []
        lock.unlock()
        try? stdin.fileHandleForWriting.close()
        for waiter in pending { waiter.resume(returning: status) }
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let exitStatus {
                lock.unlock()
                continuation.resume(returning: exitStatus)
            } else {
                waiters.append(continuation)
                lock.unlock()
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

    func terminate() async {
        guard !hasExited else { return }
        terminateNow()
        let exitedInTime = await withTaskGroup(of: Bool.self) { group in
            group.addTask { _ = await self.waitForExit(); return true }
            group.addTask { try? await Task.sleep(for: .seconds(3)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !exitedInTime {
            kill(process.processIdentifier, SIGKILL)
            _ = await waitForExit()
        }
    }
}
