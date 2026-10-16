import SwiftUI

struct WorkflowsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HeaderView(title: "Workflows", subtitle: "Inspect GitHub Actions workflow definitions.")
            EmptyStateView(
                title: "Select a repository",
                message: "Repository-specific workflow discovery is ready in the GitHub service layer.",
                systemImage: "point.3.connected.trianglepath.dotted"
            )
        }
        .padding(RunnirTheme.contentPadding)
    }
}
