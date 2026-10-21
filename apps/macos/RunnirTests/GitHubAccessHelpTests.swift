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
        let form = DispatchFormModel(target: .repository("o/r"), hub: hub, workflows: [workflow], workflowID: 1, currentBranch: "main")
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
