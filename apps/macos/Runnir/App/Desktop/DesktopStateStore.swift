import Foundation
import Darwin

struct WorkspaceRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var path: String
    var name: String
    var bookmark: Data
    var lastOpenedAt: Date
    /// The GitHub repository the working tree's origin pointed at when Runnir
    /// Core last opened it, as a `GitHubRepositoryRef.key`: "owner/name" on
    /// github.com, "<server id>:owner/name" on an Enterprise server; nil
    /// until then.
    var githubRepository: String? = nil
}

struct WorkspaceWindowRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var workspaceID: UUID
    var section: AppSection = .dashboard
    /// nil until the user switches the Runs section; reads as List.
    var runsMode: RunsMode? = nil
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

/// The session a launch starts from, and whether its workspaces came from
/// the backup because the saved session could not be read.
struct DesktopLaunchState: Equatable, Sendable {
    var snapshot: DesktopSnapshot
    var restoredFromBackup = false
}

protocol DesktopStateStoring: Sendable {
    /// The saved session, or an error when it cannot be read.
    func load() throws -> DesktopSnapshot
    /// The session to launch with; a store may recover it from a backup.
    func loadForLaunch() throws -> DesktopLaunchState
    func save(_ snapshot: DesktopSnapshot) throws
}

extension DesktopStateStoring {
    func loadForLaunch() throws -> DesktopLaunchState { DesktopLaunchState(snapshot: try load()) }
}

struct FileDesktopStateStore: DesktopStateStoring {
    let directory: URL
    var stateURL: URL { directory.appendingPathComponent("desktop-state.json") }
    /// The same snapshot as `stateURL`, written after it by every save.
    var backupURL: URL { directory.appendingPathComponent("desktop-state.backup.json") }

    static func live() throws -> FileDesktopStateStore {
        FileDesktopStateStore(directory: try RunnirSupportDirectory.url())
    }

    static let maxFileBytes = 2 * 1024 * 1024

    func load() throws -> DesktopSnapshot {
        try Self.read(stateURL) ?? DesktopSnapshot()
    }

    /// The saved session; when it exists but cannot be read, the workspaces
    /// of the backup without any window, so a window closed by hand never
    /// comes back. The unreadable file is kept and the recovered session is
    /// saved. With no readable backup it throws and writes nothing.
    func loadForLaunch() throws -> DesktopLaunchState {
        do {
            return DesktopLaunchState(snapshot: try load())
        } catch {
            guard let backup = try? Self.read(backupURL) else { throw error }
            let recovered = DesktopSnapshot(workspaces: backup.workspaces)
            try preserveUnreadable()
            try save(recovered)
            return DesktopLaunchState(snapshot: recovered, restoredFromBackup: true)
        }
    }

    func save(_ snapshot: DesktopSnapshot) throws {
        try snapshot.validate()
        try JSONFile.write(snapshot, to: stateURL, maxBytes: Self.maxFileBytes)
        try JSONFile.write(snapshot, to: backupURL, maxBytes: Self.maxFileBytes)
    }

    /// Copies the session file beside it as desktop-state-unreadable-<uuid>.json.
    func preserveUnreadable() throws {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return }
        try FileManager.default.copyItem(at: stateURL,
            to: directory.appendingPathComponent("desktop-state-unreadable-\(UUID().uuidString).json"))
    }

    private static func read(_ url: URL) throws -> DesktopSnapshot? {
        guard let snapshot = try JSONFile.read(DesktopSnapshot.self, from: url, maxBytes: maxFileBytes) else { return nil }
        try snapshot.validate()
        return snapshot
    }
}

/// A small JSON file in the app's support directory, read whole and written
/// with AtomicFile. A file larger than maxBytes is refused both ways, so
/// nothing is written that could not be read back.
enum JSONFile {
    /// The file's value; nil when there is no file.
    static func read<Value: Decodable>(_ type: Value.Type, from url: URL, maxBytes: Int,
                                        dates: JSONDecoder.DateDecodingStrategy = .deferredToDate) throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maxBytes else { throw DesktopStoreError.tooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = dates
        return try decoder.decode(Value.self, from: Data(contentsOf: url))
    }

    /// Writes the value with sorted keys, indented when `pretty`.
    static func write<Value: Encodable>(_ value: Value, to url: URL, maxBytes: Int,
                                         dates: JSONEncoder.DateEncodingStrategy = .deferredToDate, pretty: Bool = false) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = dates
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= maxBytes else { throw DesktopStoreError.tooLarge }
        try AtomicFile.write(data, to: url)
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
    /// The build's folder in Application Support: Runnir, or Runnir Dev for a
    /// dev build (B47).
    static func url(build: RunnirBuild = .current) throws -> URL {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
           let path = ProcessInfo.processInfo.environment["RUNNIR_UI_TEST_STATE_DIRECTORY"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: false)
        return support.appendingPathComponent(build.folderName, isDirectory: true)
    }
}
