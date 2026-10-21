import Foundation
import Observation

/// A GitHub Enterprise server the user added: where it is, never its token.
struct EnterpriseServer: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    let webURL: URL
    let apiURL: URL
    /// The login the token belongs to, from the check when it was added.
    var login: String = ""

    /// The web host, lowercased, without port: how working trees are matched.
    var webHost: String { (webURL.host() ?? "").lowercased() }

    var ref: GitHubServerRef { GitHubServerRef(id: id.uuidString.lowercased(), apiURL: apiURL, webHost: webHost) }

    static let maxNameLength = 60
}

/// The rules for an Enterprise web or API URL.
enum EnterpriseServerURL {
    enum Problem: Error, Equatable {
        case empty, notAURL, notHTTPS, hasCredentials, hasQuery, isGitHubDotCom

        var message: String {
            switch self {
            case .empty: "Enter the URL."
            case .notAURL: "Enter a full URL, such as https://github.company.com."
            case .notHTTPS: "Use an https:// URL."
            case .hasCredentials: "Leave the user name and password out of the URL."
            case .hasQuery: "Leave ?… and #… out of the URL."
            case .isGitHubDotCom: "github.com is already in Runnir; add Enterprise servers here."
            }
        }
    }

    /// Debug builds accept http for a loopback host, for local fakes.
    static var allowsLoopbackHTTP: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    static func check(_ text: String, allowLoopbackHTTP: Bool = allowsLoopbackHTTP) -> Result<URL, Problem> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty, let url = components.url else { return .failure(.notAURL) }
        guard components.user == nil, components.password == nil else { return .failure(.hasCredentials) }
        guard components.query == nil, components.fragment == nil else { return .failure(.hasQuery) }
        let lowered = host.lowercased()
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(lowered)
        guard scheme == "https" || (scheme == "http" && allowLoopbackHTTP && loopback) else { return .failure(.notHTTPS) }
        guard lowered != "github.com", lowered != "www.github.com", lowered != "api.github.com" else { return .failure(.isGitHubDotCom) }
        return .success(url)
    }
}

/// github-servers.json in the app's support directory: the Enterprise
/// servers, never their tokens.
struct FileEnterpriseServersStore: Sendable {
    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("github-servers.json") }
    static let maxFileBytes = 64 * 1024

    private struct Snapshot: Codable {
        var version = 1
        var servers: [EnterpriseServer]
    }

    static func live() throws -> FileEnterpriseServersStore {
        FileEnterpriseServersStore(directory: try RunnirSupportDirectory.url())
    }

    func load() throws -> [EnterpriseServer] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= Self.maxFileBytes else { throw DesktopStoreError.tooLarge }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: fileURL))
        guard snapshot.version == 1, snapshot.servers.count <= EnterpriseServers.maxServers,
              snapshot.servers.allSatisfy(Self.isValid) else { throw DesktopStoreError.invalidState }
        return snapshot.servers
    }

    func save(_ servers: [EnterpriseServer]) throws {
        guard servers.count <= EnterpriseServers.maxServers, servers.allSatisfy(Self.isValid) else { throw DesktopStoreError.invalidState }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try AtomicFile.write(try encoder.encode(Snapshot(servers: servers)), to: fileURL)
    }

    static func isValid(_ server: EnterpriseServer) -> Bool {
        let name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name.count <= EnterpriseServer.maxNameLength && server.login.count <= 100
            && (try? EnterpriseServerURL.check(server.webURL.absoluteString).get()) != nil
            && (try? EnterpriseServerURL.check(server.apiURL.absoluteString).get()) != nil
    }
}

/// The Enterprise servers and their Keychain tokens. github.com's sign-in
/// stays with GitHubSession.
@MainActor
@Observable
final class EnterpriseServers {
    enum AddError: Error, Equatable { case invalid, duplicateHost, tooMany, notSaved }

    nonisolated static let maxServers = 10

    private(set) var servers: [EnterpriseServer] = []
    /// Why the list could not be read or saved, for Settings.
    private(set) var problem: String?
    @ObservationIgnored private let store: FileEnterpriseServersStore?
    @ObservationIgnored private let credentials: @Sendable (UUID) -> any CredentialStoring
    /// Called after a server is added or removed, so the Core is told.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    init(store: FileEnterpriseServersStore?, credentials: @escaping @Sendable (UUID) -> any CredentialStoring) {
        self.store = store
        self.credentials = credentials
        do {
            servers = try store?.load() ?? []
        } catch {
            problem = "Runnir could not read its list of Enterprise servers."
        }
    }

    /// The live list, with tokens in Keychain under `enterprise:<id>`.
    static func live() -> EnterpriseServers {
        EnterpriseServers(store: try? FileEnterpriseServersStore.live()) { id in
            KeychainCredentialStore(account: EnterpriseServers.keychainAccount(id))
        }
    }

    nonisolated static func keychainAccount(_ id: UUID) -> String { "enterprise:" + id.uuidString.lowercased() }

    /// Saves the token first, then the server: a listed server always has
    /// its token, and a failed save leaves nothing behind.
    func add(_ server: EnterpriseServer, token: String) async throws {
        guard FileEnterpriseServersStore.isValid(server) else { throw AddError.invalid }
        guard !servers.contains(where: { $0.webHost == server.webHost }) else { throw AddError.duplicateHost }
        guard servers.count < Self.maxServers else { throw AddError.tooMany }
        let tokenStore = credentials(server.id)
        do { try await tokenStore.saveToken(token) } catch { throw AddError.notSaved }
        let candidate = servers + [server]
        do {
            try store?.save(candidate)
        } catch {
            try? await tokenStore.removeToken()
            throw AddError.notSaved
        }
        servers = candidate
        problem = nil
        onChange?()
    }

    /// Removes the server and deletes its token from Keychain.
    func remove(_ id: UUID) async {
        let candidate = servers.filter { $0.id != id }
        do {
            try store?.save(candidate)
        } catch {
            problem = "Runnir could not save its list of Enterprise servers."
            return
        }
        servers = candidate
        try? await credentials(id).removeToken()
        onChange?()
    }

    func token(for id: UUID) async -> String? {
        try? await credentials(id).token()
    }
}
