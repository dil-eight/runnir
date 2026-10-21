import Foundation

/// A workspace's favorite workflows, by path such as ".github/workflows/ci.yml"
/// (the same for the working tree file and the workflow on GitHub), in the
/// order they were starred.
struct FavoriteWorkflows: Codable, Equatable, Sendable {
    var workspaceID: UUID
    var paths: [String]

    static let maxPathLength = 512
    static let perWorkspaceLimit = 100

    var isValid: Bool {
        paths.count <= Self.perWorkspaceLimit && Set(paths).count == paths.count
            && paths.allSatisfy { $0.hasPrefix(".github/workflows/") && $0.count <= Self.maxPathLength }
    }
}

protocol WorkflowFavoritesStoring: Sendable {
    func load() throws -> [FavoriteWorkflows]
    func save(_ favorites: [FavoriteWorkflows]) throws
}

/// favorite-workflows.json in the app's support directory: versioned,
/// bounded, written atomically with mode 0600.
struct FileWorkflowFavoritesStore: WorkflowFavoritesStoring {
    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("favorite-workflows.json") }

    static let maxWorkspaces = 500
    static let maxFileBytes = 1024 * 1024

    private struct Snapshot: Codable {
        var version = 1
        var workspaces: [FavoriteWorkflows]
    }

    static func live() throws -> FileWorkflowFavoritesStore {
        FileWorkflowFavoritesStore(directory: try RunnirSupportDirectory.url())
    }

    func load() throws -> [FavoriteWorkflows] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= Self.maxFileBytes else { throw DesktopStoreError.tooLarge }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: fileURL))
        guard snapshot.version == 1, snapshot.workspaces.count <= Self.maxWorkspaces,
              snapshot.workspaces.allSatisfy(\.isValid) else { throw DesktopStoreError.invalidState }
        return snapshot.workspaces
    }

    func save(_ favorites: [FavoriteWorkflows]) throws {
        guard favorites.count <= Self.maxWorkspaces, favorites.allSatisfy(\.isValid) else { throw DesktopStoreError.invalidState }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Snapshot(workspaces: favorites))
        guard data.count <= Self.maxFileBytes else { throw DesktopStoreError.tooLarge }
        try AtomicFile.write(data, to: fileURL)
    }
}

/// Favorite workflows of every workspace, read when created (the file is
/// small), so views never load it while they draw. When the file cannot be
/// read, favorites are off for the session and nothing overwrites it.
@MainActor
@Observable
final class WorkflowFavorites {
    nonisolated static var perWorkspaceLimit: Int { FavoriteWorkflows.perWorkspaceLimit }

    private(set) var workspaces: [FavoriteWorkflows] = []
    /// Why favorites are unavailable or the last change was not saved.
    private(set) var problem: String?
    @ObservationIgnored private let store: (any WorkflowFavoritesStoring)?
    @ObservationIgnored private var readable = true

    init(store: (any WorkflowFavoritesStoring)?) {
        self.store = store
        guard let store else { return }
        do {
            workspaces = try store.load()
        } catch {
            readable = false
            problem = "Saved favorites could not be read, so favorites are off for now. The file was left as it is."
        }
    }

    var isAvailable: Bool { store != nil && readable }

    /// Only workflow files can be favorites; GitHub also lists workflows it
    /// adds itself, such as code scanning, under other paths.
    nonisolated static func canFavorite(_ path: String) -> Bool {
        path.hasPrefix(".github/workflows/") && path.count <= FavoriteWorkflows.maxPathLength
    }

    func paths(workspaceID: UUID) -> [String] {
        workspaces.first { $0.workspaceID == workspaceID }?.paths ?? []
    }

    func isFavorite(_ path: String, workspaceID: UUID) -> Bool {
        paths(workspaceID: workspaceID).contains(path)
    }

    /// Favorites first, in the order they were starred, then the rest in
    /// their own order.
    func ordered<Item>(_ items: [Item], workspaceID: UUID, path: (Item) -> String) -> [Item] {
        let favorites = paths(workspaceID: workspaceID)
        let rank = Dictionary(uniqueKeysWithValues: favorites.enumerated().map { ($1, $0) })
        let starred = items.filter { rank[path($0)] != nil }.sorted { rank[path($0)]! < rank[path($1)]! }
        return starred + items.filter { rank[path($0)] == nil }
    }

    @discardableResult
    func toggle(_ path: String, workspaceID: UUID) -> Bool {
        guard Self.canFavorite(path) else {
            problem = "Only workflow files in .github/workflows can be favorites."
            return false
        }
        var candidate = workspaces
        if let index = candidate.firstIndex(where: { $0.workspaceID == workspaceID }) {
            if let position = candidate[index].paths.firstIndex(of: path) {
                candidate[index].paths.remove(at: position)
                if candidate[index].paths.isEmpty { candidate.remove(at: index) }
            } else {
                guard candidate[index].paths.count < Self.perWorkspaceLimit else {
                    problem = "A workspace can have at most \(Self.perWorkspaceLimit) favorite workflows."
                    return false
                }
                candidate[index].paths.append(path)
            }
        } else {
            candidate.append(FavoriteWorkflows(workspaceID: workspaceID, paths: [path]))
        }
        return commit(candidate)
    }

    /// Keeps a renamed workflow's star, in its place.
    func moveWorkflow(workspaceID: UUID, from oldPath: String, to newPath: String) {
        guard oldPath != newPath, Self.canFavorite(newPath),
              let index = workspaces.firstIndex(where: { $0.workspaceID == workspaceID }),
              let position = workspaces[index].paths.firstIndex(of: oldPath) else { return }
        var candidate = workspaces
        candidate[index].paths[position] = newPath
        // A star left on the new path by an earlier file of that name goes.
        candidate[index].paths = candidate[index].paths.enumerated().filter { $0.element != newPath || $0.offset == position }.map(\.element)
        commit(candidate)
    }

    func removeAll(workspaceID: UUID) {
        guard workspaces.contains(where: { $0.workspaceID == workspaceID }) else { return }
        commit(workspaces.filter { $0.workspaceID != workspaceID })
    }

    @discardableResult
    private func commit(_ candidate: [FavoriteWorkflows]) -> Bool {
        guard let store, readable else {
            problem = problem ?? "Favorites are not available."
            return false
        }
        do {
            try store.save(candidate)
            workspaces = candidate
            problem = nil
            return true
        } catch {
            problem = "The favorite could not be saved. Check available storage and try again."
            return false
        }
    }
}
