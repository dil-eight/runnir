import Foundation

protocol GitHubService: Sendable {
    func getCurrentUser() async throws -> GitHubUser
}
