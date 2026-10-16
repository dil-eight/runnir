import SwiftUI

struct RepositoriesView: View {
    @Environment(\.appEnvironment) private var environment
    @State private var model = RepositoriesViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HeaderView(title: "Repositories", subtitle: "Browse repositories available to your GitHub account.")

            if model.isLoading {
                ProgressView("Loading repositories...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = model.errorMessage {
                EmptyStateView(title: "Could not load repositories", message: errorMessage, systemImage: "exclamationmark.triangle")
            } else if model.repositories.isEmpty {
                EmptyStateView(
                    title: "No repositories loaded",
                    message: "Authenticate with GitHub to fetch repositories.",
                    systemImage: "shippingbox"
                )
            } else {
                Table(model.repositories) {
                    TableColumn("Name") { repository in
                        VStack(alignment: .leading) {
                            Text(repository.name)
                                .font(.headline)
                            Text(repository.fullName)
                                .foregroundStyle(RunnirTheme.secondaryForeground)
                        }
                    }
                    TableColumn("Owner", value: \.owner)
                    TableColumn("Visibility", value: \.visibility.displayName)
                    TableColumn("Default Branch", value: \.defaultBranch)
                }
            }
        }
        .padding(RunnirTheme.contentPadding)
        .task {
            await model.load(using: environment.githubService)
        }
    }
}

@MainActor
@Observable
final class RepositoriesViewModel {
    var repositories: [Repository] = []
    var isLoading = false
    var errorMessage: String?

    func load(using githubService: any GitHubService) async {
        isLoading = true
        errorMessage = nil

        do {
            repositories = try await githubService.listRepositories()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}
