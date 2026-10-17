import Foundation
import Darwin

struct StdioCoreTransport: CoreTransport {
    let executableURL: URL
    var timeout: TimeInterval = 5

    func exchange(_ request: Data) async throws -> Data {
        try Task.checkCancellation()
        let result = try await Task.detached {
            try exchangeBlocking(request)
        }.value
        try Task.checkCancellation()
        return result
    }

    private func exchangeBlocking(_ request: Data) throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw CoreIPCError.helperUnavailable
        }
        guard request.count <= 4096, !request.contains(10) else {
            throw CoreIPCError.invalidResponse
        }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let exited = DispatchSemaphore(value: 0)
        process.executableURL = executableURL
        process.arguments = ["rpc"]
        process.environment = ["LANG": "C"]
        process.currentDirectoryURL = executableURL.deletingLastPathComponent()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in exited.signal() }
        defer {
            try? input.fileHandleForWriting.close()
            try? input.fileHandleForReading.close()
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        try process.run()
        // The proof of concept owns one short-lived child per exchange. EOF stops Core.
        do {
            try input.fileHandleForWriting.write(contentsOf: request + Data([10]))
            try input.fileHandleForWriting.close()
        } catch {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            throw CoreIPCError.processFailed
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            throw CoreIPCError.timedOut
        }
        guard process.terminationStatus == 0 else { throw CoreIPCError.processFailed }
        try output.fileHandleForWriting.close()
        let data = try output.fileHandleForReading.read(upToCount: 64 * 1024 + 1) ?? Data()
        guard !data.isEmpty, data.count <= 64 * 1024, data.last == 10,
              data.dropLast().contains(10) == false else {
            throw CoreIPCError.invalidResponse
        }
        return data
    }
}
