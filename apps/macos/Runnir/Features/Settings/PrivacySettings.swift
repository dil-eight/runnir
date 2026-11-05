import AppKit
import SwiftUI

extension CoreAnalyticsLevel {
    var title: String {
        switch self {
        case .off: "Off"
        case .basic: "Basic counts"
        case .full: "Usage analytics"
        }
    }

    var detail: String {
        switch self {
        case .off: "Nothing is counted or sent."
        case .basic: "That Runnir was installed, and how many minutes local runs and cancelled runs saved. No id."
        case .full: "Basic counts, plus which screens, panels and actions you use and how runs and syncs turn out, with a random id not linked to you, your Mac or GitHub."
        }
    }
}

/// What Runnir never sends, said by the question and by Settings › Privacy.
private let neverSent = "Runnir never sends code, repository, workflow or branch names, paths, logs or anything you type."

/// The analytics question (O10): once, in the first workspace window, above
/// the content, without blocking work. Neither answer is the default.
struct AnalyticsConsentBanner: View {
    let desktop: DesktopCoordinator
    @State private var answering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.raised").font(.system(size: 14)).foregroundStyle(RunnirTheme.primary)
            VStack(alignment: .leading, spacing: 6) {
                Text("Help improve Runnir").font(.system(size: 13, weight: .semibold))
                Text("Runnir sends a few anonymous counts: that it was installed, and how many minutes local runs and cancelled runs saved. They carry no id.")
                Text("With your permission, Runnir also counts which screens, panels and actions you use and how runs and syncs turn out, with a random id that is not linked to you, your Mac or GitHub. This shows how many people use each feature.")
                Text("\(neverSent) Data is stored by PostHog in the United States. You can change this or turn everything off in Settings › Privacy.")
                    .foregroundStyle(RunnirTheme.secondaryForeground)
                HStack(spacing: 8) {
                    Button("Basic Counts Only") { answer(.basic) }
                    Button("Share Usage Analytics") { answer(.full) }
                }
                .buttonStyle(DesignButtonStyle())
                .disabled(answering)
                .padding(.top, 6)
            }
            .font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(RunnirTheme.surface)
        .overlay(alignment: .bottom) { DesignDivider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("analytics-question")
    }

    private func answer(_ level: CoreAnalyticsLevel) {
        answering = true
        Task {
            await desktop.answerAnalyticsPrompt(level)
            answering = false
        }
    }
}

/// Settings › Privacy (S12): the analytics level, the analytics id and what
/// waits to be sent, read from the Core's ledger.
struct PrivacySettingsSection: View {
    let hub: CoreHub?
    @State private var showingSent = false

    var body: some View {
        Section("Analytics") {
            if let analytics = hub?.analytics {
                ForEach(CoreAnalyticsLevel.allCases, id: \.self) { level in levelRow(level, current: analytics.level) }
                    .disabled(!analytics.persistent)
                if !analytics.persistent {
                    note("Another copy of Runnir that is running keeps the analytics settings.")
                } else if !analytics.sendingAvailable {
                    note("Sending is off in this build: \(Self.appName) counts, but only builds from a tag send.")
                }
                if let id = analytics.analyticsID { analyticsID(id) }
                whatIsSent(analytics)
            } else {
                Text("Runnir Core is not running.").foregroundStyle(RunnirTheme.secondaryForeground)
            }
            Text("\(neverSent) Counts leave once a day and carry no time finer than the day. Data is stored by PostHog in the United States.")
                .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
        }
        .task { await hub?.loadAnalytics() }
    }

