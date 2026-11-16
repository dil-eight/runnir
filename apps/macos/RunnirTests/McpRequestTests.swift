import Foundation
import Testing
@testable import Runnir

@MainActor
final class FakeMcpDesktop: McpDesktop {
    var mcpWorkspaces: [WorkspaceRecord]
    var workflows: [CoreWorkflow]
    var environments: [String]?
    let localRunValues: any LocalRunValueStoring
    var mcpPrompt: McpValuesPrompt?
    var opened: [(UUID, Bool)] = []
    var contextRefusal: String?
    let windowID = UUID()
    var mcpRunPrompt: McpUnsandboxedPrompt?
    var mcpActionsAllowed = true
    var mcpHub: CoreHub?
    var openIDs: Set<UUID> = []
    var shownRuns: [UUID] = []
    var repositoryID = "repo_1"
    /// Requests whose client no longer waits: claiming them fails.
    var gone: Set<String> = []
    var claims: [String] = []

    func mcpIsOpen(_ workspaceID: UUID) -> Bool { openIDs.contains(workspaceID) }
    func mcpClaim(_ requestID: String) async -> Bool {
        claims.append(requestID)
        return !gone.contains(requestID)
    }
    func mcpShowLocalRun(windowID: UUID) { shownRuns.append(windowID) }

    init(workspaces: [WorkspaceRecord], workflows: [CoreWorkflow], environments: [String]? = nil,
         store: any LocalRunValueStoring = InMemoryLocalRunValueStore()) {
        mcpWorkspaces = workspaces
        self.workflows = workflows
        self.environments = environments
        localRunValues = store
    }

    /// Runs while the window "opens".
    var onContext: (() -> Void)?

    func mcpContext(for workspace: WorkspaceRecord, front: Bool) async -> Result<McpWorkspaceContext, McpRefusal> {
        opened.append((workspace.id, front))
        onContext?()
        if let contextRefusal { return .failure(McpRefusal(contextRefusal)) }
        return .success(McpWorkspaceContext(windowID: windowID, workflows: workflows, repositoryID: repositoryID, branch: "feature"))
    }

    func mcpEnvironments(for workspaceID: UUID) async -> [String]? { environments }
}

@MainActor
@Suite struct McpRequestTests {
    private static let fintropy = WorkspaceRecord(id: UUID(), path: "/Users/me/projects/fintropy", name: "fintropy",
                                                  bookmark: Data(), lastOpenedAt: Date())
    private static let memo = WorkspaceRecord(id: UUID(), path: "/Users/me/projects/memo-project", name: "memo-project",
                                              bookmark: Data(), lastOpenedAt: Date())

    private static let workflows = [
        CoreWorkflow(id: ".github/workflows/api.yml", name: "API", triggers: ["push"],
                     jobs: [CoreJob(id: "build", name: "build", needs: [], secrets: ["GHCR_TOKEN"], variables: ["REGION"]),
                            CoreJob(id: "deploy", name: "deploy", needs: ["build"], environment: "production",
                                    secrets: ["DEPLOY_SSH_KEY", "GHCR_TOKEN"])],
                     parseError: nil, secrets: ["DEPLOY_SSH_KEY", "GHCR_TOKEN"], variables: ["REGION"]),
    ]

    private func list(_ repository: String) -> CoreMcpRequest {
        CoreMcpRequest(id: "mcp_1", client: "codex", tool: .listValueSets, repository: repository, set: "", secrets: [], variables: [])
    }

    private func set(_ repository: String, _ set: String, secrets: [(String, String)] = [], variables: [(String, String)] = []) -> CoreMcpRequest {
        CoreMcpRequest(id: "mcp_2", client: "claude-code", tool: .setValues, repository: repository, set: set,
                       secrets: secrets.map { CoreMcpValue(name: $0.0, value: $0.1) },
                       variables: variables.map { CoreMcpValue(name: $0.0, value: $0.1) })
    }

    // MARK: Resolving the workspace

