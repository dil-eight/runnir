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
        // The Core appends paths to the API URL: a trailing slash would give "//repos".
        #expect(try EnterpriseServerURL.check("https://github.company.com/api/v3/", allowLoopbackHTTP: false).get().absoluteString
            == "https://github.company.com/api/v3")
        #expect(try EnterpriseServerURL.check("https://github.company.com//", allowLoopbackHTTP: false).get().absoluteString
            == "https://github.company.com")
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
        #expect(company.ref == GitHubServerRef(id: company.id.uuidString.lowercased(), apiURL: company.apiURL, webHost: "github.company.com",
                                               webURL: company.webURL))

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

private func pullRequest(_ number: Int64, updated: TimeInterval) -> CorePullRequest {
    CorePullRequest(repository: "o/r", number: number, title: "PR", htmlURL: URL(string: "https://example.com/\(number)"), state: "open",
                    draft: false, headBranch: "b", updatedAt: Date(timeIntervalSinceReferenceDate: updated), closedAt: nil, ci: .passed,
                    ciRuns: 1, ciFailed: 0, ciRunning: 0, ciURL: nil)
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct EnterpriseHubTests {
    let company = GitHubServerRef(id: "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed", apiURL: URL(string: "https://github.company.com/api/v3"),
                                  webHost: "github.company.com")

    private func signedInHub(enterprise: Bool = true) async -> (CoreHub, FakeProvider) {
        let provider = FakeProvider()
        let hub = CoreHub(provider: provider)
        let company = company
        hub.githubTokenProvider = { "ghu_dotcom" }
        hub.enterpriseCredentialsProvider = { enterprise ? [(server: company, token: "ghp_company")] : [] }
        hub.startMonitoring()
        provider.ready()
        _ = await eventually { hub.signedInServers.count == (enterprise ? 2 : 1) }
        return (hub, provider)
    }

    @Test func everySignedInServerIsHandedToTheCore() async {
        let (hub, provider) = await signedInHub()
        #expect(hub.signedInServers.map(\.id) == ["", company.id])
        #expect(hub.credentialKinds == ["": .appUser, company.id: .classic])
        let calls = provider.core.serverCredentialCalls
        #expect(calls.contains { $0.server == "" && $0.token == "ghu_dotcom" })
        #expect(calls.contains { $0.server == company.id && $0.token == "ghp_company" })

        // A removed server is cleared in the Core.
        hub.enterpriseCredentialsProvider = { [] }
        hub.githubCredentialChanged()
        #expect(await eventually { hub.signedInServers.map(\.id) == [""] })
        #expect(provider.core.serverCredentialCalls.contains { $0.server == company.id && $0.token == nil })
    }

    @Test func aSlowPushCannotBringBackARemovedServer() async {
        let (hub, provider) = await signedInHub(enterprise: false)
        let company = company
        // Reading the servers' tokens waits, as a Keychain prompt would.
        let keychain = Gate()
        hub.enterpriseCredentialsProvider = { await keychain.wait(); return [(server: company, token: "ghp_company")] }
        hub.githubCredentialChanged()
        // The first push is waiting for the Keychain before anything changes;
        // a fixed sleep let a slow machine read the provider after the change.
        #expect(await eventuallyAsync { await keychain.hasWaiter })
        // Meanwhile the server is removed.
        hub.enterpriseCredentialsProvider = { [] }
        hub.githubCredentialChanged()
        try? await Task.sleep(for: .milliseconds(50))
        await keychain.open()
        // The later push ends up in the Core: the server is cleared, not set again.
        #expect(await eventually {
            provider.core.serverCredentialCalls.filter { $0.server == company.id }.map(\.token) == ["ghp_company", nil]
        })
        // The hub records its servers once the Core answered that call.
        #expect(await eventually { hub.signedInServers.map(\.id) == [""] })
    }

    @Test func pullRequestsComeFromEveryServerNewestFirst() async {
        let (hub, provider) = await signedInHub()
        provider.core.pullRequestsByServer = [
            "": CorePullRequests(access: .ok, open: [pullRequest(1, updated: 10)], closed: [], headsUnreadable: false),
            company.id: CorePullRequests(access: .ok, open: [pullRequest(2, updated: 20)], closed: [], headsUnreadable: true),
        ]
        let merged = await hub.pullRequests(closedSince: Date())
        #expect(merged.access == .ok && merged.headsUnreadable)
        #expect(merged.open.map(\.number) == [2, 1] && merged.open.map(\.server) == [company.id, ""])

        // One server failing does not hide the other.
        provider.core.pullRequestsByServer[company.id] = .failed(.unavailable)
        let partial = await hub.pullRequests(closedSince: Date())
        #expect(partial.access == .ok && partial.open.map(\.number) == [1])
    }

    @Test func openRepositoriesAreReadAgainWhenServersChange() async {
        let (hub, provider) = await signedInHub(enterprise: false)
        let workspace = UUID()
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/ghe")
        #expect(await eventually { hub.session(for: workspace)?.phase == .ready })
        let before = provider.core.refreshCalls.count

        // The same servers again: only activity is read.
        hub.githubCredentialChanged()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(provider.core.refreshCalls.count == before)

        // A new server can be the one the working tree's origin is on.
        let company = company
        hub.enterpriseCredentialsProvider = { [(server: company, token: "ghp_company")] }
        hub.githubCredentialChanged()
        #expect(await eventually { provider.core.refreshCalls.count == before + 1 })
    }

    @Test func anEnterpriseRejectionKeepsTheGitHubDotComSignIn() async {
        let (hub, provider) = await signedInHub()
        var rejections = 0
        hub.onGitHubTokenRejected = { rejections += 1 }
        let enterpriseRepo = GitHubRepositoryRef(serverID: company.id, fullName: "o/r")
        provider.core.setRuns(CoreGitHubResult(access: .tokenRejected, items: []), forRepository: enterpriseRepo.key)
        _ = await hub.runs(of: .repository(enterpriseRepo), limit: 10)
        #expect(rejections == 0)
        provider.core.setRuns(CoreGitHubResult(access: .tokenRejected, items: []), forRepository: "o/r")
        _ = await hub.runs(of: .repository(GitHubRepositoryRef(serverID: "", fullName: "o/r")), limit: 10)
        #expect(rejections == 1)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct EnterpriseServerFormTests {
    @Test func tokenLinksUseTheServersWebURL() {
        let web = URL(string: "https://github.company.com")!
        #expect(GitHubTokenAdvice.newClassicURL(webURL: web).absoluteString == "https://github.company.com/settings/tokens/new?scopes=repo&description=Runnir")
        #expect(GitHubTokenAdvice.newFineGrainedURL(webURL: web).absoluteString == "https://github.company.com/settings/personal-access-tokens/new")
        #expect(GitHubTokenAdvice.newClassicURL.absoluteString == "https://github.com/settings/tokens/new?scopes=repo&description=Runnir")
        #expect(GitHubAccessHelp.tokenSettingsURL(.fineGrained, webURL: web).absoluteString == "https://github.company.com/settings/personal-access-tokens")
    }

    @Test func theFormNeedsValidURLsAndAnAcceptedToken() async {
        let (hub, provider) = await makeReadyHub()
        let form = EnterpriseServerForm(existing: [])
        form.name = "Company"
        form.webURL = "http://github.company.com"
        form.apiURL = "https://github.company.com/api/v3"
        form.token = "ghp_company"
        #expect(form.problems == ["Web URL: Use an https:// URL."])
        #expect(!form.canAdd)
        await form.runCheck(hub: hub)
        #expect(provider.core.checkedTokens.isEmpty, "invalid fields are not checked")

        form.webURL = "https://github.company.com"
        provider.core.tokenCheck = CoreGitHubTokenCheck(access: .ok, kind: .classic, login: "me", scopes: ["repo"], expiresAt: nil,
                                                        repositories: 3, checks: [], suitable: true)
        await form.runCheck(hub: hub)
        #expect(form.canAdd && form.draft?.webHost == "github.company.com" && form.draft?.login == "me")
        #expect(provider.core.tokenCheckServers.last?.webHost == "github.company.com")
        #expect(provider.core.tokenCheckServers.last?.id == form.draft?.ref.id)

        form.token = "ghp_other"
        #expect(!form.canAdd, "a changed token is checked again")
    }

    @Test func theTokenCanBeCheckedBeforeTheServerIsNamed() async {
        let (hub, provider) = await makeReadyHub()
        let form = EnterpriseServerForm(existing: [])
        form.webURL = "https://github.company.com"
        form.apiURL = "https://github.company.com/api/v3"
        form.token = "ghp_company"
        #expect(form.canCheck && form.shownProblems.isEmpty)
        provider.core.tokenCheck = CoreGitHubTokenCheck(access: .ok, kind: .classic, login: "me", scopes: ["repo"], expiresAt: nil,
                                                        repositories: 3, checks: [], suitable: true)
        await form.runCheck(hub: hub)
        #expect(provider.core.checkedTokens == ["ghp_company"])
        // Add waits for the name, and now says so.
        #expect(!form.canAdd && form.shownProblems == ["Name: use 1 to 60 characters."])
        form.name = "Company"
        #expect(form.canAdd && form.shownProblems.isEmpty)
    }

    @Test func emptyFieldsAreNotShownAsMistakes() {
        let form = EnterpriseServerForm(existing: [])
        #expect(form.shownProblems.isEmpty && !form.problems.isEmpty, "nothing typed yet: Add stays off, no errors shown")
        form.webURL = "github.company.com"
        #expect(form.shownProblems == ["Web URL: Enter a full URL, such as https://github.company.com."])
    }

    @Test func aServerAlreadyListedIsRefused() {
        let existing = EnterpriseServer(id: UUID(), name: "Company", webURL: URL(string: "https://github.company.com")!,
                                        apiURL: URL(string: "https://github.company.com/api/v3")!)
        let form = EnterpriseServerForm(existing: [existing])
        form.name = "Again"
        form.webURL = "https://GitHub.Company.com"
        form.apiURL = "https://github.company.com/api/v3"
        #expect(form.problems == ["Web URL: github.company.com is already in the list."])
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SettingsOverlayTests {
    @Test func settingsShowInOneWindowAtATime() {
        let desktop = DesktopCoordinator(store: nil)
        let first = UUID(), second = UUID()
        desktop.showSettings(in: first)
        #expect(desktop.settings == SettingsPresentation(windowID: first, section: .account))
        desktop.showSettingsSection(.pullRequests)
        // Opening them in another window moves them there, at the same section.
        desktop.showSettings(in: second)
        #expect(desktop.settings == SettingsPresentation(windowID: second, section: .pullRequests))
        desktop.closeSettings()
        #expect(desktop.settings == nil)
        desktop.showSettingsSection(.tools)
        #expect(desktop.settings == nil, "choosing a section does not open closed Settings")
        // They open again at the section shown last.
        desktop.showSettings(in: first)
        #expect(desktop.settings?.section == .pullRequests)
        desktop.showSettings(in: first, section: .account)
        #expect(desktop.settings?.section == .account)
    }
}

/// Holds callers until it is opened.
actor Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Someone is waiting for the gate to open.
    var hasWaiter: Bool { !waiting.isEmpty }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}
