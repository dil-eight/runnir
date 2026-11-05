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

@MainActor
@Suite struct AnalyticsPromptTests {
    private func coordinator(_ state: CoreAnalytics? = nil) async -> (DesktopCoordinator, FakeProvider) {
        let provider = FakeProvider()
        if let state { provider.core.analyticsState = state }
        let hub = CoreHub(provider: provider)
        hub.startMonitoring()
        provider.ready()
        _ = await eventually { hub.analytics != nil }
        return (DesktopCoordinator(core: hub), provider)
    }

    @Test func theQuestionGoesToTheFirstWindowOnly() async {
        let (desktop, _) = await coordinator()
        let first = UUID(), second = UUID()
        desktop.offerAnalyticsPrompt(windowID: first)
        desktop.offerAnalyticsPrompt(windowID: second)
        #expect(desktop.analyticsPromptWindowID == first)
        desktop.releaseAnalyticsPrompt(windowID: first)
        desktop.offerAnalyticsPrompt(windowID: second)
        #expect(desktop.analyticsPromptWindowID == second)
    }

    @Test func anAnswerSetsTheLevelAndHidesTheQuestion() async {
        let (desktop, provider) = await coordinator()
        let window = UUID()
        desktop.offerAnalyticsPrompt(windowID: window)
        await desktop.answerAnalyticsPrompt(.basic)
        #expect(desktop.analyticsPromptWindowID == nil)
        #expect(provider.core.levelCalls.first.map { $0.level == .basic && $0.fromPrompt } == true)
        desktop.offerAnalyticsPrompt(windowID: window)
        #expect(desktop.analyticsPromptWindowID == nil, "answered: never asked again")
    }

    @Test func noQuestionWithoutALedgerOnDisk() async {
        let (desktop, _) = await coordinator(CoreAnalytics(level: .basic, promptAnswered: false, sendingAvailable: false,
                                                           persistent: false, analyticsID: nil, sealed: [], today: []))
        desktop.offerAnalyticsPrompt(windowID: UUID())
        #expect(desktop.analyticsPromptWindowID == nil)
    }
}

@MainActor
@Suite struct UsageCounterTests {
    private func fullDesktop() async -> (DesktopCoordinator, FakeProvider) {
        let provider = FakeProvider()
        provider.core.analyticsState = CoreAnalytics(level: .full, promptAnswered: true, sendingAvailable: true, persistent: true,
                                                     analyticsID: "id", sealed: [], today: [])
        let hub = CoreHub(provider: provider)
        hub.startMonitoring()
        provider.ready()
        _ = await eventually { hub.analytics?.level == .full }
        return (DesktopCoordinator(core: hub), provider)
    }

    @Test func openingOrSwitchingSettingsCountsTheSection() async {
        let (desktop, provider) = await fullDesktop()
        let window = UUID()
        desktop.showSettings(in: window, section: .storage)
        desktop.showSettingsSection(.storage) // same section: not again
        desktop.showSettingsSection(.privacy)
        // Each count is its own task, so their order is not fixed.
        #expect(await eventually { provider.core.usage.count == 2 })
        #expect(Set(provider.core.usage) == [.overlaySettingsStorage, .overlaySettingsPrivacy])
    }

    @Test func gitHubLinksAndTheIssuePageAreCounted() async {
        let (desktop, provider) = await fullDesktop()
        desktop.noteOpened(URL(string: "https://github.com/o/r/actions/runs/1")!)
        desktop.noteOpened(BugReportDraft.newIssue)
        desktop.noteOpened(URL(string: "https://github.com/settings/tokens")!)
        desktop.noteOpened(URL(string: "https://docs.docker.com/desktop/")!)
        desktop.noteOpened(URL(fileURLWithPath: "/tmp/log.txt"))
        #expect(await eventually { provider.core.usage.count == 2 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(provider.core.usage.count == 2 && Set(provider.core.usage) == [.actionGithubOpenOnGithub, .actionAppReportBug])
    }

    @Test func everySidebarSectionAndSettingsSectionHasAnEvent() {
        for tab in [WorkspaceTab.editor, .localRun] {
            #expect(AppSection.sidebarSections.allSatisfy { $0.usageEvent(workspaceTab: tab) != nil })
        }
        #expect(AppSection.workspace.usageEvent(workspaceTab: .localRun) == .screenLocalRunHistory)
        #expect(Set(SettingsSection.allCases.map(\.usageEvent)).count == SettingsSection.allCases.count)
    }
}
