import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    var selectedSection: AppSection = .dashboard
    var authenticationState: AuthenticationState = .unknown
    var lastError: AppError?
    /// The workspace switcher is showing in this window.
    var showingSwitcher = false
}

enum AuthenticationState: Equatable, Sendable {
    case unknown
    case unauthenticated
    case authenticated(GitHubUser)
}

enum AppError: Error, Equatable, Sendable, Identifiable {
    case message(String)

    var id: String { localizedDescription }

    var localizedDescription: String {
        switch self {
        case .message(let message):
            message
        }
    }
}
