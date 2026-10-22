import Foundation
import Testing
@testable import Runnir

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct GitHubAccessHelpTests {
    private let settings = URL(string: "https://github.com/organizations/o/settings/installations/5")!

    private func installation(missing: [String] = [], suspended: Bool = false, type: String = "Organization") -> CoreGitHubInstallation {
        CoreGitHubInstallation(id: 5, account: "o", accountType: type, repositorySelection: "selected", htmlURL: settings,
                               missingPermissions: missing, suspended: suspended)
    }

    private func details(canPush: Bool, installation: CoreGitHubInstallation? = nil) -> CoreGitHubRepository {
        CoreGitHubRepository(access: .ok, fullName: "o/r", visibility: "private", defaultBranch: "main", htmlURL: nil,
                             canPush: canPush, installation: installation)
    }

    @Test func connectingIsOfferedOnlyWithoutASignIn() {
        #expect(GitHubAccessHelp.forAccess(.signedOut, repository: "o/r", purpose: .read)?.fix == .connect)
        #expect(GitHubAccessHelp.forAccess(.tokenRejected, repository: "o/r", purpose: .run)?.fix == .signInAgain)
        #expect(GitHubAccessHelp.forAccess(.notVisible, repository: "o/r", purpose: .read)?.fix == .giveAccess(GitHubAccessHelp.installationURL))
        #expect(GitHubAccessHelp.forAccess(.ok, repository: "o/r", purpose: .read) == nil)
        #expect(GitHubAccessHelp.Fix.signInAgain.buttonTitle == "Sign In Again...")
        #expect(GitHubAccessHelp.Fix.askForWriteAccess.buttonTitle == nil, "the user's own rights are explained, not fixed here")
    }

    @Test func aRefusalSaysWhetherAnOwnerOrTheUserHasToAct() {
        // New permissions an owner has not accepted.
        let pending = GitHubAccessHelp.forAccess(.permissionMissing, repository: "o/r", purpose: .run,
                                                 details: details(canPush: true, installation: installation(missing: ["actions: write"])))
        #expect(pending?.fix == .reviewPermissions(settings))
        #expect(pending?.title == "Runnir Desktop needs new permissions on o")
        #expect(pending?.message.contains("Actions (write)") == true && pending?.message.contains("An owner of o") == true)

        // On a personal account the user is the owner.
        let personal = GitHubAccessHelp.pendingPermissions(installation(missing: ["actions: write"], type: "User"))
        #expect(personal.message.contains("o reviews and accepts them on GitHub."))

        // No write access for the user.
        let readOnly = GitHubAccessHelp.forAccess(.permissionMissing, repository: "o/r", purpose: .change, details: details(canPush: false))
        #expect(readOnly?.fix == .askForWriteAccess)
        #expect(readOnly?.title == "You can't cancel or re-run runs in o/r")

        // Nothing known: check the app's permissions.
        let unknown = GitHubAccessHelp.forAccess(.permissionMissing, repository: "o/r", purpose: .read, details: nil)
        #expect(unknown?.fix == .reviewPermissions(GitHubAccessHelp.installationURL))
    }

    @Test func blockersAreKnownBeforeTrying() {
        #expect(GitHubAccessHelp.blocker(for: .run, repository: "o/r", details: details(canPush: false))?.fix == .askForWriteAccess)
        #expect(GitHubAccessHelp.blocker(for: .read, repository: "o/r", details: details(canPush: false)) == nil, "reading needs no write access")
        #expect(GitHubAccessHelp.blocker(for: .run, repository: "o/r", details: details(canPush: true)) == nil)
        // Starting workflows waits for Actions write, not for other permissions.
        let actions = details(canPush: true, installation: installation(missing: ["actions: write"]))
        #expect(GitHubAccessHelp.blocker(for: .run, repository: "o/r", details: actions)?.fix == .reviewPermissions(settings))
        #expect(GitHubAccessHelp.blocker(for: .read, repository: "o/r", details: actions) == nil)
        let contents = details(canPush: true, installation: installation(missing: ["contents: read"]))
        #expect(GitHubAccessHelp.blocker(for: .run, repository: "o/r", details: contents) == nil)
        // A suspended installation blocks everything.
        let suspended = details(canPush: true, installation: installation(suspended: true))
        #expect(GitHubAccessHelp.blocker(for: .read, repository: "o/r", details: suspended)?.title == "Runnir Desktop is suspended on o")
        // An unknown repository blocks nothing yet.
        #expect(GitHubAccessHelp.blocker(for: .run, repository: "o/r", details: nil) == nil)
        #expect(GitHubAccessHelp.permissionName("actions: write") == "Actions (write)")
    }

    @Test func aPersonalTokenIsFixedInItsSettings() {
        let fine = GitHubAccessHelp.forAccess(.notVisible, repository: "o/r", purpose: .read, credential: .fineGrained)
        #expect(fine?.fix == .editToken(GitHubTokenAdvice.fineGrainedSettingsURL))
        #expect(fine?.message.contains("Add o/r to the token's repository access") == true)
        #expect(fine?.fix.buttonTitle == "Edit Token on GitHub...")

        let classic = GitHubAccessHelp.forAccess(.permissionMissing, repository: "o/r", purpose: .run, details: details(canPush: true), credential: .classic)
        #expect(classic?.fix == .editToken(GitHubTokenAdvice.classicSettingsURL))
        #expect(classic?.message.contains("repo scope") == true)

        let actions = GitHubAccessHelp.forAccess(.permissionMissing, repository: "o/r", purpose: .change, details: details(canPush: true), credential: .fineGrained)
        #expect(actions?.message.contains("Actions: Read and write") == true)

        // The user's own rights are still the user's own.
        #expect(GitHubAccessHelp.forAccess(.permissionMissing, repository: "o/r", purpose: .run, details: details(canPush: false),
                                           credential: .fineGrained)?.fix == .askForWriteAccess)
        #expect(GitHubAccessHelp.forAccess(.tokenRejected, repository: "o/r", purpose: .read, credential: .classic)?.fix == .signInAgain)
        // Signed in through the app, a repository it does not reach still asks to give it access.
        #expect(GitHubAccessHelp.forAccess(.notVisible, repository: "o/r", purpose: .read, credential: .appUser)?.fix
                == .giveAccess(GitHubAccessHelp.installationURL))
        #expect(GitHubRepositoriesView.listHelp(.notVisible, credential: .fineGrained)?.fix == .editToken(GitHubTokenAdvice.fineGrainedSettingsURL))
        #expect(GitHubRepositoriesView.listHelp(.notVisible, credential: .appUser)?.fix == .giveAccess(GitHubAccessHelp.installationURL))
    }

    @Test func theHubKnowsTheTokenKindAndChecksTokens() async {
        let provider = FakeProvider()
        let hub = CoreHub(provider: provider)
        hub.githubTokenProvider = { "github_pat_held" }
        hub.startMonitoring()
        provider.ready()
        #expect(await eventually { hub.credentialKind == .fineGrained })

        provider.core.tokenCheck = CoreGitHubTokenCheck(access: .ok, kind: .classic, login: "octocat", scopes: ["repo"], expiresAt: nil,
                                                        repositories: 0, checks: [.init(name: "Scope repo", state: .passed, detail: "")],
                                                        suitable: true)
        let check = await hub.checkGitHubToken("ghp_checked")
        #expect(check.suitable && check.login == "octocat")
        #expect(provider.core.checkedTokens == ["ghp_checked"])
        #expect(provider.core.credentialCalls.last == "github_pat_held", "checking does not replace the held token")
    }

    @Test func aRefusedDispatchExplainsItself() async {
        let provider = FakeProvider()
        let hub = CoreHub(provider: provider)
        hub.startMonitoring()
        provider.ready()
        _ = await eventually { hub.status == .ready(version: "fake") }
        provider.core.preparedAccess = .permissionMissing
        provider.core.repositoryResult = CoreGitHubRepository(access: .ok, fullName: "o/r", visibility: "private", defaultBranch: "main",
                                                              htmlURL: nil, canPush: false)
        let workflow = CoreGitHubWorkflow(id: 1, name: "CI", path: ".github/workflows/ci.yml", state: "active", htmlURL: nil)
        let form = DispatchFormModel(target: .repository(GitHubRepositoryRef(serverID: "", fullName: "o/r")), hub: hub, workflows: [workflow], workflowID: 1, currentBranch: "main")
        await form.load()
        await form.review()
        #expect(form.accessHelp?.fix == .askForWriteAccess)
        #expect(form.accessHelp?.title == "You can't start workflows in o/r")
    }

    @Test func aRunChangeTheUserCannotMakeIsNotAsked() async {
        let provider = FakeProvider()
        let hub = CoreHub(provider: provider)
        hub.startMonitoring()
        provider.ready()
        let workspace = UUID()
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/linked")
        _ = await eventually { hub.session(for: workspace)?.githubAccess == .ok }
        provider.core.repositoryResult = CoreGitHubRepository(access: .ok, fullName: "o/r", visibility: "private", defaultBranch: "main",
                                                              htmlURL: nil, canPush: false)
        await hub.githubRepository(workspaceID: workspace)
        #expect(hub.session(for: workspace)?.githubDetails?.canPush == false)

        let model = RunActionModel(hub: hub, workspaceID: workspace)
        let run = CoreWorkflowRun(id: 1, workflowID: 1, name: "CI", displayTitle: "CI", runNumber: 1, event: "push", status: "in_progress",
                                  conclusion: nil, branch: "main", headSHA: "a", actor: nil, htmlURL: nil, createdAt: Date(), updatedAt: Date())
        await model.prepare(.cancel, for: run)
        #expect(model.accessHelp?.fix == .askForWriteAccess)
        #expect(model.phase == .idle)
        #expect(provider.core.runActions.isEmpty, "nothing was asked of GitHub")
    }
}