    private static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Runnir"
    }

    private func levelRow(_ level: CoreAnalyticsLevel, current: CoreAnalyticsLevel) -> some View {
        let selected = level == current
        return Button {
            Task { await hub?.setAnalyticsLevel(level, fromPrompt: false) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? RunnirTheme.primary : RunnirTheme.secondaryForeground)
                VStack(alignment: .leading, spacing: 2) {
                    Text(level.title)
                    Text(level.detail).font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.hit)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("analytics-level-\(level)")
    }

    private func note(_ text: String) -> some View {
        Label(text, systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
    }

    private func analyticsID(_ id: String) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Analytics ID")
                Text(id).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                Text("Random, made when you chose usage analytics. Give it with a request to delete your data.")
                    .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
            }
            Spacer()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(id, forType: .string)
            }
        }
    }

    @ViewBuilder private func whatIsSent(_ analytics: CoreAnalytics) -> some View {
        let waiting = analytics.sealed.count + analytics.today.count
        Button { showingSent.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: showingSent ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold)).frame(width: 12)
                    .foregroundStyle(RunnirTheme.secondaryForeground)
                Text("What is sent")
                Spacer()
                if !showingSent {
                    Text(waiting == 1 ? "1 count waiting" : "\(waiting) counts waiting")
                        .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.hit)
        .accessibilityValue(showingSent ? "Expanded" : "Collapsed")
        if showingSent {
            if waiting == 0 {
                Text("Nothing is waiting to be sent.").font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    counters("Sealed, waiting to be sent", analytics.sealed)
                    counters("Counted today, sent from tomorrow", analytics.today)
                }
                .padding(.leading, 18)
            }
        }
    }

    @ViewBuilder private func counters(_ title: String, _ counters: [CoreAnalyticsCounter]) -> some View {
        if !counters.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(RunnirTheme.secondaryForeground)
                ForEach(counters, id: \.name) { counter in
                    HStack {
                        Text(counter.name)
                        Spacer()
                        Text("\(counter.value)")
                    }
                    .font(.system(size: 12, design: .monospaced))
                }
            }
        }
    }
}

// MARK: Counting usage

extension EnvironmentValues {
    /// Counts a usage event; dropped below the Usage analytics level. Set by
    /// `usageAnalytics(desktop:)`; unset outside Runnir's windows.
    @Entry var recordUsage: (@MainActor (UsageEvent) -> Void)? = nil
}

extension View {
    /// Lets views inside count usage, and counts the links they open on
    /// GitHub.
    func usageAnalytics(desktop: DesktopCoordinator) -> some View {
        environment(\.recordUsage) { desktop.core?.recordUsage($0) }
            .environment(\.openURL, OpenURLAction { url in
                // SwiftUI opens links on the main thread.
                MainActor.assumeIsolated { desktop.noteOpened(url) }
                return .systemAction
            })
    }

    /// Counts an overlay, a sheet or a panel each time it appears.
    func countsUsage(_ event: UsageEvent) -> some View { modifier(UsageOnAppear(event: event)) }
}

private struct UsageOnAppear: ViewModifier {
    let event: UsageEvent
    @Environment(\.recordUsage) private var recordUsage

    func body(content: Content) -> some View { content.onAppear { recordUsage?(event) } }
}

extension AppSection {
    /// The screen a click on this sidebar section shows; the Workspace one
    /// depends on its tab.
    func usageEvent(workspaceTab: WorkspaceTab) -> UsageEvent? {
        switch self {
        case .dashboard: .screenOverviewPage
        case .workflows: .screenWorkflowsList
        case .runs: .screenRunsList
        case .secrets: .screenSecretsValues
        case .workspace: workspaceTab.usageEvent
        case .repositories, .artifacts: nil
        }
    }
}

extension WorkspaceTab {
    var usageEvent: UsageEvent {
        switch self {
        case .editor: .screenEditorWorkflow
        case .localRun: .screenLocalRunHistory
        }
    }
}

extension SettingsSection {
    var usageEvent: UsageEvent {
        switch self {
        case .account: .overlaySettingsAccount
        case .runs: .overlaySettingsRuns
        case .notifications: .overlaySettingsNotifications
        case .pullRequests: .overlaySettingsPullRequests
        case .tools: .overlaySettingsTools
        case .storage: .overlaySettingsStorage
        case .privacy: .overlaySettingsPrivacy
        }
    }
}
