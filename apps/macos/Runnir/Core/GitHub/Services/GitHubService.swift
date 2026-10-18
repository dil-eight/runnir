import Foundation

protocol GitHubService: Sendable {
    func getCurrentUser() async throws -> GitHubUser
    func listRepositories() async throws -> [Repository]
    /// One repository by "owner/name"; `notFound` when the token cannot see it.
    func repository(owner: String, name: String) async throws -> Repository
    func listWorkflows(owner: String, repository: String) async throws -> [Workflow]
}
