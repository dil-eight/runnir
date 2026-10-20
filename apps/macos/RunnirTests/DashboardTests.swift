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
                        start: TimeInterval? = 0, end: TimeInterval? = 10) -> CoreRunJob {
        CoreRunJob(id: Int64(name.hashValue & 0xffff), name: name, status: status, conclusion: conclusion,
                   startedAt: start.map { Date(timeIntervalSince1970: $0) }, completedAt: end.map { Date(timeIntervalSince1970: $0) },
                   htmlURL: nil, steps: [])
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

    @Test func runJobsMatchExpressionNamesAndReusableWorkflows() {
        let jobs = [runJob("Build ubuntu-latest"), runJob("Build macos-latest"), runJob("release / publish"), runJob("Lint")]
        #expect(PipelineLayout.runJobs(for: job("build", name: "Build ${{ matrix.os }}"), in: jobs).count == 2)
        #expect(PipelineLayout.runJobs(for: job("release"), in: jobs).map(\.name) == ["release / publish"])
        #expect(PipelineLayout.runJobs(for: job("x", name: "${{ matrix.name }}"), in: jobs).isEmpty)
        // A run job another job names is not taken by an expression's stem.
        let docs = job("docs", name: "Build docs")
        let all = jobs + [runJob("Build docs")]
        #expect(PipelineLayout.runJobs(for: job("build", name: "Build ${{ matrix.os }}"), in: all, among: [job("build", name: "Build ${{ matrix.os }}"), docs]).count == 2)
    }

    @Test func runJobsMatchByNameIdAndMatrix() {
        let jobs = [runJob("Lint"), runJob("build (ubuntu, 18)"), runJob("build (macos, 18)"), runJob("deploy")]
        #expect(PipelineLayout.runJobs(for: job("lint", name: "Lint"), in: jobs).map(\.name) == ["Lint"])
        #expect(PipelineLayout.runJobs(for: job("build"), in: jobs).count == 2)
        #expect(PipelineLayout.runJobs(for: job("deploy", name: "Deploy app"), in: jobs).map(\.name) == ["deploy"])
        #expect(PipelineLayout.runJobs(for: job("buil"), in: jobs).isEmpty)
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
