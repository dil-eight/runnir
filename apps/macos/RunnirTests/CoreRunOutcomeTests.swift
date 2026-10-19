import Testing
@testable import Runnir

struct CoreRunOutcomeTests {
    @Test
    func statusAndConclusionMapToOneOutcome() {
        let cases: [(String, String?, CoreRunOutcome)] = [
            ("completed", "success", .succeeded),
            ("completed", "failure", .failed),
            ("completed", "timed_out", .failed),
            ("completed", "startup_failure", .failed),
            ("completed", "cancelled", .cancelled),
            ("completed", "skipped", .skipped),
            ("completed", "neutral", .neutral),
            ("completed", "action_required", .neutral),
            ("in_progress", nil, .running),
            ("queued", nil, .queued),
            ("waiting", nil, .queued),
            ("pending", nil, .queued),
        ]
        for (status, conclusion, expected) in cases {
            #expect(CoreRunOutcome(status: status, conclusion: conclusion) == expected)
        }
        #expect(CoreRunOutcome.running.isActive && CoreRunOutcome.queued.isActive)
        #expect(!CoreRunOutcome.failed.isActive)
    }
}
