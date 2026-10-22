import Foundation
import Testing
@testable import Runnir

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct GitHubRepositoriesTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("repositories-" + UUID().uuidString, isDirectory: true)
    }

    private func repository(_ fullName: String, description: String = "", pushed: TimeInterval = 0, canPush: Bool = true) -> CoreGitHubAccountRepository {
        let parts = fullName.split(separator: "/").map(String.init)
        return CoreGitHubAccountRepository(fullName: fullName, owner: parts[0], name: parts[1], description: description, visibility: "private",
                                           defaultBranch: "main", htmlURL: URL(string: "https://github.com/" + fullName),
                                           pushedAt: Date(timeIntervalSince1970: pushed), archived: false, fork: false,
                                           canPush: canPush, installationID: 1)
    }

    private func readyHub() async -> (CoreHub, FakeProvider) {
        let provider = FakeProvider()
        let hub = CoreHub(provider: provider)
        hub.startMonitoring()
        provider.ready()
        hub.runLookupInterval = .milliseconds(10)
        hub.runLookupTimeout = .milliseconds(500)
        _ = await eventually { hub.status == .ready(version: "fake") }
        return (hub, provider)
    }

    // MARK: Stars

    @Test func starsSurviveARestartAndIgnoreCase() throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let favorites = RepositoryFavorites(store: FileRepositoryFavoritesStore(directory: folder))
        #expect(favorites.toggle("dil-eight/runnir"))
        #expect(favorites.toggle("octocat/hello"))
        #expect(favorites.isFavorite("Dil-Eight/Runnir"))
        #expect(!favorites.toggle("not a name"))

        let restarted = RepositoryFavorites(store: FileRepositoryFavoritesStore(directory: folder))
        #expect(restarted.names == ["dil-eight/runnir", "octocat/hello"])
        #expect(restarted.toggle("DIL-EIGHT/runnir"), "unstarring matches whatever the case")
        #expect(RepositoryFavorites(store: FileRepositoryFavoritesStore(directory: folder)).names == ["octocat/hello"])
    }

    @Test func anUnreadableStarsFileTurnsStarsOffAndIsLeftAlone() throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = FileRepositoryFavoritesStore(directory: folder)
        try Data(#"{"version":1,"repositories":["../escape"]}"#.utf8).write(to: store.fileURL)
        let favorites = RepositoryFavorites(store: store)
        #expect(!favorites.isAvailable && favorites.problem != nil)
        #expect(!favorites.toggle("o/r"))
        #expect(try String(contentsOf: store.fileURL, encoding: .utf8).contains("../escape"))
    }

    @Test func repositoryNamesAreGitHubNames() {
        for good in ["o/r", "dil-eight/runnir", "a1/.github", "o/r.js", "o/r_x-y"] { #expect(GitHubRepositoryName.isValid(good), "\(good)") }
        for bad in ["", "o", "/r", "o/", "o/r/x", "o/..", "o/.", "-o/r", "o o/r", "o/r?x", "ö/r", String(repeating: "o", count: 40) + "/r"] {
            #expect(!GitHubRepositoryName.isValid(bad), "\(bad)")
        }
    }

    // MARK: The list

    @Test func theListFiltersAndPutsStarsFirst() async throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (hub, provider) = await readyHub()
        provider.core.accountResult = CoreGitHubAccount(
            access: .ok,
            installations: [CoreGitHubInstallation(id: 1, account: "dil-eight", accountType: "Organization", repositorySelection: "all", htmlURL: nil),
                            CoreGitHubInstallation(id: 2, account: "octocat", accountType: "User", repositorySelection: "selected", htmlURL: nil)],
            repositories: [repository("dil-eight/runnir", description: "Native GitHub Actions client", pushed: 3),
                           repository("octocat/hello", pushed: 2), repository("dil-eight/site", pushed: 1)],
            truncated: false)
        let model = GitHubRepositoriesModel()
        await model.load(hub: hub, login: "me")
        let favorites = RepositoryFavorites(store: FileRepositoryFavoritesStore(directory: folder))
        favorites.toggle("dil-eight/site")

        #expect(model.visible(favorites: favorites).map(\.fullName) == ["dil-eight/site", "dil-eight/runnir", "octocat/hello"])
        model.owner = "octocat"
        #expect(model.visible(favorites: favorites).map(\.fullName) == ["octocat/hello"])
        model.owner = nil
        model.search = "actions NATIVE"
        #expect(model.visible(favorites: favorites).map(\.fullName) == ["dil-eight/runnir"])
        model.search = ""
        model.starredOnly = true
        #expect(model.visible(favorites: favorites).map(\.fullName) == ["dil-eight/site"])
    }

    @Test func aFailedReloadKeepsTheListAndSigningOutClearsIt() async {
        let (hub, provider) = await readyHub()
        provider.core.accountResult = CoreGitHubAccount(access: .ok, installations: [], repositories: [repository("o/r")], truncated: true)
        let model = GitHubRepositoriesModel()
        await model.load(hub: hub, login: "me")
        model.selectedFullName = "o/r"
        #expect(model.repositories.count == 1 && model.truncated && model.selected?.fullName == "o/r")
        #expect(!model.needsReload(for: "me"), "a fresh list is not read again when the tab opens")
        #expect(model.needsReload(for: "someone-else"))

        provider.core.accountResult = .failed(.rateLimited(until: nil))
        await model.load(hub: hub, login: "me")
        #expect(model.repositories.count == 1 && model.access == .rateLimited(until: nil))
        #expect(model.needsReload(for: "me"))
        #expect(GitHubRepositoriesView.listHelp(.rateLimited(until: nil))?.message.hasPrefix("What is shown is from the last read.") == true)
        #expect(GitHubRepositoriesView.listHelp(.permissionMissing)?.fix == .giveAccess(GitHubAccessHelp.installationURL))

        provider.core.accountResult = .failed(.signedOut)
        await model.load(hub: hub, login: "me")
        #expect(model.repositories.isEmpty && model.selected == nil)

        // Another account never sees the first one's list, even when its
        // own read fails.
        provider.core.accountResult = CoreGitHubAccount(access: .ok, installations: [], repositories: [repository("o/r")], truncated: false)
        await model.load(hub: hub, login: "me")
        model.selectedFullName = "o/r"
        provider.core.accountResult = .failed(.unavailable)
        await model.load(hub: hub, login: "other")
        #expect(model.repositories.isEmpty && model.selected == nil && model.loadedLogin == nil)
    }

    @Test func aNewTokenInTheCoreIsCounted() async {
        let (hub, _) = await readyHub()
        // A ready Core is handed the token once by itself; count from after that.
        #expect(await eventually { hub.credentialGeneration >= 1 })
        let before = hub.credentialGeneration
        hub.githubCredentialChanged()
        #expect(await eventually { hub.credentialGeneration == before + 1 },
                "the GitHub tab reads again once the Core has a new sign-in's token")
    }

    // MARK: One repository

    @Test func aRepositoryWithoutACloneIsReadByName() async {
        let (hub, provider) = await readyHub()
        let old = CoreWorkflowRun(id: 5, workflowID: 1, name: "CI", displayTitle: "Fix", runNumber: 5, event: "push", status: "completed",
                                  conclusion: "failure", branch: "main", headSHA: "a", actor: nil, htmlURL: nil, createdAt: Date(), updatedAt: Date())
        provider.core.setRuns(CoreGitHubResult(access: .ok, items: [old]), forRepository: "o/r")
        let model = RemoteRepositoryModel(fullName: "o/r")
        await model.load(hub: hub)
        #expect(provider.core.workflowTargets == ["github:o/r"])
        #expect(provider.core.runsCalls == ["github:o/r"])
        let workflow = try! #require(model.workflows?.items.first)
        #expect(model.latestRun(workflow)?.id == 5)
        #expect(model.access == .ok && !model.hasActiveRuns)

        provider.core.setRuns(CoreGitHubResult(access: .unavailable, items: []), forRepository: "o/r")
        await model.load(hub: hub)
        #expect(model.runs?.items.map(\.id) == [5], "what was read stays shown")
        #expect(model.access == .unavailable)
    }

    @Test func aWorkflowStartsWithoutAClone() async throws {
        let (hub, provider) = await readyHub()
        let workflow = CoreGitHubWorkflow(id: 1, name: "CI", path: ".github/workflows/ci.yml", state: "active", htmlURL: nil)
        let presets = DispatchPresetLibrary(store: FileDispatchPresetStore(directory: directory()))
        let form = DispatchFormModel(target: .repository(GitHubRepositoryRef(serverID: "", fullName: "o/r")), hub: hub, workflows: [workflow], workflowID: 1,
                                     currentBranch: "main", presets: presets)
        #expect(form.presets == nil && form.workspaceID == nil, "presets belong to workspaces")
        await form.load()
        #expect(form.ref == "main")
        await form.review()
        guard case .review = form.step else { Issue.record("step = \(form.step)"); return }
        #expect(provider.core.dispatchTargets.allSatisfy { $0 == "github:o/r" } && provider.core.dispatchTargets.count == 3)

        provider.core.setRuns(CoreGitHubResult(access: .ok, items: []), forRepository: "o/r")
        let confirming = Task { await form.confirm() }
        #expect(await eventually { !provider.core.confirmed.isEmpty })
        let started = CoreWorkflowRun(id: 9, workflowID: 1, name: "CI", displayTitle: "CI", runNumber: 9, event: "workflow_dispatch",
                                      status: "queued", conclusion: nil, branch: "main", headSHA: "b", actor: nil,
                                      htmlURL: URL(string: "https://github.com/o/r/actions/runs/9"), createdAt: Date(), updatedAt: Date())
        provider.core.setRuns(CoreGitHubResult(access: .ok, items: [started]), forRepository: "o/r")
        await confirming.value
        #expect(form.step == .found(started))
    }

    // MARK: Local clones

    @Test func aWorkspaceIsFoundByItsGitHubRepository() async throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FileDesktopStateStore(directory: folder)
        let older = WorkspaceRecord(id: UUID(), path: "/tmp/a", name: "a", bookmark: Data(), lastOpenedAt: Date(timeIntervalSince1970: 1))
        let newer = WorkspaceRecord(id: UUID(), path: "/tmp/b", name: "b", bookmark: Data(), lastOpenedAt: Date(timeIntervalSince1970: 2))
        try store.save(DesktopSnapshot(workspaces: [older, newer]))
        let desktop = DesktopCoordinator(store: store)
        await desktop.loadSession()

        desktop.noteGitHubRepository("Dil-Eight/Runnir", workspaceID: older.id)
        desktop.noteGitHubRepository("dil-eight/runnir", workspaceID: newer.id)
        desktop.noteGitHubRepository("not a name", workspaceID: newer.id)
        #expect(desktop.workspace(forGitHubRepository: "DIL-EIGHT/runnir")?.id == newer.id, "the most recently opened clone")
        #expect(desktop.workspace(forGitHubRepository: "o/other") == nil)
        #expect(try store.load().workspaces.map(\.githubRepository) == ["Dil-Eight/Runnir", "dil-eight/runnir"])

        // An origin no longer on github.com forgets the name.
        desktop.noteGitHubRepository(nil, workspaceID: newer.id)
        #expect(desktop.workspace(forGitHubRepository: "dil-eight/runnir")?.id == older.id)
    }

    @Test func everyAccountIsInOneList() async {
        let (hub, provider) = await readyHub()
        let company = "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed"
        provider.core.accountsByServer = [
            "": CoreGitHubAccount(access: .ok, installations: [], repositories: [repository("o/r")], truncated: false),
            company: CoreGitHubAccount(access: .ok, installations: [], repositories: [repository("o/r"), repository("org/app")], truncated: false,
                                       credentialKind: .classic),
        ]
        let model = GitHubRepositoriesModel()
        await model.load(hub: hub, login: "me", servers: [company])
        #expect(model.repositories.map(\.ref.key) == ["o/r", "\(company):o/r", "\(company):org/app"])
        #expect(Set(model.repositories.map(\.id)).count == 3, "o/r on two servers is two rows")
        #expect(model.credentialKind == .appUser, "github.com's token kind")
        #expect(!model.needsReload(for: "me", servers: [company]))
        #expect(model.needsReload(for: "me", servers: []), "a removed server reads again")

        model.selectedFullName = "\(company):o/r"
        #expect(model.selected?.server == company)
        model.owner = "org"
        #expect(model.visible(favorites: RepositoryFavorites(store: nil)).map(\.ref.key) == ["\(company):org/app"])
        model.owner = nil

        // One server failing keeps its last list and does not hide the other.
        provider.core.accountsByServer[company] = .failed(.unavailable)
        await model.load(hub: hub, login: "me", servers: [company])
        #expect(model.repositories.count == 3 && model.accessByServer[company] == .unavailable && model.accessByServer[""] == .ok)
        #expect(model.needsReload(for: "me", servers: [company]))

        // A removed server's repositories go.
        await model.load(hub: hub, login: "me", servers: [])
        #expect(model.repositories.map(\.ref.key) == ["o/r"] && model.selected == nil)
    }

    @Test func enterpriseOnlyListsWithoutAGitHubDotComSignIn() async {
        let (hub, provider) = await readyHub()
        let company = "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed"
        provider.core.accountsByServer = [company: CoreGitHubAccount(access: .ok, installations: [], repositories: [repository("org/app")],
                                                                     truncated: false, credentialKind: .classic)]
        let model = GitHubRepositoriesModel()
        await model.load(hub: hub, login: nil, servers: [company])
        #expect(model.repositories.map(\.ref.key) == ["\(company):org/app"] && model.access == .ok)
        #expect(model.accessByServer[""] == nil, "github.com is not asked")
    }

    @Test func starsAndClonesTellServersApart() async throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let company = "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed"
        let dotcom = GitHubRepositoryRef(serverID: "", fullName: "o/r")
        let enterprise = GitHubRepositoryRef(serverID: company, fullName: "o/r")

        let favorites = RepositoryFavorites(store: FileRepositoryFavoritesStore(directory: folder))
        #expect(favorites.toggle(enterprise.key))
        #expect(favorites.isFavorite(enterprise.key) && !favorites.isFavorite(dotcom.key))
        #expect(RepositoryFavorites(store: FileRepositoryFavoritesStore(directory: folder)).names == [enterprise.key])

        let store = FileDesktopStateStore(directory: folder)
        let clone = WorkspaceRecord(id: UUID(), path: "/tmp/app", name: "app", bookmark: Data(), lastOpenedAt: Date())
        try store.save(DesktopSnapshot(workspaces: [clone]))
        let desktop = DesktopCoordinator(store: store)
        await desktop.loadSession()
        desktop.noteGitHubRepository(enterprise.key, workspaceID: clone.id)
        #expect(desktop.workspace(for: enterprise)?.id == clone.id)
        #expect(desktop.workspace(for: dotcom) == nil, "o/r on github.com is another repository")
    }

    @Test func registeredClonesAreFoundWithoutOpeningThem() async throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FileDesktopStateStore(directory: folder)
        let clone = WorkspaceRecord(id: UUID(), path: "/tmp/runnir", name: "runnir", bookmark: Data(), lastOpenedAt: Date())
        let other = WorkspaceRecord(id: UUID(), path: "/tmp/notes", name: "notes", bookmark: Data(), lastOpenedAt: Date())
        try store.save(DesktopSnapshot(workspaces: [clone, other]))
        let (hub, provider) = await readyHub()
        provider.core.origins = ["/tmp/runnir": "dil-eight/runnir"]
        let desktop = DesktopCoordinator(store: store, core: hub)
        await desktop.loadSession()

        await desktop.findGitHubOrigins()
        #expect(desktop.workspace(forGitHubRepository: "dil-eight/runnir")?.id == clone.id)
        #expect(try store.load().workspaces.first { $0.id == clone.id }?.githubRepository == "dil-eight/runnir")
        #expect(provider.core.originRequests == [["/tmp/runnir", "/tmp/notes"]])

        // A working tree without a GitHub origin is asked once per launch.
        await desktop.findGitHubOrigins()
        #expect(provider.core.originRequests.count == 1)
    }

    @Test func aRegistrySavedBeforeGitHubNamesStillLoads() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","path":"/a","name":"a","bookmark":"","lastOpenedAt":0}"#
        let record = try JSONDecoder().decode(WorkspaceRecord.self, from: Data(json.utf8))
        #expect(record.githubRepository == nil)
        // A name that is not a GitHub name never makes the registry unreadable.
        var odd = record
        odd.githubRepository = "../x"
        #expect(throws: Never.self) { try DesktopSnapshot(workspaces: [odd]).validate() }
    }
}