    @Test func aPathANestedPathAndANameFindTheWorkspace() throws {
        let all = [Self.fintropy, Self.memo]
        #expect(try McpWorkspaceResolver.resolve("/Users/me/projects/fintropy", in: all).get() == Self.fintropy)
        #expect(try McpWorkspaceResolver.resolve("/Users/me/projects/fintropy/", in: all).get() == Self.fintropy)
        #expect(try McpWorkspaceResolver.resolve("/Users/me/projects/fintropy/apps/api", in: all).get() == Self.fintropy)
        #expect(try McpWorkspaceResolver.resolve("Memo-Project", in: all).get() == Self.memo)
    }

    @Test func anUnknownOrAmbiguousWorkspaceIsRefusedWithTheNames() {
        let all = [Self.fintropy, Self.memo]
        guard case .failure(let unknown) = McpWorkspaceResolver.resolve("/Users/me/projects/fintropy-old", in: all) else {
            Issue.record("found a workspace")
            return
        }
        #expect(unknown.reason.contains("fintropy") && unknown.reason.contains("memo-project"))
        let twin = WorkspaceRecord(id: UUID(), path: "/Volumes/x/fintropy", name: "fintropy", bookmark: Data(), lastOpenedAt: Date())
        guard case .failure(let ambiguous) = McpWorkspaceResolver.resolve("fintropy", in: all + [twin]) else {
            Issue.record("picked one of two")
            return
        }
        #expect(ambiguous.reason.contains("/Volumes/x/fintropy"))
    }

    // MARK: Listing

    @Test func aListSaysWhatEachSetHas() async throws {
        let store = InMemoryLocalRunValueStore()
        try await store.save(workspaceID: Self.fintropy.id, key: LocalRunValueKey(kind: .secret, name: "GHCR_TOKEN"), value: "s3cr3t")
        try await store.save(workspaceID: Self.fintropy.id, key: LocalRunValueKey(kind: .variable, name: "REGION"), value: "eu-west-1")
        try await store.save(workspaceID: Self.fintropy.id, key: LocalRunValueKey(kind: .secret, name: "OLD", environment: "gone"), value: "x")
        let desktop = FakeMcpDesktop(workspaces: [Self.fintropy], workflows: Self.workflows, environments: ["production"], store: store)
        let handler = McpRequestHandler(desktop: desktop)

        let answer = await handler.answer(list("/Users/me/projects/fintropy"))
        guard case .sets(let sets) = answer else {
            Issue.record("\(answer)")
            return
        }
        #expect(sets.workspace == "fintropy")
        #expect(sets.sets.map(\.name) == ["Repository", "gone", "production"])
        let repository = try #require(sets.sets.first)
        #expect(repository.names.contains(CoreMcpValueName(name: "GHCR_TOKEN", secret: true, state: .saved)))
        #expect(repository.names.contains(CoreMcpValueName(name: "REGION", secret: false, state: .saved, value: "eu-west-1")))
        #expect(repository.names.contains(CoreMcpValueName(name: "DEPLOY_SSH_KEY", secret: true, state: .notNeeded)) == false)
        #expect(repository.names.contains { $0.name == "DEPLOY_SSH_KEY" && $0.state == .missing })
        let production = try #require(sets.sets.last)
        #expect(production.names.contains(CoreMcpValueName(name: "DEPLOY_SSH_KEY", secret: true, state: .missing)))
        #expect(production.names.contains(CoreMcpValueName(name: "GHCR_TOKEN", secret: true, state: .fromRepository)))
        #expect(sets.sets[1].stale)
        // A secret's value never leaves.
        #expect(sets.sets.flatMap(\.names).allSatisfy { !$0.secret || $0.value == nil })
        #expect(desktop.opened.map(\.1) == [false])
    }

