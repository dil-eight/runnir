import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        NavigationSplitView {
            List(AppSection.allCases, selection: $appState.selectedSection) { section in
                Label(section.title, systemImage: section.symbolName)
                    .tag(section)
            }
            .navigationTitle("Runnir")
            .toolbar {
                ToolbarItem {
                    Button("Refresh", systemImage: "arrow.clockwise") {}
                        .keyboardShortcut("r", modifiers: [.command])
                }
            }
        } detail: {
            Group {
                switch appState.selectedSection {
                case .dashboard:
                    DashboardView()
                case .repositories:
                    RepositoriesView()
                case .workflows:
                    WorkflowsView()
                case .runs:
                    RunsView()
                case .artifacts:
                    ArtifactsView()
                case .workspace:
                    EmptyStateView(title: "Open a local repository", message: "Choose a repository in the Workspace Manager.", systemImage: "folder")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