struct EnterpriseAccessHelpTests {
    let company = GitHubServerRef(id: "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed", apiURL: URL(string: "https://github.company.com/api/v3"),
                                  webHost: "github.company.com", webURL: URL(string: "https://github.company.com"))

    @Test func enterpriseNoticesNameTheServer() {
        let signedOut = GitHubAccessHelp.forAccess(.signedOut, repository: "org/app", purpose: .read, credential: nil, server: company)
        #expect(signedOut?.title == "Sign in to github.company.com" && signedOut?.fix == .openSettings)
        let rejected = GitHubAccessHelp.forAccess(.tokenRejected, repository: "org/app", purpose: .read, credential: .classic, server: company)
        #expect(rejected?.fix == .openSettings && rejected?.message.contains("github.company.com") == true)
        let hidden = GitHubAccessHelp.forAccess(.notVisible, repository: "org/app", purpose: .read, credential: .fineGrained, server: company)
        #expect(hidden?.fix == .editToken(URL(string: "https://github.company.com/settings/personal-access-tokens")!))
        let down = GitHubAccessHelp.forAccess(.unavailable, repository: "org/app", purpose: .read, credential: .classic, server: company)
        #expect(down?.title == "github.company.com could not be reached")
        // github.com keeps its own wording and fixes.
        #expect(GitHubAccessHelp.forAccess(.signedOut, repository: "o/r", purpose: .read)?.fix == .connect)
    }

    @Test func anOriginOnAnUnknownHostSuggestsAddingTheServer() {
        let unknown = GitHubAccessHelp.noRemote(originHost: "ghe.example")
        #expect(unknown.fix == .openSettings && unknown.message.contains("ghe.example"))
        #expect(GitHubAccessHelp.forAccess(.noRemote, repository: nil, purpose: .read, originHost: "ghe.example") == unknown)
        #expect(GitHubAccessHelp.noRemote(originHost: nil).fix == .none)
        #expect(GitHubAccessHelp.noRemote(originHost: "github.com").fix == .none)
    }

    @Test func theServerShowsOnAPullRequestWhenGiven() {
        var pr = CorePullRequest(repository: "org/app", number: 3, title: "T", htmlURL: nil, state: "open", draft: false, headBranch: "b",
                                 updatedAt: nil, closedAt: nil, ci: .passed, ciRuns: 1, ciFailed: 0, ciRunning: 0, ciURL: nil)
        pr.server = company.id
        #expect(PullRequestRow.subtitle(pr, serverHost: "github.company.com") == "github.company.com · org/app #3 · CI passed")
        #expect(PullRequestRow.subtitle(pr, serverHost: nil) == "org/app #3 · CI passed")
    }
}
