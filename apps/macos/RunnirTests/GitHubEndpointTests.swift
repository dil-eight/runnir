import Foundation
import Testing
@testable import Runnir

struct GitHubEndpointTests {
    @Test
    func repositoriesRequestUsesGitHubHeadersAndPagination() throws {
        let request = try GitHubEndpoint.repositories(page: 3).request(
            baseURL: URL(string: "https://api.github.com")!,
            token: "token"
        )

        #expect(request.url?.path == "/user/repos")
        #expect(request.url?.query?.contains("page=3") == true)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
    }
}