    @Test func aWorkspaceThatCannotOpenIsRefused() async {
        let desktop = FakeMcpDesktop(workspaces: [Self.fintropy], workflows: [])
        desktop.contextRefusal = "Runnir has no access to fintropy's folder."
        #expect(await McpRequestHandler(desktop: desktop).answer(list("fintropy")) == .refusal("Runnir has no access to fintropy's folder."))
    }

    // MARK: Setting

    @Test func anUnknownSetIsRefusedWithTheSets() async {
        let desktop = FakeMcpDesktop(workspaces: [Self.fintropy], workflows: Self.workflows, environments: ["production"])
        let answer = await McpRequestHandler(desktop: desktop).answer(set("fintropy", "staging", secrets: [("A", "x")]))
        guard case .refusal(let reason) = answer else {
            Issue.record("\(answer)")
            return
        }
        #expect(reason.contains("staging") && reason.contains("Repository") && reason.contains("production"))
        #expect(desktop.mcpPrompt == nil)
    }

    @Test func saveWritesTheSetsAccountsAndAnswersTheNames() async throws {
        let store = InMemoryLocalRunValueStore()
        try await store.save(workspaceID: Self.fintropy.id, key: LocalRunValueKey(kind: .secret, name: "DEPLOY_SSH_KEY", environment: "production"), value: "old")
        let desktop = FakeMcpDesktop(workspaces: [Self.fintropy], workflows: Self.workflows, environments: ["production"], store: store)
        let handler = McpRequestHandler(desktop: desktop)
        let request = set("/Users/me/projects/fintropy", "Production", secrets: [("deploy_ssh_key", "new-key")], variables: [("REGION", "us-east-1")])
        let answering = Task { await handler.answer(request) }
        let prompt = try #require(await waitForPrompt(desktop))
        #expect(prompt.windowID == desktop.windowID)
        #expect(prompt.setName == "production")
        #expect(prompt.rows.map(\.name) == ["DEPLOY_SSH_KEY", "REGION"])
        #expect(prompt.rows.first?.replaces == true)
        #expect(prompt.rows.last?.replaces == false)
        #expect(prompt.rows.first?.shown == false)
        prompt.toggleShown("DEPLOY_SSH_KEY")
        #expect(prompt.rows.first?.shown == true)
        #expect(desktop.opened.map(\.1) == [true])

        await prompt.save(store: store)
        let answer = await answering.value
        #expect(answer == .saved(CoreMcpSaved(workspace: "fintropy", set: "production", secrets: ["DEPLOY_SSH_KEY"], variables: ["REGION"])))
        #expect(try await store.value(workspaceID: Self.fintropy.id, key: LocalRunValueKey(kind: .secret, name: "DEPLOY_SSH_KEY", environment: "production")) == "new-key")
        #expect(try await store.value(workspaceID: Self.fintropy.id, key: LocalRunValueKey(kind: .variable, name: "REGION", environment: "production")) == "us-east-1")
        #expect(desktop.mcpPrompt == nil)
    }

    @Test func theRepositorySetWritesWithoutAnEnvironment() async throws {
        let store = InMemoryLocalRunValueStore()
        let desktop = FakeMcpDesktop(workspaces: [Self.fintropy], workflows: Self.workflows, store: store)
        let handler = McpRequestHandler(desktop: desktop)
        let answering = Task { await handler.answer(set("fintropy", "repository", secrets: [("GHCR_TOKEN", "t")])) }
        let prompt = try #require(await waitForPrompt(desktop))
        await prompt.save(store: store)
        _ = await answering.value
        #expect(try await store.keys(workspaceID: Self.fintropy.id) == [LocalRunValueKey(kind: .secret, name: "GHCR_TOKEN")])
    }

