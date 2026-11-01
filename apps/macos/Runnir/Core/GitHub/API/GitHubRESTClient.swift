import Foundation

final class GitHubRESTClient: GitHubService {
    private let baseURL: URL
    private let credentialStore: any CredentialStoring
    private let urlSession: URLSession
    private let decoder: JSONDecoder

    init(baseURL: URL, credentialStore: any CredentialStoring, urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.credentialStore = credentialStore
        self.urlSession = urlSession
        self.decoder = JSONDecoder.github
    }

    func getCurrentUser() async throws -> GitHubUser {
        try await send(.currentUser, responseType: GitHubUser.self)
    }

    private func send<Response: Decodable & Sendable>(
        _ endpoint: GitHubEndpoint,
        responseType: Response.Type
    ) async throws -> Response {
        guard let token = try await credentialStore.token() else {
            throw GitHubAPIError.missingCredentials
        }

        let request = try endpoint.request(baseURL: baseURL, token: token)

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw GitHubAPIError.invalidResponse
            }

            try mapStatus(httpResponse, data: data)

            do {
                return try decoder.decode(Response.self, from: data)
            } catch {
                throw GitHubAPIError.decodingFailed
            }
        } catch let error as GitHubAPIError {
            throw error
        } catch {
            throw GitHubAPIError.networkUnavailable
        }
    }

    private func mapStatus(_ response: HTTPURLResponse, data: Data) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401:
            throw GitHubAPIError.authenticationFailed
        case 429:
            throw GitHubAPIError.rateLimited(resetDate: rateLimitResetDate(from: response))
        case 403:
            // The primary limit sets Remaining to 0; secondary limits send Retry-After.
            if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
                || response.value(forHTTPHeaderField: "Retry-After") != nil {
                throw GitHubAPIError.rateLimited(resetDate: rateLimitResetDate(from: response))
            }
            throw GitHubAPIError.authorizationFailed
        case 404:
            throw GitHubAPIError.notFound
        case 422:
            let message = try? decoder.decode(GitHubErrorResponse.self, from: data).message
            throw GitHubAPIError.validationFailed(message)
        case 500..<600:
            throw GitHubAPIError.serverError(statusCode: response.statusCode)
        default:
            throw GitHubAPIError.invalidResponse
        }
    }

    private func rateLimitResetDate(from response: HTTPURLResponse) -> Date? {
        if let after = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) {
            return Date().addingTimeInterval(after)
        }
        guard let value = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
              let interval = TimeInterval(value)
        else {
            return nil
        }
        return Date(timeIntervalSince1970: interval)
    }
}

private extension JSONDecoder {
    static var github: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
