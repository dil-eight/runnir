import SwiftUI

@main
struct RunnirApp: App {
    @NSApplicationDelegateAdaptor(DesktopAppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsView(github: delegate.github)
                .environment(delegate.desktop.accountState)
                .environment(\.appEnvironment, AppEnvironment.live)
        }
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