    @Test func cancelAnswersARefusalAndSavesNothing() async throws {
        let store = InMemoryLocalRunValueStore()
        let desktop = FakeMcpDesktop(workspaces: [Self.fintropy], workflows: Self.workflows, store: store)
        let handler = McpRequestHandler(desktop: desktop)
        let answering = Task { await handler.answer(set("fintropy", "Repository", secrets: [("GHCR_TOKEN", "t")])) }
        let prompt = try #require(await waitForPrompt(desktop))
        prompt.cancel()
        #expect(await answering.value == .refusal("Cancelled in Runnir. Nothing was saved."))
        #expect(try await store.keys(workspaceID: Self.fintropy.id).isEmpty)
        #expect(desktop.mcpPrompt == nil)
    }

    @Test func anUnansweredPromptExpiresBeforeTheCoreGivesUp() async throws {
        let desktop = FakeMcpDesktop(workspaces: [Self.fintropy], workflows: Self.workflows)
        let handler = McpRequestHandler(desktop: desktop, promptLifetime: .milliseconds(50))
        let answer = await handler.answer(set("fintropy", "Repository", secrets: [("GHCR_TOKEN", "t")]))
        guard case .refusal(let reason) = answer else {
            Issue.record("\(answer)")
            return
        }
        #expect(reason.contains("Nobody answered"))
        #expect(desktop.mcpPrompt == nil)
    }

    /// Save claims the request first: a call the Core already answered,
    /// telling its client nothing was saved, saves nothing.
    @Test func aCallThatStoppedWaitingSavesNothing() async throws {
        let store = InMemoryLocalRunValueStore()
        let desktop = FakeMcpDesktop(workspaces: [Self.fintropy], workflows: Self.workflows, store: store)
        let handler = McpRequestHandler(desktop: desktop)
        let answering = Task { await handler.answer(set("fintropy", "Repository", secrets: [("GHCR_TOKEN", "t")])) }
        let prompt = try #require(await waitForPrompt(desktop))
        desktop.gone = ["mcp_2"]
        await prompt.save(store: store)
        #expect(await answering.value == .refusal(McpValuesPrompt.gone))
        #expect(desktop.claims == ["mcp_2"])
        #expect(try await store.keys(workspaceID: Self.fintropy.id).isEmpty)
        #expect(desktop.mcpPrompt == nil)
    }

    /// A request the Core withdraws takes its question down, or never shows it.
    @Test func aWithdrawnRequestComesDown() async throws {
        let desktop = FakeMcpDesktop(workspaces: [Self.fintropy], workflows: Self.workflows)
        let handler = McpRequestHandler(desktop: desktop)
        let answering = Task { await handler.answer(set("fintropy", "Repository", secrets: [("GHCR_TOKEN", "t")])) }
        _ = try #require(await waitForPrompt(desktop))
        handler.withdraw("mcp_2")
        #expect(await answering.value == .refusal(McpValuesPrompt.gone))
        #expect(desktop.mcpPrompt == nil)

        // Withdrawn while the window opens, before the question came up.
        desktop.onContext = { handler.withdraw("mcp_2") }
        #expect(await handler.answer(set("fintropy", "Repository", secrets: [("GHCR_TOKEN", "t")])) == .refusal(McpValuesPrompt.gone))
        #expect(desktop.mcpPrompt == nil, "withdrawn before it came up")
    }

    /// The question lasts until a few seconds before the Core stops waiting,
    /// counted from when the Core asked, not from when it came up.
    @Test func aPromptEndsBeforeTheCoresDeadline() async {
        let desktop = FakeMcpDesktop(workspaces: [Self.fintropy], workflows: Self.workflows)
        var request = set("fintropy", "Repository", secrets: [("GHCR_TOKEN", "t")])
        request.expiresAt = Date().addingTimeInterval(5.05)
        let started = Date()
        let answer = await McpRequestHandler(desktop: desktop).answer(request)
        guard case .refusal(let reason) = answer else {
            Issue.record("\(answer)")
            return
        }
        #expect(reason.contains("Nobody answered"))
        #expect(Date().timeIntervalSince(started) < 2)
    }

