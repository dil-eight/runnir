import Foundation
import Testing
@testable import Runnir

struct GitHubDecodingTests {
    @Test
    func repositoryDTOMapsToDomainModel() throws {
        let json = """
        {
          "id": 42,
          "name": "runnir",
          "full_name": "dil-eight/runnir",
          "private": false,
          "visibility": "public",
          "default_branch": "main",
          "owner": { "login": "dil-eight" }
        }
        """.data(using: .utf8)!

        let dto = try JSONDecoder().decode(GitHubRepositoryDTO.self, from: json)
        let repository = dto.domainModel()

        #expect(repository.id == 42)
        #expect(repository.owner == "dil-eight")
        #expect(repository.fullName == "dil-eight/runnir")
        #expect(repository.visibility == .public)
    }

    @Test
    func workflowDTOMapsToDomainModel() throws {
        let json = """
        {
          "id": 1001,
          "name": "CI",
          "path": ".github/workflows/ci.yml",
          "state": "active"
        }
        """.data(using: .utf8)!

        let dto = try JSONDecoder().decode(GitHubWorkflowDTO.self, from: json)
        let workflow = dto.domainModel(repositoryFullName: "dil-eight/runnir")

        #expect(workflow.id == 1001)
        #expect(workflow.repositoryFullName == "dil-eight/runnir")
        #expect(workflow.state == .active)
    }
}
