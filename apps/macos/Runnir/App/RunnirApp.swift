import SwiftUI

@main
struct RunnirApp: App {
    @NSApplicationDelegateAdaptor(DesktopAppDelegate.self) private var delegate

    private var menuBarSymbol: String {
        switch delegate.desktop.pullRequests.worstCI {
        case .failed: "exclamationmark.triangle"
        case .running: "arrow.triangle.2.circlepath"
        default: "arrow.triangle.pull"
        }
    }

    private var shortcutText: String? {
        if case .registered(let shortcut) = delegate.desktop.shortcuts.status { return shortcut.display }
        return nil
    }

    var body: some Scene {
        Settings {
            SettingsView(github: delegate.github, core: delegate.desktop.core, shortcuts: delegate.desktop.shortcuts)
                .environment(delegate.desktop.accountState)
        }
        // Open pull requests and their CI, from the menu bar.
        MenuBarExtra {
            PullRequestsMenu(model: delegate.desktop.pullRequests, desktop: delegate.desktop,
                             shortcut: shortcutText)
        } label: {
            Image(systemName: menuBarSymbol).accessibilityLabel("Runnir pull requests")
        }
        .menuBarExtraStyle(.window)
        .commands {
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