    /// Cancel, expiry and withdrawal wait for a save that has started.
    @Test func aSaveThatStartedIsNotCancelled() async throws {
        let store = SlowValueStore()
        let desktop = FakeMcpDesktop(workspaces: [Self.fintropy], workflows: Self.workflows, store: store)
        let handler = McpRequestHandler(desktop: desktop)
        let answering = Task { await handler.answer(set("fintropy", "Repository", secrets: [("A", "1"), ("B", "2")])) }
        let prompt = try #require(await waitForPrompt(desktop))
        let saving = Task { await prompt.save(store: store) }
        while !prompt.isSaving { await Task.yield() }
        prompt.cancel()
        prompt.expire()
        prompt.withdraw()
        store.release()
        await saving.value
        #expect(await answering.value == .saved(CoreMcpSaved(workspace: "fintropy", set: "Repository", secrets: ["A", "B"], variables: [])))
    }

    @Test func namesThatDifferOnlyInCaseAreRefused() async {
        let desktop = FakeMcpDesktop(workspaces: [Self.fintropy], workflows: Self.workflows)
        let answer = await McpRequestHandler(desktop: desktop).answer(set("fintropy", "Repository", secrets: [("api_key", "a")], variables: [("API_KEY", "b")]))
        guard case .refusal(let reason) = answer else {
            Issue.record("\(answer)")
            return
        }
        #expect(reason.contains("API_KEY"))
    }

    // MARK: Workspaces and actions

    @Test func workspacesAreListedByNameWithTheOpenOnes() async {
        let desktop = FakeMcpDesktop(workspaces: [Self.memo, Self.fintropy], workflows: [])
        desktop.openIDs = [Self.memo.id]
        let answer = await McpRequestHandler(desktop: desktop).answer(CoreMcpRequest(id: "m", client: "codex", tool: .listWorkspaces,
                                                                                     repository: "", set: "", secrets: [], variables: []))
        #expect(answer == .workspaces([
            CoreMcpWorkspace(name: "fintropy", path: Self.fintropy.path, workspaceID: Self.fintropy.id, open: false),
            CoreMcpWorkspace(name: "memo-project", path: Self.memo.path, workspaceID: Self.memo.id, open: true),
        ]))
        #expect(desktop.opened.isEmpty, "listing opens no window")
    }

    private func open(_ repository: String, action: Bool) -> CoreMcpRequest {
        CoreMcpRequest(id: "m", client: "codex", tool: .openWorkspace, repository: repository, set: "", secrets: [], variables: [], action: action)
    }

    @Test func anOpenedWorkspaceGivesItsRepositoryInTheCore() async {
        let desktop = FakeMcpDesktop(workspaces: [Self.fintropy], workflows: [])
        let answer = await McpRequestHandler(desktop: desktop).answer(open("/Users/me/projects/fintropy/apps", action: false))
        #expect(answer == .workspace(CoreMcpOpenedWorkspace(
            workspace: CoreMcpWorkspace(name: "fintropy", path: Self.fintropy.path, workspaceID: Self.fintropy.id, open: true),
            repositoryID: "repo_1", branch: "feature")))
        #expect(desktop.opened.map(\.1) == [false], "the window opens behind")
        desktop.repositoryID = ""
        guard case .refusal(let reason) = await McpRequestHandler(desktop: desktop).answer(open("fintropy", action: false)) else {
            Issue.record("answered without a repository")
            return
        }
        #expect(reason.contains("has not opened"))
    }

    @Test func actionsTurnedOffAreRefusedAndReadingGoesOn() async {
        let desktop = FakeMcpDesktop(workspaces: [Self.fintropy], workflows: Self.workflows)
        desktop.mcpActionsAllowed = false
        let handler = McpRequestHandler(desktop: desktop)
        #expect(await handler.answer(open("fintropy", action: true)) == .refusal(McpRequestHandler.actionsOff))
        #expect(await handler.answer(set("fintropy", "Repository", secrets: [("A", "x")])) == .refusal(McpRequestHandler.actionsOff))
        let start = CoreMcpRequest(id: "m", client: "codex", tool: .startLocalRun, repository: "fintropy", set: "", secrets: [], variables: [],
                                   action: true, start: CoreMcpLocalRunStart())
        #expect(await handler.answer(start) == .refusal(McpRequestHandler.actionsOff))
        #expect(desktop.opened.isEmpty, "nothing opened for a refused action")
        guard case .workspace = await handler.answer(open("fintropy", action: false)) else {
            Issue.record("reading was refused")
            return
        }
        guard case .sets = await handler.answer(list("fintropy")) else {
            Issue.record("listing values was refused")
            return
        }
    }

    private func waitForPrompt(_ desktop: FakeMcpDesktop) async -> McpValuesPrompt? {
        for _ in 0..<200 {
            if let prompt = desktop.mcpPrompt { return prompt }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }
}

