import SwiftUI

struct ArtifactsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HeaderView(title: "Artifacts", subtitle: "Prepare for build reuse and deployment provenance.")
            EmptyStateView(
                title: "No artifacts loaded",
                message: "Artifact discovery will validate repository, workflow run, attempt, expiration, and digest where available.",
                systemImage: "archivebox"
            )
        }
        .padding(RunnirTheme.contentPadding)
    }
}
