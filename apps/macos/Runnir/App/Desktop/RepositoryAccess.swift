import Foundation

enum RepositoryAccessError: Error {
    case notRepository
    case unavailable
    case outsideRepository
    case tooLarge
}

struct LocalWorkflowFile: Identifiable, Equatable, Sendable {
    var id: String { relativePath }
    let relativePath: String
    var name: String { URL(fileURLWithPath: relativePath).lastPathComponent }
}

struct RepositoryReader: Sendable {
    let root: URL

    static func canonicalRepository(_ url: URL) throws -> URL {
        let root = url.standardizedFileURL.resolvingSymlinksInPath()
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey])
        guard values.isDirectory == true, values.isReadable == true else { throw RepositoryAccessError.unavailable }
        // A worktree .git file is a marker only; never follow its external gitdir.
        let marker = root.appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: marker.path) else { throw RepositoryAccessError.notRepository }
        return root
    }

    func scopedURL(_ relativePath: String) throws -> URL {
        guard !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains("..") else {
            throw RepositoryAccessError.outsideRepository
        }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = canonicalRoot.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(canonicalRoot.path + "/") else { throw RepositoryAccessError.outsideRepository }
        return candidate
    }

    func workflows() throws -> [LocalWorkflowFile] {
        let directory = try scopedURL(".github/workflows")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles])
        guard entries.count <= 1000 else { throw RepositoryAccessError.tooLarge }
        return try entries.filter { ["yml", "yaml"].contains($0.pathExtension.lowercased()) }.map { entry in
            let relativePath = ".github/workflows/" + entry.lastPathComponent
            let scoped = try scopedURL(relativePath)
            guard try scoped.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw RepositoryAccessError.unavailable
            }
            return LocalWorkflowFile(relativePath: relativePath)
        }.sorted { $0.relativePath < $1.relativePath }
    }

    func source(for file: LocalWorkflowFile) throws -> String {
        let url = try scopedURL(file.relativePath)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw RepositoryAccessError.unavailable }
        guard (values.fileSize ?? Int.max) <= 512 * 1024 else { throw RepositoryAccessError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 512 * 1024 + 1) ?? Data()
        guard data.count <= 512 * 1024, let source = String(data: data, encoding: .utf8) else {
            throw RepositoryAccessError.tooLarge
        }
        return source
    }
}

@MainActor
final class RepositoryGrant {
    let url: URL
    private let scoped: Bool

    init(record: WorkspaceRecord) throws {
        var stale = false
        let resolved = try URL(resolvingBookmarkData: record.bookmark, options: [.withSecurityScope, .withoutUI],
                               relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw RepositoryAccessError.unavailable }
        url = resolved
        scoped = url.startAccessingSecurityScopedResource()
        do { _ = try RepositoryReader.canonicalRepository(url) } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    func stop() { if scoped { url.stopAccessingSecurityScopedResource() } }
}
