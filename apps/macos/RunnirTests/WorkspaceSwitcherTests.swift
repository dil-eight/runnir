import Foundation
import Testing
@testable import Runnir

struct WorkspaceSwitcherTests {
    private func workspace(_ name: String, path: String, daysAgo: Double) -> WorkspaceRecord {
        WorkspaceRecord(id: UUID(), path: path, name: name, bookmark: Data(),
                        lastOpenedAt: Date(timeIntervalSince1970: 1_000_000 - daysAgo * 86_400))
    }

    private func items(_ workspaces: [WorkspaceRecord], query: String = "", current: UUID? = nil,
                       open: [UUID: Int] = [:], repositories: [UUID: String] = [:]) -> [String] {
        WorkspaceSwitcher.items(
            workspaces: workspaces, query: query, currentWorkspaceID: current,
            openWindows: { open[$0] ?? 0 },
            details: { (nil, repositories[$0]) }
        ).map(\.workspace.name)
    }

    @Test
    func withoutAQueryRecentComeFirstAndTheCurrentOneLast() {
        let old = workspace("old", path: "/Users/me/old", daysAgo: 30)
        let recent = workspace("recent", path: "/Users/me/recent", daysAgo: 1)
        let current = workspace("current", path: "/Users/me/current", daysAgo: 0)
        #expect(items([old, current, recent], current: current.id) == ["recent", "old", "current"])
    }

    @Test
    func everyTokenMustMatchAndNameMatchesRankFirst() {
        let runnir = workspace("runnir", path: "/Users/me/projects/runnir", daysAgo: 5)
        let landing = workspace("landing", path: "/Users/me/projects/runnir-landing", daysAgo: 1)
        let other = workspace("fintropy", path: "/Users/me/work/fintropy", daysAgo: 0)
        // "runnir" is in both paths; the workspace named runnir wins over the newer path match.
        #expect(items([runnir, landing, other], query: "runnir") == ["runnir", "landing"])
        #expect(items([runnir, landing, other], query: "proj land") == ["landing"])
        #expect(items([runnir, landing, other], query: "RUN") == ["runnir", "landing"])
        #expect(items([runnir, landing, other], query: "nothing-here").isEmpty)
    }

    @Test
    func theGitHubRepositoryIsSearchable() {
        let local = workspace("app", path: "/Users/me/app", daysAgo: 1)
        let other = workspace("site", path: "/Users/me/site", daysAgo: 0)
        #expect(items([local, other], query: "dil-eight", repositories: [local.id: "dil-eight/runnir"]) == ["app"])
    }

    @Test
    func itemsCarryWhereTheWorkspaceIsOpen() {
        let a = workspace("a", path: "/Users/me/a", daysAgo: 1)
        let result = WorkspaceSwitcher.items(workspaces: [a], query: "", currentWorkspaceID: nil,
                                             openWindows: { _ in 2 }, details: { _ in ("main", "o/a") })
        #expect(result.first?.openWindows == 2)
        #expect(result.first?.branch == "main")
        #expect(result.first?.isCurrent == false)
    }

    @Test
    func homePathsAreAbbreviated() {
        #expect(WorkspaceSwitcher.abbreviate("/Users/me/projects/runnir") == "~/projects/runnir")
        #expect(WorkspaceSwitcher.abbreviate("/Volumes/Disk/repo") == "/Volumes/Disk/repo")
        #expect(WorkspaceSwitcher.abbreviate("/Users/me") == "/Users/me")
    }

    @Test
    func actIsInstalledByAScriptThatWaitsForReturn() throws {
        #expect(ActInstaller.brew(isExecutable: { $0 == "/usr/local/bin/brew" }) == "/usr/local/bin/brew")
        #expect(ActInstaller.brew(isExecutable: { _ in true }) == "/opt/homebrew/bin/brew", "Apple silicon's Homebrew first")
        #expect(ActInstaller.brew(isExecutable: { _ in false }) == nil)
        let script = ActInstaller.script(brew: "/opt/homebrew/bin/brew")
        let read = try #require(script.range(of: "read \"?Press Return"))
        let install = try #require(script.range(of: "\"/opt/homebrew/bin/brew\" install act"))
        #expect(script.hasPrefix("#!/bin/zsh\n"))
        #expect(read.upperBound < install.lowerBound, "nothing runs before Return")
    }

    @Test
    func theSearchFindsActionsToo() {
        #expect(WorkspaceSwitcherAction.matching("") == [.importRepository, .manager])
        #expect(WorkspaceSwitcherAction.matching("import repo") == [.importRepository])
        #expect(WorkspaceSwitcherAction.matching("MANAGER") == [.manager])
        #expect(WorkspaceSwitcherAction.matching("runnir").isEmpty)
    }
}
