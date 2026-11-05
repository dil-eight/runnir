import Foundation
import Testing
@testable import Runnir

@MainActor
@Suite struct AnalyticsHubTests {
    private func readyHub(_ state: CoreAnalytics? = nil) async -> (CoreHub, FakeProvider) {
        let provider = FakeProvider()
        if let state { provider.core.analyticsState = state }
        let hub = CoreHub(provider: provider)
        hub.startMonitoring()
        provider.ready()
        _ = await eventually { hub.analytics != nil }
        return (hub, provider)
    }

    @Test func theLedgerIsReadWhenTheCoreStarts() async {
        let (hub, provider) = await readyHub()
        #expect(hub.analytics == provider.core.analyticsState)
    }

    @Test func usageIsSentOnlyAtUsageAnalytics() async {
        let (hub, provider) = await readyHub()
        hub.recordUsage(.screenRunsList)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(provider.core.usage.isEmpty)
        #expect(await hub.setAnalyticsLevel(.full, fromPrompt: false))
        hub.recordUsage(.screenRunsList)
        #expect(await eventually { provider.core.usage == [.screenRunsList] })
    }

    @Test func changingTheLevelUpdatesTheHub() async {
        let (hub, provider) = await readyHub()
        #expect(await hub.setAnalyticsLevel(.full, fromPrompt: true))
        #expect(hub.analytics?.level == .full)
        #expect(hub.analytics?.promptAnswered == true)
        #expect(provider.core.levelCalls.map(\.fromPrompt) == [true])
    }

    @Test func usageEventsMatchTheContract() {
        let generated = Runnir_Core_V1_UsageEvent.allCases.filter { $0 != .unspecified }
        #expect(generated.count == UsageEvent.allCases.count)
        for event in UsageEvent.allCases {
            let wire = Runnir_Core_V1_UsageEvent(rawValue: event.rawValue)
            #expect(wire.map { String(describing: $0) } == String(describing: event), "\(event)")
        }
    }
}
