import Foundation
import Testing
@testable import Runnir

actor MemoryCredentialStore: CredentialStoring {
    private(set) var stored: String?
    func token() async throws -> String? { stored }
    func saveToken(_ token: String) async throws { stored = token }
    func removeToken() async throws { stored = nil }
}

/// One memory store per server id, shared across model instances.
final class LockedStores: @unchecked Sendable {
    private let lock = NSLock()
    private var stores: [UUID: MemoryCredentialStore] = [:]
    func store(for id: UUID) -> MemoryCredentialStore {
        lock.withLock {
            if let existing = stores[id] { return existing }
            let made = MemoryCredentialStore()
            stores[id] = made
            return made
        }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct EnterpriseServersTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("servers-" + UUID().uuidString, isDirectory: true)
    }

    private func server(_ host: String = "github.company.com", name: String = "Company") -> EnterpriseServer {
        EnterpriseServer(id: UUID(), name: name, webURL: URL(string: "https://\(host)")!, apiURL: URL(string: "https://\(host)/api/v3")!)
    }

    @Test func urlsMustBeHTTPSWithoutCredentials() throws {
        #expect(try EnterpriseServerURL.check("https://github.company.com", allowLoopbackHTTP: false).get().host() == "github.company.com")
        #expect(try EnterpriseServerURL.check(" https://ghe.example:8443/api/v3 ", allowLoopbackHTTP: false).get().port == 8443)
        #expect(EnterpriseServerURL.check("", allowLoopbackHTTP: false) == .failure(.empty))
        #expect(EnterpriseServerURL.check("github.company.com", allowLoopbackHTTP: false) == .failure(.notAURL))
        #expect(EnterpriseServerURL.check("http://github.company.com", allowLoopbackHTTP: false) == .failure(.notHTTPS))
        #expect(EnterpriseServerURL.check("http://127.0.0.1:3000", allowLoopbackHTTP: false) == .failure(.notHTTPS))
        #expect((try? EnterpriseServerURL.check("http://127.0.0.1:3000", allowLoopbackHTTP: true).get()) != nil)
        #expect(EnterpriseServerURL.check("http://github.company.com", allowLoopbackHTTP: true) == .failure(.notHTTPS))
        #expect(EnterpriseServerURL.check("https://me:pw@github.company.com", allowLoopbackHTTP: false) == .failure(.hasCredentials))
        #expect(EnterpriseServerURL.check("https://github.company.com/?a=1", allowLoopbackHTTP: false) == .failure(.hasQuery))
        #expect(EnterpriseServerURL.check("https://github.company.com/#top", allowLoopbackHTTP: false) == .failure(.hasQuery))
        #expect(EnterpriseServerURL.check("https://GitHub.com", allowLoopbackHTTP: false) == .failure(.isGitHubDotCom))
        #expect(EnterpriseServerURL.check("ftp://github.company.com", allowLoopbackHTTP: false) == .failure(.notHTTPS))
    }

    @Test func serversAndTokensAreSavedApart() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let made = LockedStores()
        let servers = EnterpriseServers(store: FileEnterpriseServersStore(directory: directory), credentials: { made.store(for: $0) })
        var changes = 0
        servers.onChange = { changes += 1 }
        let company = server()
        try await servers.add(company, token: "ghp_company")
        #expect(servers.servers.map(\.webHost) == ["github.company.com"] && changes == 1)
        #expect(await servers.token(for: company.id) == "ghp_company")
        #expect(company.ref == GitHubServerRef(id: company.id.uuidString.lowercased(), apiURL: company.apiURL, webHost: "github.company.com"))

        // The next launch reads the same list; the file holds no token.
        let data = try Data(contentsOf: directory.appendingPathComponent("github-servers.json"))
        #expect(!String(decoding: data, as: UTF8.self).contains("ghp_"))
        let reread = EnterpriseServers(store: FileEnterpriseServersStore(directory: directory), credentials: { made.store(for: $0) })
        #expect(reread.servers == servers.servers && reread.problem == nil)

        // The same web host twice is refused, whatever its case.
        await #expect(throws: EnterpriseServers.AddError.duplicateHost) {
            try await servers.add(self.server("GITHUB.company.com", name: "Twin"), token: "ghp_x")
        }

        await servers.remove(company.id)
        #expect(servers.servers.isEmpty && changes == 2)
        #expect(await servers.token(for: company.id) == nil)
    }

    @Test func aDamagedListIsReportedNotLost() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: directory.appendingPathComponent("github-servers.json"))
        let servers = EnterpriseServers(store: FileEnterpriseServersStore(directory: directory), credentials: { _ in MemoryCredentialStore() })
        #expect(servers.servers.isEmpty && servers.problem != nil)
    }

    @Test func atMostTenServers() async throws {
        let made = LockedStores()
        let servers = EnterpriseServers(store: nil, credentials: { made.store(for: $0) })
        for index in 0..<EnterpriseServers.maxServers {
            try await servers.add(server("ghe\(index).example"), token: "ghp_x")
        }
        await #expect(throws: EnterpriseServers.AddError.tooMany) {
            try await servers.add(self.server("one-more.example"), token: "ghp_x")
        }
    }

    @Test func keychainAccountsDoNotTouchGitHubDotCom() {
        let id = UUID(uuidString: "1B9D6BCD-BBFD-4B2D-9B5D-AB8DFBBD4BED")!
        #expect(EnterpriseServers.keychainAccount(id) == "enterprise:1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed")
        #expect(KeychainCredentialStore.defaultAccount == "oauth-token")
    }
}
