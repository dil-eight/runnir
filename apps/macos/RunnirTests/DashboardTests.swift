import Foundation
import Testing
@testable import Runnir

@MainActor
struct WorkflowFavoritesTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    @Test func favoritesComeFirstAndSurviveARestart() throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let workspace = UUID(), other = UUID()
        let favorites = WorkflowFavorites(store: FileWorkflowFavoritesStore(directory: folder))
        #expect(favorites.toggle(".github/workflows/release.yml", workspaceID: workspace))
        #expect(favorites.toggle(".github/workflows/ci.yml", workspaceID: workspace))
        #expect(favorites.toggle(".github/workflows/ci.yml", workspaceID: other))

        let files = ["build.yml", "ci.yml", "lint.yml", "release.yml"].map { LocalWorkflowFile(relativePath: ".github/workflows/" + $0) }
        #expect(favorites.ordered(files, workspaceID: workspace, path: \.relativePath).map(\.name) == ["release.yml", "ci.yml", "build.yml", "lint.yml"])

        // A new library on the same file is what the next launch sees.
        let restarted = WorkflowFavorites(store: FileWorkflowFavoritesStore(directory: folder))
        #expect(restarted.paths(workspaceID: workspace) == [".github/workflows/release.yml", ".github/workflows/ci.yml"])
        #expect(restarted.isFavorite(".github/workflows/ci.yml", workspaceID: other))

        #expect(restarted.toggle(".github/workflows/release.yml", workspaceID: workspace))
        #expect(!restarted.isFavorite(".github/workflows/release.yml", workspaceID: workspace))
        restarted.removeAll(workspaceID: other)
        let again = WorkflowFavorites(store: FileWorkflowFavoritesStore(directory: folder))
        #expect(again.paths(workspaceID: workspace) == [".github/workflows/ci.yml"])
        #expect(again.paths(workspaceID: other).isEmpty)
    }

    @Test func aRenamedWorkflowKeepsItsStarInPlace() throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let workspace = UUID()
        let favorites = WorkflowFavorites(store: FileWorkflowFavoritesStore(directory: folder))
        for name in ["release.yml", "ci.yml", "build.yml"] { favorites.toggle(".github/workflows/" + name, workspaceID: workspace) }
        favorites.moveWorkflow(workspaceID: workspace, from: ".github/workflows/ci.yml", to: ".github/workflows/test.yml")
        #expect(favorites.paths(workspaceID: workspace) == [".github/workflows/release.yml", ".github/workflows/test.yml", ".github/workflows/build.yml"])
        // A star left on the new name by an earlier file goes, so the list stays unique.
        favorites.moveWorkflow(workspaceID: workspace, from: ".github/workflows/test.yml", to: ".github/workflows/build.yml")
        #expect(favorites.paths(workspaceID: workspace) == [".github/workflows/release.yml", ".github/workflows/build.yml"])
        favorites.moveWorkflow(workspaceID: workspace, from: ".github/workflows/none.yml", to: ".github/workflows/x.yml")
        let restarted = WorkflowFavorites(store: FileWorkflowFavoritesStore(directory: folder))
        #expect(restarted.paths(workspaceID: workspace) == [".github/workflows/release.yml", ".github/workflows/build.yml"])
    }

    @Test func anUnreadableFileTurnsFavoritesOffAndIsLeftAlone() throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FileWorkflowFavoritesStore(directory: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: store.fileURL)
        let favorites = WorkflowFavorites(store: store)
        #expect(!favorites.isAvailable)
        #expect(!favorites.toggle(".github/workflows/ci.yml", workspaceID: UUID()))
        #expect(favorites.problem != nil)
        #expect(try String(contentsOf: store.fileURL, encoding: .utf8) == "{not json")
    }

    @Test func workflowsGitHubAddsItselfCannotBeFavorites() throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let favorites = WorkflowFavorites(store: FileWorkflowFavoritesStore(directory: folder))
        #expect(!WorkflowFavorites.canFavorite("dynamic/github-code-scanning/codeql"))
        #expect(!favorites.toggle("dynamic/github-code-scanning/codeql", workspaceID: UUID()))
        #expect(favorites.problem == "Only workflow files in .github/workflows can be favorites.")
        #expect(favorites.isAvailable)
    }

    @Test func onlyWorkflowPathsAreStored() {
        #expect(!FavoriteWorkflows(workspaceID: UUID(), paths: ["README.md"]).isValid)
        #expect(!FavoriteWorkflows(workspaceID: UUID(), paths: [".github/workflows/a.yml", ".github/workflows/a.yml"]).isValid)
        #expect(FavoriteWorkflows(workspaceID: UUID(), paths: [".github/workflows/a.yml"]).isValid)
    }
}

struct PipelineLayoutTests {
    private func job(_ id: String, needs: [String] = [], name: String? = nil) -> CoreJob {
        CoreJob(id: id, name: name ?? id, needs: needs)
    }

