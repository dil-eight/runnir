import Foundation
import Testing
@testable import Runnir

struct GitHubAppConfigurationTests {
    @Test
    func runnirDesktopAppIsConfiguredWithoutSecrets() {
        let app = GitHubAppConfiguration.runnirDesktop
        #expect(app.clientID.hasPrefix("Iv"))
        #expect(app.installationURL.absoluteString == "https://github.com/apps/runnir-desktop/installations/new")
        #expect(app.deviceCodeURL.absoluteString == "https://github.com/login/device/code")
        #expect(app.accessTokenURL.absoluteString == "https://github.com/login/oauth/access_token")
    }
}
