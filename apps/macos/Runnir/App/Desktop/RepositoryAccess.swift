import Foundation
import Darwin

enum RepositoryAccessError: Error {
    case notRepository
    case unavailable
    case notFound
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
    private let directory: RepositoryDirectory

    init(root: URL) throws {
        self.root = root.standardizedFileURL
        let descriptor = Darwin.open(self.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw RepositoryAccessError.unavailable }
        directory = RepositoryDirectory(descriptor)
    }

    static func canonicalRepository(_ url: URL) throws -> URL {
        let root = url.standardizedFileURL.resolvingSymlinksInPath()
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey])
        guard values.isDirectory == true, values.isReadable == true else { throw RepositoryAccessError.unavailable }
        // A worktree .git file is a marker only; never follow its external gitdir.
        let marker = root.appendingPathComponent(".git")
        var metadata = stat()
        guard lstat(marker.path, &metadata) == 0,
              [S_IFDIR, S_IFREG].contains(metadata.st_mode & S_IFMT) else { throw RepositoryAccessError.notRepository }
        return root
    }

    func workflows() throws -> [LocalWorkflowFile] {
        let descriptor: Int32
        do { descriptor = try openRelative(".github/workflows", flags: O_RDONLY | O_DIRECTORY) }
        catch RepositoryAccessError.notFound { return [] }
        guard let stream = fdopendir(descriptor) else {
            Darwin.close(descriptor)
            throw RepositoryAccessError.unavailable
        }
        defer { closedir(stream) }
        var files: [LocalWorkflowFile] = []
        var count = 0
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw RepositoryAccessError.unavailable }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard !name.hasPrefix(".") else { continue }
            count += 1
            guard count <= 1000 else { throw RepositoryAccessError.tooLarge }
            guard ["yml", "yaml"].contains(URL(fileURLWithPath: name).pathExtension.lowercased()) else { continue }
            var metadata = stat()
            guard fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
                  metadata.st_mode & S_IFMT == S_IFREG else { throw RepositoryAccessError.outsideRepository }
            files.append(LocalWorkflowFile(relativePath: ".github/workflows/" + name))
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    func source(for file: LocalWorkflowFile) throws -> String {
        let descriptor = try openRelative(file.relativePath, flags: O_RDONLY | O_NONBLOCK)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            throw RepositoryAccessError.unavailable
        }
        guard metadata.st_size >= 0, metadata.st_size <= 512 * 1024 else { throw RepositoryAccessError.tooLarge }
        let data = try handle.read(upToCount: 512 * 1024 + 1) ?? Data()
        guard data.count <= 512 * 1024, let source = String(data: data, encoding: .utf8) else {
            throw RepositoryAccessError.tooLarge
        }
        return source
    }

    private func components(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.utf8.contains(0) }) else {
            throw RepositoryAccessError.outsideRepository
        }
        return parts
    }

    private func openRelative(_ path: String, flags: Int32) throws -> Int32 {
        let parts = try components(path)
        var current = directory.descriptor
        defer { if current != directory.descriptor { Darwin.close(current) } }
        for (index, part) in parts.enumerated() {
            let isLast = index == parts.count - 1
            let next = openat(current, part, (isLast ? flags : O_RDONLY | O_DIRECTORY) | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else {
                if errno == ENOENT { throw RepositoryAccessError.notFound }
                if errno == ELOOP { throw RepositoryAccessError.outsideRepository }
                throw RepositoryAccessError.unavailable
            }
            if isLast { return next }
            if current != directory.descriptor { Darwin.close(current) }
            current = next
        }
        throw RepositoryAccessError.unavailable
    }
}

private final class RepositoryDirectory: @unchecked Sendable {
    let descriptor: Int32
    init(_ descriptor: Int32) { self.descriptor = descriptor }
    deinit { Darwin.close(descriptor) }
}

@MainActor
protocol RepositoryGranting: AnyObject {
    var url: URL { get }
    var reader: RepositoryReader { get }
    func stop()
}

@MainActor
final class RepositoryGrant: RepositoryGranting {
    let url: URL
    let reader: RepositoryReader
    private let scopedURL: URL
    private var scoped: Bool

    init(record: WorkspaceRecord) throws {
        var stale = false
        let resolved = try URL(resolvingBookmarkData: record.bookmark, options: [.withSecurityScope, .withoutUI],
                               relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw RepositoryAccessError.unavailable }
        scopedURL = resolved
        scoped = resolved.startAccessingSecurityScopedResource()
        do {
            url = try RepositoryReader.canonicalRepository(resolved)
            reader = try RepositoryReader(root: url)
        } catch {
            if scoped { resolved.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    func stop() {
        if scoped { scopedURL.stopAccessingSecurityScopedResource(); scoped = false }
    }
}