@Suite struct McpSettingsTests {
    @Test func theClaudeCommandQuotesPathsForTheShell() {
        let command = McpSettings.claudeCommand(name: "runnir-local", helper: "/Users/me/Applications/Runnir Local.app/Contents/Helpers/runnir-core")
        #expect(command == "claude mcp add --scope user runnir-local -- '/Users/me/Applications/Runnir Local.app/Contents/Helpers/runnir-core' mcp")
        #expect(McpSettings.shellQuoted("it's") == "'it'\\''s'")
    }

    @Test func theCodexBlockWaitsLongEnoughForAConfirmation() {
        let block = McpSettings.codexBlock(name: "runnir-dev", helper: "/A \"B\"/runnir-core")
        #expect(block.contains("[mcp_servers.runnir-dev]"))
        #expect(block.contains(#"command = "/A \"B\"/runnir-core""#))
        #expect(block.contains(#"args = ["mcp"]"#))
        #expect(block.contains("tool_timeout_sec = 300"))
    }

    @Test func thePluginReachesOnlyABuildOfATagInApplications() {
        let applications = "/Applications/Runnir.app/Contents/Helpers/runnir-core"
        #expect(McpSettings.pluginReaches(build: .release, helper: applications))
        #expect(McpSettings.pluginReaches(build: .alpha, helper: applications))
        #expect(!McpSettings.pluginReaches(build: .local, helper: applications))
        #expect(!McpSettings.pluginReaches(build: .release, helper: "/Users/me/Applications/Runnir.app/Contents/Helpers/runnir-core"))
        #expect(McpSettings.claudePluginCommands.contains("claude plugin install runnir@runnir"))
        #expect(McpSettings.codexPluginCommands.contains("codex plugin add runnir@runnir"))
    }

    @Test func eachBuildHasItsOwnServerName() {
        #expect(Set(RunnirBuild.allCases.map(McpSettings.serverName(for:))) == ["runnir", "runnir-dev", "runnir-local"])
    }

    @Test func theSettingIsFoundBySearch() {
        #expect(SettingsIndex.items.contains { $0.section == .mcp && $0.keywords.contains("codex") })
    }
}

/// Saves as the in-memory store does once released, so a test can act while
/// a save is under way.
@MainActor
final class SlowValueStore: LocalRunValueStoring {
    private let store = InMemoryLocalRunValueStore()
    private var released = false

    func release() { released = true }

    func save(workspaceID: UUID, key: LocalRunValueKey, value: String) async throws {
        while !released { try await Task.sleep(for: .milliseconds(5)) }
        try await store.save(workspaceID: workspaceID, key: key, value: value)
    }

    func value(workspaceID: UUID, key: LocalRunValueKey) async throws -> String? { try await store.value(workspaceID: workspaceID, key: key) }
    func keys(workspaceID: UUID) async throws -> Set<LocalRunValueKey> { try await store.keys(workspaceID: workspaceID) }
    func remove(workspaceID: UUID, key: LocalRunValueKey) async throws { try await store.remove(workspaceID: workspaceID, key: key) }
    func removeAll(workspaceID: UUID) async throws { try await store.removeAll(workspaceID: workspaceID) }
}
