import Foundation

protocol GitHubService: Sendable {
    func getCurrentUser() async throws -> GitHubUser
    func listRepositories() async throws -> [Repository]
    func listWorkflows(owner: String, repository: String) async throws -> [Workflow]
}
