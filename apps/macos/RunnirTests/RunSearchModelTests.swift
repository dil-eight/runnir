import Foundation
import Testing
@testable import Runnir

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RunSearchModelTests {
    private func run(_ id: Int64, minute: Int = 0) -> CoreWorkflowRun {
        CoreWorkflowRun(id: id, workflowID: 3, name: "CI", displayTitle: "Deploy \(id)", runNumber: id, event: "push", status: "completed",
                        conclusion: "success", branch: "main", headSHA: "abc", actor: "eugene", htmlURL: nil,
                        createdAt: Date(timeIntervalSince1970: 1_000_000 - Double(minute) * 60), updatedAt: nil)
    }

    private func rig() async -> (RunSearchModel, FakeProvider, UUID) {
        let provider = FakeProvider()
        let hub = CoreHub(provider: provider)
        hub.startMonitoring()
        provider.ready()
        let workspace = UUID()
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/linked")
        _ = await eventually { hub.session(for: workspace)?.coreID != nil }
        let model = RunSearchModel(hub: hub, workspaceID: workspace)
        model.debounce = .milliseconds(5)
        return (model, provider, workspace)
    }

    @Test func aQueryIsSearchedAfterTheTypingPausesAndABlankOneEndsIt() async {
        let (model, provider, _) = await rig()
        provider.core.runSearchResult = CoreRunSearch(cachedRunIDs: [3, 1], indexedRuns: [run(9)], cachedSearched: 100, indexedSearched: 400)
        #expect(model.matchingIDs == nil)
        model.update(query: "  deploy ")
        #expect(await eventually { model.matchingIDs == [3, 1] })
        #expect(provider.core.searchQueries == ["deploy"], "the Core gets the trimmed query")
        #expect(model.indexedRuns.map(\.id) == [9])
        model.update(query: "   ")
        #expect(model.matchingIDs == nil && model.saved == nil && model.deep == .idle)
    }

    @Test func aDeepSearchReadsStepsFromTheCursorAndKeepsTheMatches() async {
        let (model, provider, _) = await rig()
        provider.core.runSearchResult = CoreRunSearch(cachedRunIDs: [3], cachedSearched: 100)
        let cursor = Date(timeIntervalSince1970: 900_000)
        provider.core.githubSearchSteps = [
            CoreGitHubRunSearch(access: .ok, runs: [run(2, minute: 10), run(1, minute: 20)], nextCursor: cursor,
                                lookedBackTo: cursor, pages: 10, runsRead: 1000, stop: .budget),
            CoreGitHubRunSearch(access: .ok, runs: [run(1, minute: 20), run(0, minute: 30)], lookedBackTo: cursor.addingTimeInterval(-3_600),
                                pages: 2, runsRead: 150, stop: .done),
        ]
        model.update(query: "deploy")
        #expect(await eventually { model.matchingIDs != nil })
        model.searchGitHub()
        #expect(model.deep == .running)
        #expect(await eventually { model.deep == .more })
        #expect(model.githubRuns.map(\.id) == [2, 1])
        #expect(model.runsRead == 1000 && model.lookedBackTo == cursor)
        model.searchDeeper()
        #expect(await eventually { model.deep == .done })
        #expect(provider.core.githubSearchCursors == [nil, cursor], "the second step starts where the first ended")
        #expect(model.githubRuns.map(\.id) == [2, 1, 0], "a run read twice is kept once")
        // Runs the saved list or the index already show are not listed again.
        #expect(model.foundOnGitHub(excluding: [2]).map(\.id) == [1, 0])
    }

    @Test func aStoppedStepSaysWhy() async {
        let (model, provider, _) = await rig()
        provider.core.runSearchResult = CoreRunSearch()
        model.update(query: "x")
        #expect(await eventually { model.saved != nil })
        let reset = Date(timeIntervalSince1970: 2_000_000)
        provider.core.githubSearchSteps = [CoreGitHubRunSearch(access: .rateLimited(until: reset), stop: .rateLimited)]
        model.searchGitHub()
        #expect(await eventually { model.deep == .rateLimited(reset) })
        provider.core.githubSearchSteps = []
        model.searchGitHub()
        #expect(await eventually { model.deep == .failed(.unavailable) })
    }

    @Test func aSyncWhileTypingKeepsTheSearchForTheNewText() async {
        let (model, provider, _) = await rig()
        model.debounce = .milliseconds(50)
        provider.core.runSearchResult = CoreRunSearch(cachedRunIDs: [1])
        model.update(query: "deploy")
        #expect(await eventually { model.query == "deploy" })
        model.update(query: "deploy prod")
        // A sync lands during the pause before the new text is searched.
        model.refresh()
        #expect(await eventually { model.query == "deploy prod" })
        #expect(provider.core.searchQueries.last == "deploy prod")
    }

    @Test func aTextClearedBeforeItsSearchRanIsNotSearched() async throws {
        let (model, provider, _) = await rig()
        model.debounce = .milliseconds(50)
        model.update(query: "a")
        model.update(query: "")
        try await Task.sleep(for: .milliseconds(200))
        #expect(!provider.core.searchQueries.contains("a"))
        #expect(model.query.isEmpty && model.saved == nil)
    }

    @Test func aSearchTheCoreDoesNotAnswerNarrowsNothing() async {
        let (model, provider, _) = await rig()
        provider.core.runSearchFails = true
        model.update(query: "deploy")
        #expect(await eventually { model.unavailable })
        #expect(model.matchingIDs == nil, "the list stays as it is instead of saying nothing matches")
        provider.core.runSearchFails = false
        provider.core.runSearchResult = CoreRunSearch(cachedRunIDs: [2])
        model.update(query: "deploy!")
        #expect(await eventually { model.matchingIDs == [2] })
        #expect(!model.unavailable)
    }

    @Test func anotherQueryEndsTheDeepSearchOfTheOldOne() async {
        let (model, provider, _) = await rig()
        provider.core.runSearchResult = CoreRunSearch(cachedRunIDs: [1])
        provider.core.githubSearchSteps = [CoreGitHubRunSearch(access: .ok, runs: [run(7)], lookedBackTo: Date(), pages: 1, runsRead: 100, stop: .done)]
        model.update(query: "deploy")
        #expect(await eventually { model.saved != nil })
        model.searchGitHub()
        #expect(await eventually { model.deep == .done })
        model.update(query: "build")
        #expect(await eventually { model.query == "build" })
        #expect(model.deep == .idle && model.githubRuns.isEmpty)
    }
}
