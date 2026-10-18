import SwiftUI

struct AppEnvironment: Sendable {
    let githubService: any GitHubService
    let credentialStore: any CredentialStoring
    let coreClient: CoreClient = .bundled

    static let live = AppEnvironment(
        githubService: GitHubRESTClient(
            baseURL: URL(string: "https://api.github.com")!,
            credentialStore: CachingCredentialStore.keychain
        ),
        credentialStore: CachingCredentialStore.keychain
    )
}

private struct AppEnvironmentKey: EnvironmentKey {
    static let defaultValue = AppEnvironment.live
}

extension EnvironmentValues {
    var appEnvironment: AppEnvironment {
        get { self[AppEnvironmentKey.self] }
        set { self[AppEnvironmentKey.self] = newValue }
    }
}
