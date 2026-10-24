import Foundation
import Testing
@testable import Runnir

@Suite struct RunLinkMappingTests {
    @Test func activityCarriesLinksChangesAndHints() throws {
        let message = Runnir_Core_V1_WorkspaceActivity.with {
            $0.runs = [
                .with {
                    $0.id = 4; $0.name = "CI"; $0.headSha = "m1"; $0.headRepository = "o/r"; $0.commitTitle = "Merge #142"
                    $0.link = .with { $0.kind = .afterMerge; $0.pullRequest = 142 }
                },
                .with { $0.id = 1; $0.name = "CI"; $0.supersededBy = 3; $0.link = .with { $0.kind = .pullRequest; $0.pullRequest = 142 } },
                .with { $0.id = 9; $0.name = "Nightly" },
            ]
            $0.changes = [.with {
                $0.id = "pr:142"
                $0.status = .passed
                $0.pullRequest = .with { $0.number = 142; $0.title = "Add retry"; $0.state = "merged"; $0.htmlURL = "https://github.com/o/r/pull/142" }
                $0.sections = [.with { $0.kind = .afterMerge; $0.headSha = "m1"; $0.branch = "main"; $0.runIds = [4] }]
                $0.olderRunIds = [1]
                $0.olderCommits = 1
            }]
            $0.concurrencyHints = [.with { $0.workflowID = 3; $0.path = ".github/workflows/ci.yml"; $0.runs = 2; $0.overlapMinutes = 15; $0.runIds = [1, 2] }]
            $0.cachedRuns = 250
            $0.historyComplete = true
            $0.freshness = .with { $0.source = .live; $0.pullRequestsAccess = .permissionMissing }
        }
        let activity = GRPCCoreService.map(message)
        #expect(activity.runs[0].link == .afterMerge(142) && activity.runs[0].headRepository == "o/r" && activity.runs[0].commitTitle == "Merge #142")
        #expect(activity.runs[1].supersededBy == 3 && activity.runs[1].isSuperseded && activity.runs[1].link.pullRequest == 142)
        #expect(activity.runs[2].link == .none && activity.runs[2].supersededBy == nil)
        let change = try #require(activity.changes.first)
        #expect(change.id == "pr:142" && change.status == .passed && change.pullRequest?.state == "merged")
        #expect(change.pullRequest?.htmlURL?.absoluteString == "https://github.com/o/r/pull/142")
        #expect(change.sections == [CoreRunChangeSection(kind: .afterMerge, headSHA: "m1", branch: "main", commitTitle: "", runIDs: [4], repeatRunIDs: [])])
        #expect(change.olderRunIDs == [1] && change.olderCommits == 1)
        #expect(activity.concurrencyHints == [CoreConcurrencyHint(workflowID: 3, path: ".github/workflows/ci.yml", runs: 2, overlapMinutes: 15, runIDs: [1, 2], pullRequests: [])])
        #expect(activity.cachedRuns == 250 && activity.historyComplete)
        #expect(activity.freshness.pullRequestsAccess == .permissionMissing)
    }

    @Test func insertionAnswersMapToEditsOrReasons() {
        let inserted = GRPCCoreService.map(Runnir_Core_V1_InsertWorkflowConcurrencyResponse.with {
            $0.refusal = .none; $0.content = "x"; $0.firstLine = 3; $0.lastLine = 6
        })
        #expect(inserted == .inserted(content: "x", firstLine: 3, lastLine: 6))
        #expect(GRPCCoreService.map(Runnir_Core_V1_InsertWorkflowConcurrencyResponse.with { $0.refusal = .alreadyPresent }) == .refused(.alreadyPresent))
    }
}