    private func runJob(_ name: String, status: String = "completed", conclusion: String? = "success",
                        start: TimeInterval? = 0, end: TimeInterval? = 10, node: String = "") -> CoreRunJob {
        CoreRunJob(id: Int64(name.hashValue & 0xffff), name: name, status: status, conclusion: conclusion,
                   startedAt: start.map { Date(timeIntervalSince1970: $0) }, completedAt: end.map { Date(timeIntervalSince1970: $0) },
                   htmlURL: nil, steps: [], workflowJobID: node)
    }

    @Test func hoveringAJobSaysItsStatus() {
        let deploy = job("deploy-production", needs: ["build"], name: "Deploy to production")
        let now = Date(timeIntervalSince1970: 100)
        #expect(PipelineLayout.hint(for: deploy, matched: [runJob("Deploy to production", conclusion: "skipped")], readFailed: false, now: now)
                == "Skipped in the latest run: its condition was not met, or a job it needs did not succeed\nNeeds build")
        #expect(PipelineLayout.hint(for: job("test"), matched: [runJob("test", start: 0, end: 261)], readFailed: false, now: now)
                == "Succeeded · 4m 21s")
        #expect(PipelineLayout.hint(for: job("test"), matched: [], readFailed: true, now: now)
                == "Status unknown: the latest run's jobs could not be read from GitHub")
        #expect(PipelineLayout.hint(for: job("test"), matched: [], readFailed: false, now: now) == "Not in the latest run")
    }

    @Test func columnsFollowNeeds() {
        let columns = PipelineLayout.columns([
            job("lint"), job("unit-tests"), job("build", needs: ["lint", "unit-tests"]),
            job("archive", needs: ["build"]), job("deploy", needs: ["archive", "lint"]),
        ])
        #expect(columns.map { $0.map(\.id) } == [["lint", "unit-tests"], ["build"], ["archive"], ["deploy"]])
    }

    @Test func unknownNeedsAndCyclesDoNotBreakTheLayout() {
        #expect(PipelineLayout.columns([job("a", needs: ["missing"])]).map { $0.map(\.id) } == [["a"]])
        let cycle = PipelineLayout.columns([job("a", needs: ["b"]), job("b", needs: ["a"])])
        #expect(cycle.flatMap { $0 }.count == 2)
        #expect(PipelineLayout.columns([]).isEmpty)
    }

    @Test func runJobsAreTheOnesTheCoreNamesForTheJob() {
        // The Core matches names (flow.RunJobNodes); the app only reads its answer.
        let jobs = [runJob("Build ubuntu-latest", node: "build"), runJob("Build macos-latest", node: "build"),
                    runJob("release / publish", node: "release"), runJob("Lint")]
        #expect(PipelineLayout.runJobs(for: job("build", name: "Build ${{ matrix.os }}"), in: jobs).count == 2)
        #expect(PipelineLayout.runJobs(for: job("release"), in: jobs).map(\.name) == ["release / publish"])
        #expect(PipelineLayout.runJobs(for: job("lint", name: "Lint"), in: jobs).isEmpty, "a run job the Core named for no job")
    }

    @Test func theWorstOutcomeAndTheWholeDurationWin() {
        let mixed = [runJob("b (1)"), runJob("b (2)", conclusion: "failure"), runJob("b (3)", status: "in_progress", conclusion: nil, start: 5, end: nil)]
        #expect(PipelineLayout.outcome(mixed) == .failed)
        #expect(PipelineLayout.outcome([runJob("x"), runJob("y", status: "in_progress", conclusion: nil)]) == .running)
        #expect(PipelineLayout.outcome([]) == nil)
        #expect(PipelineLayout.duration(mixed, now: Date(timeIntervalSince1970: 60)) == 60)
        #expect(PipelineLayout.duration([runJob("x", start: nil, end: nil)], now: Date()) == nil)
        #expect(PipelineLayout.format(41) == "41s")
        #expect(PipelineLayout.format(192) == "3m 12s")
        #expect(PipelineLayout.format(3720) == "1h 2m")
    }
}

struct SavingTextTests {
    @Test func minutesReadAsHoursOnceThereAreSixty() {
        #expect(SavingText.amount(minutes: 0) == "0 min")
        #expect(SavingText.amount(minutes: 42) == "42 min")
        #expect(SavingText.amount(minutes: 120) == "2 h")
        #expect(SavingText.amount(minutes: 192) == "3 h 12 min")
    }

    @Test func localRunsSayWhatWasCounted() {
        let one = CoreSaving(kind: .localRuns, minutes: 3, count: 1, since: nil)
        #expect(SavingText.title(one) == "Local runs")
        #expect(SavingText.detail(one) == "GitHub Actions minutes · 1 run")
        #expect(SavingText.detail(CoreSaving(kind: .localRuns, minutes: 9, count: 4, since: nil)) == "GitHub Actions minutes · 4 runs")
        #expect(SavingText.help(one).contains("rounded up to a whole minute") && !SavingText.help(one).contains("Counted since"))
        #expect(SavingText.help(CoreSaving(kind: .localRuns, minutes: 3, count: 1, since: Date())).contains("Counted since"))
    }
}
