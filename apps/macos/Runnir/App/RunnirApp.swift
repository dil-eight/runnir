import SwiftUI

@main
struct RunnirApp: App {
    @NSApplicationDelegateAdaptor(DesktopAppDelegate.self) private var delegate

    /// The logo glyph, with a dot when a check or a run failed or runs,
    /// dimmed while no account is signed in.
    private var menuBarImage: NSImage {
        let signedIn = delegate.github.user != nil || !delegate.coreHub.signedInServers.isEmpty
        let badge = MenuBarIcon.badge(for: delegate.desktop.pullRequests.worstCI, runs: delegate.desktop.watchedRuns.badge)
        return MenuBarIcon.image(badge: badge, dimmed: !signedIn)
    }

    private var menuBarLabel: String {
        MenuBarIcon.accessibilityLabel(checks: delegate.desktop.pullRequests.worstCI, runs: delegate.desktop.watchedRuns.badge)
    }

    private var shortcutText: String? {
        if case .registered(let shortcut) = delegate.desktop.shortcuts.status { return shortcut.display }
        return nil
    }

    var body: some Scene {
        // Open pull requests and their CI, from the menu bar.
        MenuBarExtra {
            PullRequestsMenu(model: delegate.desktop.pullRequests, desktop: delegate.desktop,
                             shortcut: shortcutText)
                .environment(\.openRunnirSettings) { [desktop = delegate.desktop] section in
                    desktop.showSettingsInFrontWindow(section: section)
                }
                .handPointerButtons()
        } label: {
            Image(nsImage: menuBarImage).accessibilityLabel(menuBarLabel)
        }
        .menuBarExtraStyle(.window)
        .commands {
            // Settings open over the window in front, not in a window of their own.
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") { delegate.desktop.showSettingsInFrontWindow() }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Workspace...") { delegate.desktop.showManager() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Open Quickly...") { delegate.desktop.showSwitcher() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Link("Runnir on GitHub", destination: URL(string: "https://github.com/dil-eight/runnir")!)
            }
        }
    }
}
