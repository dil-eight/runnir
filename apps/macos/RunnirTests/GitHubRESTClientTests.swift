import Foundation
import Testing
@testable import Runnir

@Suite(.serialized)
struct GitHubRESTClientTests {
    @Test func listsRepositoriesWithProductionDecoder() async throws {
        let session = URLSession.mock(statusCode: 200, body: #"[{"id":42,"name":"example","full_name":"owner/example","private":false,"visibility":"public","default_branch":"main","owner":{"login":"owner"}}]"#)
        let client = GitHubRESTClient(baseURL: URL(string: "https://api.github.test")!,
                                      credentialStore: InMemoryCredentialStore(token: "fixture"), urlSession: session)
        let repositories = try await client.listRepositories()
        #expect(repositories.count == 1)
        #expect(repositories.first?.fullName == "owner/example")
        #expect(repositories.first?.defaultBranch == "main")
    }

    @Test
    func mapsUnauthorizedResponse() async throws {
        let session = URLSession.mock(statusCode: 401, body: #"{"message":"Bad credentials"}"#)
        let client = GitHubRESTClient(
            baseURL: URL(string: "https://api.github.test")!,
            credentialStore: InMemoryCredentialStore(token: "token"),
            urlSession: session
        )

        await #expect(throws: GitHubAPIError.authenticationFailed) {
            _ = try await client.getCurrentUser()
        }
    }

    @Test
    func fetchesCurrentUser() async throws {
        let session = URLSession.mock(statusCode: 200, body: #"{"id":1,"login":"octocat","name":"Mona"}"#)
        let client = GitHubRESTClient(
            baseURL: URL(string: "https://api.github.test")!,
            credentialStore: InMemoryCredentialStore(token: "token"),
            urlSession: session
        )

        let user = try await client.getCurrentUser()

        #expect(user.login == "octocat")
        #expect(user.name == "Mona")
    }

    @Test
    func readsOneRepositoryAndMapsNotFound() async throws {
        let found = URLSession.mock(statusCode: 200, body: #"{"id":7,"name":"runnir","full_name":"dil-eight/runnir","private":false,"visibility":"public","default_branch":"main","owner":{"login":"dil-eight"}}"#)
        let client = GitHubRESTClient(baseURL: URL(string: "https://api.github.test")!,
                                      credentialStore: InMemoryCredentialStore(token: "t"), urlSession: found)
        let repository = try await client.repository(owner: "dil-eight", name: "runnir")
        #expect(repository.fullName == "dil-eight/runnir")

        let missing = URLSession.mock(statusCode: 404, body: #"{"message":"Not Found"}"#)
        let hidden = GitHubRESTClient(baseURL: URL(string: "https://api.github.test")!,
                                      credentialStore: InMemoryCredentialStore(token: "t"), urlSession: missing)
        await #expect(throws: GitHubAPIError.notFound) { _ = try await hidden.repository(owner: "o", name: "r") }
    }
}

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var body = Data()

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension URLSession {
    static func mock(statusCode: Int, body: String) -> URLSession {
        MockURLProtocol.statusCode = statusCode
        MockURLProtocol.body = Data(body.utf8)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
