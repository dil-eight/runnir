import SwiftUI

@main
struct RunnirApp: App {
    @NSApplicationDelegateAdaptor(DesktopAppDelegate.self) private var delegate

    /// The logo glyph, with a dot when a check failed or runs, dimmed
    /// while no account is signed in.
    private var menuBarImage: NSImage {
        let signedIn = delegate.github.user != nil || !delegate.coreHub.signedInServers.isEmpty
        return MenuBarIcon.image(badge: MenuBarIcon.badge(for: delegate.desktop.pullRequests.worstCI), dimmed: !signedIn)
    }

    private var menuBarLabel: String {
        switch delegate.desktop.pullRequests.worstCI {
        case .failed: "Runnir pull requests, a check failed"
        case .running: "Runnir pull requests, checks running"
        default: "Runnir pull requests"
        }
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
