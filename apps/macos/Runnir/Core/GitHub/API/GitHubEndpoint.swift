import Foundation

enum GitHubEndpoint: Sendable {
    case currentUser
    case repositories(page: Int)
    case workflows(owner: String, repository: String, page: Int)

    func request(baseURL: URL, token: String?) throws -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = path
        components?.queryItems = queryItems

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
        case .repositories:
            "/user/repos"
        case .workflows(let owner, let repository, _):
            "/repos/\(owner)/\(repository)/actions/workflows"
        }
    }

    private var queryItems: [URLQueryItem]? {
        switch self {
        case .currentUser:
            nil
        case .repositories(let page):
            [
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "sort", value: "updated")
            ]
        case .workflows(_, _, let page):
            [
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "page", value: String(page))
            ]
        }
    }
}
