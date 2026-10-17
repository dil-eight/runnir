import Foundation

enum GitHubAPIError: Error, Equatable, LocalizedError, Sendable {
    case invalidRequest
    case missingCredentials
    case authenticationFailed
    case authorizationFailed
    case notFound
    case validationFailed(String?)
    case rateLimited(resetDate: Date?)
    case serverError(statusCode: Int)
    case invalidResponse
    case decodingFailed
    case networkUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            "The GitHub request could not be created."
        case .missingCredentials:
            "GitHub credentials are not available."
        case .authenticationFailed:
            "GitHub authentication failed. Sign in again."
        case .authorizationFailed:
            "GitHub denied access to this resource."
        case .notFound:
            "The GitHub resource was not found."
        case .validationFailed(let message):
            message ?? "GitHub rejected the request."
        case .rateLimited:
            "GitHub rate limit reached. Try again later."
        case .serverError(let statusCode):
            "GitHub returned server error \(statusCode)."
        case .invalidResponse:
            "GitHub returned an invalid response."
        case .decodingFailed:
            "GitHub response could not be decoded."
        case .networkUnavailable:
            "Network connection is unavailable."
        }
    }
}

struct GitHubErrorResponse: Decodable, Sendable {
    let message: String?
}
