import Foundation

enum GitHubEndpoint: Sendable {
    case currentUser

    func request(baseURL: URL, token: String?) throws -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = path

        guard let url = components?.url else {
            throw GitHubAPIError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        return request
    }

    private var path: String {
        switch self {
        case .currentUser:
            "/user"
        }
    }
}
