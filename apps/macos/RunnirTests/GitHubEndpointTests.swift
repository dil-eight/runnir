import Foundation
import Testing
@testable import Runnir

struct GitHubEndpointTests {
    @Test
    func currentUserRequestUsesGitHubHeaders() throws {
        let request = try GitHubEndpoint.currentUser.request(
            baseURL: URL(string: "https://api.github.com")!,
            token: "token"
        )

        #expect(request.url?.path == "/user")
        #expect(request.url?.query == nil)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
    }
}
