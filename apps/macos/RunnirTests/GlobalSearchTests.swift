import Foundation
import Testing
@testable import Runnir

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct GlobalSearchTests {
    private let current = UUID()
    private let other = UUID()
    private let unreadable = UUID()

    private func record(_ id: UUID, _ name: String) -> WorkspaceRecord {
        WorkspaceRecord(id: id, path: "/repo/\(name)", name: name, bookmark: Data(), lastOpenedAt: Date())
    }

    private func run(_ id: Int64, title: String, conclusion: String = "success") -> CoreWorkflowRun {
        CoreWorkflowRun(id: id, workflowID: 3, name: "CI", displayTitle: title, runNumber: id, event: "push", status: "completed",
                        conclusion: conclusion, branch: "main", headSHA: "abc", actor: "ana", htmlURL: nil,
                        createdAt: Date(timeIntervalSince1970: 1_000_000), updatedAt: nil)
    }

    private func rig() async -> (GlobalSearchModel, FakeProvider) {
        let provider = FakeProvider()
        let hub = CoreHub(provider: provider)
        hub.startMonitoring()
        provider.ready()
        hub.attach(windowID: UUID(), workspaceID: current, path: "/repo/mobile-app")
        _ = await eventually { hub.session(for: current)?.coreID != nil }
        let records = [record(other, "web"), record(current, "mobile-app"), record(unreadable, "old")]
        let model = GlobalSearchModel(hub: hub, currentWorkspaceID: current, workspaces: { records })
        model.debounce = .milliseconds(5)
        return (model, provider)
    }

    private var answer: CoreWorkspaceSearch {
        CoreWorkspaceSearch(workspaces: [
            CoreWorkspaceHits(workspaceID: other, isOpen: false, repository: "o/web", savedAt: Date(timeIntervalSinceNow: -3 * 86_400),
                              runs: [run(1, title: "Fix login on Safari")], runsMatched: 1,
                              pullRequests: [CoreSearchedPullRequest(number: 7, title: "Fix login redirect", state: "open", isDraft: false, author: "ana",
                                                                     headRef: "fix-login", htmlURL: URL(string: "https://github.com/o/web/pull/7"), updatedAt: nil)],
                              pullRequestsMatched: 1),
            CoreWorkspaceHits(workspaceID: UUID(), runs: [run(99, title: "Not registered")], runsMatched: 1),
            CoreWorkspaceHits(workspaceID: current, isOpen: true, repository: "o/mobile-app",
                              runs: [run(12, title: "Fix flaky login test", conclusion: "failure")], runsMatched: 31,
                              workflows: [CoreGitHubWorkflow(id: 4, name: "Login smoke", path: ".github/workflows/login.yml", state: "active", htmlURL: nil)],
                              workflowsMatched: 1),
            CoreWorkspaceHits(workspaceID: unreadable, problem: "Its saved data could not be read now."),
        ])
    }

    @Test func settingsAreFoundByNameKeywordAndDescription() {
        #expect(SettingsIndex.search("touch id").first?.id == "touch-id")
        #expect(SettingsIndex.search("password").first?.section == .runs, "a keyword")
        #expect(SettingsIndex.search("offline").first?.id == "job-logs", "a word of the description")
        #expect(SettingsIndex.search("notif").allSatisfy { $0.section == .notifications || $0.keywords.joined().contains("notif") })
        #expect(SettingsIndex.search("logs offline").map(\.id) == ["job-logs"], "every word has to match")
        #expect(SettingsIndex.search("zzzz").isEmpty && SettingsIndex.search("  ").isEmpty)
        #expect(SettingsIndex.search("pull request").first?.id == "notify-checks" || SettingsIndex.search("pull request").first?.id == "pr-shortcut")
    }

    @Test func everySettingsSectionCanBeFound() {
        for section in SettingsSection.allCases {
            #expect(SettingsIndex.items.contains { $0.section == section }, "\(section.title) has no entry in the search list")
        }
    }

    @Test func theWordsTheCoreReadMarkTheResults() async {
        let (model, provider) = await rig()
        var search = answer
        search.words = ["login"]
        provider.core.workspaceSearchResult = search
        model.update(query: "Login branch:main")
        #expect(model.words == ["login", "branch:main"], "before the answer, the typed words")
        #expect(await eventually { model.status == .done })
        #expect(model.words == ["login"], "the Core says which words are qualifiers")
        let marked = SearchText.marked("Fix login on Login", words: ["login"])
        let emphasized = marked.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }.map { String(marked[$0.range].characters) }
        #expect(emphasized == ["login", "Login"])
        #expect(String(marked.characters) == "Fix login on Login")
    }

    @Test func resultsAreGroupedByKindWithTheWindowsWorkspaceFirst() async {
        let (model, provider) = await rig()
        provider.core.workspaceSearchResult = answer
        model.update(query: "login")
        #expect(await eventually { model.status == .done })
        let kinds = model.results.map(\.kind)
        #expect(kinds == kinds.sorted { $0.rawValue < $1.rawValue }, "kinds stay together")
        let runs = model.results.filter { $0.kind == .run }
        #expect(runs.map(\.workspaceName) == ["mobile-app", "mobile-app", "web"], "the open window's workspace first; a row for the rest of its 31 runs")
        #expect(runs[0].title == "Fix flaky login test" && runs[0].outcome == .failed)
        #expect(runs[1].isMore && runs[1].destination == .runsList(query: "login") && runs[1].title == "Show all 31 runs")
        #expect(runs[0].age == nil, "an open workspace's data is live")
        #expect(runs[2].age?.hasPrefix("saved ") == true, "a closed workspace says how old its data is")
        #expect(model.results.first { $0.kind == .pullRequest }?.destination == .pullRequest(URL(string: "https://github.com/o/web/pull/7")))
        #expect(model.results.first { $0.kind == .workflow }?.destination == .workflow(path: ".github/workflows/login.yml"))
        #expect(model.unreadable.map(\.name) == ["old"], "a workspace that could not be read is named, the others are shown")
        #expect(model.count(.runs) == 2, "the row for the rest is not counted")
    }

    @Test func settingsAnswerAtOnceAndTheCoreAddsTheRest() async {
        let (model, provider) = await rig()
        provider.core.workspaceSearchResult = answer
        model.update(query: "notifications")
        #expect(model.results.contains { $0.kind == .setting }, "no wait for the Core")
        #expect(await eventually { model.status == .done })
        #expect(model.results.contains { $0.kind == .setting && $0.destination == .setting(.notifications) })
    }

    @Test func thisWorkspaceAsksTheCoreForOnlyItself() async {
        let (model, provider) = await rig()
        model.update(query: "login")
        #expect(await eventually { model.status == .done })
        #expect(Set(provider.core.workspaceSearchScopes.last ?? []) == [current, other, unreadable])
        model.scope = .thisWorkspace
        #expect(await eventually { provider.core.workspaceSearchScopes.last == [current] })
    }

    @Test func aCoreThatDoesNotAnswerStillSearchesSettings() async {
        let provider = FakeProvider()
        let model = GlobalSearchModel(hub: CoreHub(provider: provider), currentWorkspaceID: current, workspaces: { [] })
        model.debounce = .milliseconds(5)
        model.update(query: "telemetry")
        #expect(await eventually { model.status == .done || model.status == .unavailable })
        #expect(model.results.map(\.kind) == [.setting])
    }

    @Test func theKeysMoveThroughTheVisibleResultsAndTabsNarrowThem() async {
        let (model, provider) = await rig()
        provider.core.workspaceSearchResult = answer
        model.update(query: "login")
        #expect(await eventually { model.status == .done })
        #expect(model.selected?.id == model.results.first?.id)
        let total = model.visible.count
        model.moveSelection(by: 1)
        #expect(model.selected?.id == model.visible[1].id)
        model.moveSelection(by: -5)
        #expect(model.selected?.id == model.visible[0].id, "it stops at the first")
        model.moveSelection(by: total + 5)
        #expect(model.selected?.id == model.visible.last?.id, "and at the last")
        model.tab = .pullRequests
        #expect(model.visible.map(\.kind) == [.pullRequest] && model.selected?.kind == .pullRequest)
        model.tab = .workflows
        #expect(model.visible.allSatisfy { $0.kind == .workflow || $0.kind == .localRun })
    }

    @Test func clearingTheQueryEndsTheSearch() async {
        let (model, provider) = await rig()
        provider.core.workspaceSearchResult = answer
        model.update(query: "login")
        #expect(await eventually { model.status == .done })
        model.update(query: "  ")
        #expect(model.results.isEmpty && model.status == .idle && model.selection == nil)
    }

    @Test func aSearchResultTakesTheWindowToIt() {
        let state = AppState()
        state.go(to: .run(id: 7, number: 12))
        #expect(state.selectedSection == .runs && state.selectedRunID == 7)
        #expect(state.runsRequest == RunsListRequest(query: "#12", unlessSaved: 7))
        state.go(to: .runsList(query: "branch:main"))
        #expect(state.runsRequest == RunsListRequest(query: "branch:main"))
        state.go(to: .workflow(path: ".github/workflows/ci.yml"))
        #expect(state.selectedSection == .dashboard && state.overviewWorkflowPath == ".github/workflows/ci.yml")
        state.go(to: .localRuns)
        #expect(state.selectedSection == .workspace && state.workspaceTab == .localRun)
    }
}
