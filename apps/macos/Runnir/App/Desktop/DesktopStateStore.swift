import Foundation
import Darwin

struct WorkspaceRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var path: String
    var name: String
    var bookmark: Data
    var lastOpenedAt: Date
}

struct WorkspaceWindowRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var workspaceID: UUID
    var section: AppSection = .dashboard
    var frame: WindowGeometry?
}

struct WindowGeometry: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite)
            && width >= 100 && height >= 100 && width <= 16384 && height <= 16384
    }
}

struct DesktopSnapshot: Codable, Equatable, Sendable {
    static let maxWorkspaces = 200
    static let maxWindows = 50

    var version = 1
    var workspaces: [WorkspaceRecord] = []
    var windows: [WorkspaceWindowRecord] = []

    func validate() throws {
        let workspaceIDs = Set(workspaces.map(\.id))
        guard version == 1, workspaces.count <= Self.maxWorkspaces, windows.count <= Self.maxWindows,
              workspaceIDs.count == workspaces.count,
              Set(windows.map(\.id)).count == windows.count,
              workspaces.allSatisfy({ $0.path.hasPrefix("/") && !$0.name.isEmpty && $0.bookmark.count <= 65536 }),
              windows.allSatisfy({ workspaceIDs.contains($0.workspaceID) && ($0.frame?.isValid ?? true) }) else {
            throw DesktopStoreError.invalidState
        }
    }

    mutating func closeWindow(_ id: UUID) { windows.removeAll { $0.id == id } }

    mutating func associate(windowID: UUID, workspaceID: UUID) {
        guard let index = windows.firstIndex(where: { $0.id == windowID }) else { return }
        windows[index].workspaceID = workspaceID
        windows[index].section = .dashboard
    }
}

enum DesktopStoreError: Error {
    case invalidState
    case tooLarge
    case ioFailure
    /// The session already holds `DesktopSnapshot.maxWindows` windows.
    case tooManyWindows
}

protocol DesktopStateStoring: Sendable {
    func load() throws -> DesktopSnapshot
    func save(_ snapshot: DesktopSnapshot) throws
}

struct FileDesktopStateStore: DesktopStateStoring {
    let directory: URL
    var stateURL: URL { directory.appendingPathComponent("desktop-state.json") }

    static func live() throws -> FileDesktopStateStore {
        FileDesktopStateStore(directory: try RunnirSupportDirectory.url())
    }

    func load() throws -> DesktopSnapshot {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return DesktopSnapshot() }
        let size = try stateURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 2 * 1024 * 1024 else { throw DesktopStoreError.tooLarge }
        let snapshot = try JSONDecoder().decode(DesktopSnapshot.self, from: Data(contentsOf: stateURL))
        try snapshot.validate()
        return snapshot
    }

    func save(_ snapshot: DesktopSnapshot) throws {
        try snapshot.validate()
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= 2 * 1024 * 1024 else { throw DesktopStoreError.tooLarge }
        try AtomicFile.write(data, to: stateURL)
    }
}

/// Replaces a small private file atomically: a new 0600 file in the same
/// 0700 directory, synced, renamed over the old one, and the directory
/// synced, so a crash leaves either the old or the new content.
enum AtomicFile {
    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent)-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw DesktopStoreError.ioFailure }
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw DesktopStoreError.ioFailure }
                    offset += written
                }
            }
            guard fsync(descriptor) == 0 else { throw DesktopStoreError.ioFailure }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        guard Darwin.close(descriptor) == 0 else { throw DesktopStoreError.ioFailure }
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw DesktopStoreError.ioFailure }
        let directoryDescriptor = Darwin.open(directory.path, O_RDONLY)
        guard directoryDescriptor >= 0 else { throw DesktopStoreError.ioFailure }
        defer { Darwin.close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else { throw DesktopStoreError.ioFailure }
    }
}

/// Where Runnir keeps its files: ~/Library/Application Support/Runnir, or,
/// for UI tests of a Debug build, the folder they name, so a test run never
/// writes into the user's own session, presets or favorites.
enum RunnirSupportDirectory {
    static func url() throws -> URL {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
           let path = ProcessInfo.processInfo.environment["RUNNIR_UI_TEST_STATE_DIRECTORY"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: false)
        return support.appendingPathComponent("Runnir", isDirectory: true)
    }
}
