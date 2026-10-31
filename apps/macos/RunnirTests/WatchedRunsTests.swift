import Foundation
import Testing
@testable import Runnir

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct WatchedRunsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func readyHub() async -> (CoreHub, FakeProvider) {
        let provider = FakeProvider()
        let hub = CoreHub(provider: provider)
        hub.startMonitoring()
        provider.ready()
        _ = await eventually { hub.status == .ready(version: "fake") }
        return (hub, provider)
    }

    private func ref(_ key: String) -> GitHubRepositoryRef { GitHubRepositoryRef(key: key)! }

    private func run(_ id: Int64, status: String = "completed", conclusion: String? = "failure", attempt: Int64 = 1,
                     minutesAgo: Double = 5, starts: [CoreRunnirStart] = []) -> CoreWorkflowRun {
        let at = now.addingTimeInterval(-minutesAgo * 60)
        return CoreWorkflowRun(id: id, workflowID: 1, name: "CI", displayTitle: "Fix login", runNumber: id, event: "push",
                               status: status, conclusion: conclusion, branch: "main", headSHA: "abc", actor: "ana",
                               htmlURL: URL(string: "https://github.com/o/r/actions/runs/\(id)"), createdAt: at, updatedAt: at,
                               runAttempt: attempt, runnirStarts: starts)
    }

    private func answer(_ key: String, failed: [CoreWorkflowRun] = [], running: [CoreWorkflowRun] = [],
                        access: CoreGitHubAccess = .ok, watched: Bool = true, workspaces: [UUID] = [], read: Bool = true) -> CoreWatchedRuns {
        CoreWatchedRuns(repository: CoreWatchedRepository(repository: ref(key), workspaceIDs: workspaces), access: access,
                        watched: watched, failed: failed, running: running, readAt: read ? now : nil)
    }

    @Test func workspacesComeFirstThenStarredOnceEach() {
        let a = UUID(), b = UUID(), c = UUID()
        let ghe = "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed"
        let workspaces = [
            WorkspaceRecord(id: a, path: "/a", name: "a", bookmark: Data(), lastOpenedAt: now, githubRepository: "o/r"),
            WorkspaceRecord(id: UUID(), path: "/n", name: "n", bookmark: Data(), lastOpenedAt: now),
            WorkspaceRecord(id: b, path: "/b", name: "b", bookmark: Data(), lastOpenedAt: now, githubRepository: "O/R"),
            WorkspaceRecord(id: c, path: "/c", name: "c", bookmark: Data(), lastOpenedAt: now, githubRepository: "\(ghe):corp/app"),
        ]
        let sent = WatchedRepositories.of(workspaces: workspaces, isOpen: { $0 == b }, starred: ["o/R", "o/s", "not a key"])
        #expect(sent.map(\.repository.key) == ["o/r", "\(ghe):corp/app", "o/s"])
        #expect(sent[0].workspaceIDs == [b, a], "the open one first: a click opens it")
        #expect(sent[1].workspaceIDs == [c] && sent[2].workspaceIDs.isEmpty)
    }

    @Test func sectionsChipsAndTheDot() async {
        let (hub, provider) = await readyHub()
        provider.core.watchedRunsResult = CoreWatchedRunsList(repositories: [
            answer("o/r", failed: [run(1, minutesAgo: 30)], running: [run(2, status: "queued", conclusion: nil, minutesAgo: 9)]),
            answer("o/s", failed: [run(3, minutesAgo: 2)], running: [run(4, status: "in_progress", conclusion: nil, minutesAgo: 1)]),
            answer("o/gone", access: .notVisible),
            answer("o/far", watched: false),
        ], pauses: [:])
        let model = WatchedRunsModel(store: nil)
        model.repositories = { [CoreWatchedRepository(repository: GitHubRepositoryRef(key: "o/r")!)] }
        await model.refresh(hub: hub)
        #expect(model.failed.map(\.run.id) == [3, 1])
        #expect(model.running.map(\.run.id) == [4, 2])
        #expect(model.skipped.map(\.repository.repository.fullName) == ["o/gone"] && model.unwatched.count == 1)
        #expect(model.watched.count == 3 && model.badge == .failed)
        #expect(provider.core.watchedRunsCalls.first?.refresh == false)
        await model.refresh(hub: hub, force: true)
        #expect(provider.core.watchedRunsCalls.last?.refresh == true)
    }

    @Test func aRemovedRunStaysRemovedUntilAnotherAttemptFails() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("runs-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (hub, provider) = await readyHub()
        provider.core.watchedRunsResult = CoreWatchedRunsList(repositories: [answer("o/r", failed: [run(5)])], pauses: [:])
        let store = FileDismissalStore(directory: folder, fileName: FileDismissalStore.runsFile)
        let model = WatchedRunsModel(store: store)
        model.repositories = { [CoreWatchedRepository(repository: GitHubRepositoryRef(key: "o/r")!)] }
        await model.refresh(hub: hub)
        model.dismiss(try #require(model.failed.first))
        #expect(model.failed.isEmpty && model.badge == .none)

        let again = WatchedRunsModel(store: store)
        again.repositories = model.repositories
        await again.refresh(hub: hub)
        #expect(again.failed.isEmpty, "kept on this Mac")
        provider.core.watchedRunsResult = CoreWatchedRunsList(repositories: [answer("o/r", failed: [run(5, attempt: 2)])], pauses: [:])
        await again.refresh(hub: hub)
        #expect(again.failed.map(\.run.runAttempt) == [2], "a re-run that failed again comes back")
        again.restoreDismissed()
        #expect(again.dismissed.isEmpty)
    }

    @Test func aRenamedRepositoryListsItsRunsOnceAndTheScopeCountsWhatWasRead() async {
        let (hub, provider) = await readyHub()
        let queued = run(2, status: "queued", conclusion: nil)
        // A workspace links the old name, the star the new one: GitHub answers both.
        provider.core.watchedRunsResult = CoreWatchedRunsList(repositories: [
            answer("o/old", failed: [run(1)], running: [queued], workspaces: [UUID(), UUID()]),
            answer("o/new", failed: [run(1)], running: [queued]),
            answer("o/gone", access: .notVisible, workspaces: [UUID()], read: false),
        ], pauses: [:])
        let model = WatchedRunsModel(store: nil)
        model.repositories = { [CoreWatchedRepository(repository: GitHubRepositoryRef(key: "o/old")!)] }
        await model.refresh(hub: hub)
        #expect(model.failed.map(\.run.id) == [1] && model.running.map(\.run.id) == [2])
        #expect(model.scope.workspaces == 2 && model.scope.starred == 1, "workspaces, not repositories; the skipped one is not counted")
    }

    @Test func noAnswerFromTheCoreKeepsWhatWasRead() async {
        let (hub, provider) = await readyHub()
        let model = WatchedRunsModel(store: nil)
        model.repositories = { [CoreWatchedRepository(repository: GitHubRepositoryRef(key: "o/r")!)] }
        await model.refresh(hub: hub)
        #expect(model.unanswered && model.loadedAt == nil && model.answers.isEmpty)
        provider.core.watchedRunsResult = CoreWatchedRunsList(repositories: [answer("o/r", failed: [run(1)])], pauses: [:])
        await model.refresh(hub: hub)
        #expect(!model.unanswered && model.failed.count == 1)
        provider.core.watchedRunsResult = nil
        await model.refresh(hub: hub)
        #expect(model.unanswered && model.failed.map(\.run.id) == [1])
    }

    @Test func nothingToWatchAsksNothing() async {
        let (hub, provider) = await readyHub()
        let model = WatchedRunsModel(store: nil)
        await model.refresh(hub: hub)
        #expect(provider.core.watchedRunsCalls.isEmpty && model.answers.isEmpty && model.loadedAt != nil)
    }

    @Test func pollingAsksAgainWhenTheWatchedRepositoriesChange() async {
        let (hub, provider) = await readyHub()
        provider.core.watchedRunsResult = CoreWatchedRunsList(repositories: [], pauses: [:])
        let model = WatchedRunsModel(store: nil)
        var keys = ["o/r"]
        model.repositories = { keys.map { CoreWatchedRepository(repository: GitHubRepositoryRef(key: $0)!) } }
        model.startPolling(hub: hub, retry: .milliseconds(20)) { true }
        defer { model.stopPolling() }
        #expect(await eventually { provider.core.watchedRunsCalls.count == 1 })
        keys.append("o/s")
        #expect(await eventually { provider.core.watchedRunsCalls.last?.repositories.count == 2 })
    }

    @Test func theDotAndTheLabelNameBothLists() {
        #expect(MenuBarIcon.badge(for: .passed, runs: .failed) == .failed)
        #expect(MenuBarIcon.badge(for: .failed, runs: .running) == .failed)
        #expect(MenuBarIcon.badge(for: .running, runs: .none) == .running)
        #expect(MenuBarIcon.badge(for: nil, runs: .running) == .running)
        #expect(MenuBarIcon.badge(for: .passed, runs: .none) == .none)
        #expect(MenuBarIcon.accessibilityLabel(checks: .running, runs: .failed) == "Runnir, a run failed, checks running")
        #expect(MenuBarIcon.accessibilityLabel(checks: .passed, runs: .none) == "Runnir")
    }

    @Test func aRowSaysWhatItIsAndWhatAClickDoes() {
        let workspace = UUID()
        let mine = WatchedRun(run: run(1, minutesAgo: 4), repository: CoreWatchedRepository(repository: ref("o/r"), workspaceIDs: [workspace]))
        #expect(WatchedRunText.title(mine.run) == "CI · Fix login")
        #expect(WatchedRunText.subtitle(mine, host: nil, now: now) == "o/r · main · failed 4 minutes ago")
        #expect(WatchedRunText.subtitle(mine, host: "ghe.test", now: now).hasPrefix("ghe.test · o/r"))
        #expect(WatchedRunText.action(mine) { $0 == workspace ? "runnir" : nil } == "Open in runnir")
        let starred = WatchedRun(run: run(2, status: "queued", conclusion: nil, minutesAgo: 1), repository: CoreWatchedRepository(repository: ref("o/s")))
        #expect(WatchedRunText.subtitle(starred, host: nil, now: now) == "o/s · main · queued 1 minute ago")
        #expect(WatchedRunText.action(starred) { _ in nil } == "Open on GitHub")
        let at = now.addingTimeInterval(-120 * 60)
        let timedOut = CoreWorkflowRun(id: 3, workflowID: 1, name: "Deploy", displayTitle: "Deploy", runNumber: 3, event: "push",
                                       status: "completed", conclusion: "timed_out", branch: "main", headSHA: "abc", actor: "ana",
                                       htmlURL: nil, createdAt: at, updatedAt: at)
        #expect(WatchedRunText.title(timedOut) == "Deploy", "the title alone when it is the workflow's name")
        #expect(WatchedRunText.subtitle(WatchedRun(run: timedOut, repository: starred.repository), host: nil, now: now) == "o/s · main · timed out 2 hours ago")
    }

    @Test func theNotesUnderTheList() {
        #expect(WatchedRunText.updated(count: 14) == " · 14 repositories" && WatchedRunText.updated(count: 1) == " · 1 repository")
        #expect(WatchedRunText.skipped(1) == "1 repository skipped: Runnir can't read its Actions.")
        #expect(WatchedRunText.skipped(2) == "2 repositories skipped: Runnir can't read their Actions.")
        #expect(WatchedRunText.budget(watched: 100, total: 130) == "Watching 100 of 130 repositories: workspaces first, then starred ones in the order you starred them.")
        #expect(WatchedRunText.scope(workspaces: 9, starred: 5) == "Your runs in 9 workspaces and 5 starred repositories.")
        #expect(WatchedRunText.scope(workspaces: 1, starred: 0) == "Your runs in 1 workspace.")
        #expect(WatchedRunText.scope(workspaces: 0, starred: 1) == "Your runs in 1 starred repository.")
        #expect(WatchedRunText.scope(workspaces: 0, starred: 0) == nil, "nothing read: no line")
        #expect(WatchedRunText.unanswered(readAt: nil) == "Runnir Core isn't answering, so your runs can't be read.")
        #expect(WatchedRunText.unanswered(readAt: now).hasSuffix("can't be read. These runs were read at \(now.formatted(date: .omitted, time: .shortened))."))
        #expect(WatchedRunText.paused(until: now, readAt: now).hasPrefix("Paused until "))
        #expect(WatchedRunText.paused(until: now, readAt: now).contains(" to keep the GitHub rate limit. These runs were read at "))
        #expect(WatchedRunText.offline(readAt: nil) == "GitHub can't be reached.")
        #expect(WatchedRunText.offline(readAt: now).hasPrefix("GitHub can't be reached. These runs were read at "))
    }
}
