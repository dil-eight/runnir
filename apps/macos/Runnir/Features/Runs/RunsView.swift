import SwiftUI

struct RunsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HeaderView(title: "Runs", subtitle: "Monitor workflow runs and their status.")
            EmptyStateView(
                title: "Run monitoring is planned",
                message: "The initial foundation models runs and errors without pretending polling is complete.",
                systemImage: "play.circle"
            )
        }
        .padding(RunnirTheme.contentPadding)
    }
}
