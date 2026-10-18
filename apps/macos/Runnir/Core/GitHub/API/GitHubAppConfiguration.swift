import Foundation

/// The registered "Runnir Desktop" GitHub App. These values are public: the
/// app signs users in with the OAuth Device Flow using only the client ID and
/// never ships a client secret or private key.
struct GitHubAppConfiguration: Equatable, Sendable {
    let clientID: String
    let slug: String
    let webBaseURL: URL

    static let runnirDesktop = GitHubAppConfiguration(
        clientID: "Iv23liopD8rc8O16F7gK",
        slug: "runnir-desktop",
        webBaseURL: URL(string: "https://github.com")!
    )

    /// Where a user installs the app on their account or organization; user
    /// tokens only reach repositories where the app is installed.
    var installationURL: URL {
        webBaseURL.appendingPathComponent("apps").appendingPathComponent(slug).appendingPathComponent("installations/new")
    }

    /// Device Flow endpoints (https://docs.github.com/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-user-access-token-for-a-github-app#using-the-device-flow-to-generate-a-user-access-token).
    var deviceCodeURL: URL { webBaseURL.appendingPathComponent("login/device/code") }
    var accessTokenURL: URL { webBaseURL.appendingPathComponent("login/oauth/access_token") }
}
