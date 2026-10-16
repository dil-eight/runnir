import Foundation

struct GitHubRepositoryDTO: Decodable, Sendable {
    let id: Int64
    let name: String
    let fullName: String
    let `private`: Bool
    let visibility: String?
    let defaultBranch: String
    let owner: Owner

    struct Owner: Decodable, Sendable {
        let login: String
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case fullName = "full_name"
        case `private`
        case visibility
        case defaultBranch = "default_branch"
        case owner
    }

    func domainModel() -> Repository {
        let resolvedVisibility: RepositoryVisibility
        if let visibility, let parsed = RepositoryVisibility(rawValue: visibility) {
            resolvedVisibility = parsed
        } else {
            resolvedVisibility = self.private ? .private : .public
        }

        return Repository(
            id: id,
            owner: owner.login,
            name: name,
            fullName: fullName,
            defaultBranch: defaultBranch,
            visibility: resolvedVisibility
        )
    }
}

struct GitHubWorkflowDTO: Decodable, Sendable {
    let id: Int64
    let name: String
    let path: String
    let state: WorkflowState

    func domainModel(repositoryFullName: String) -> Workflow {
        Workflow(id: id, repositoryFullName: repositoryFullName, name: name, path: path, state: state)
    }
}

struct GitHubWorkflowListResponse: Decodable, Sendable {
    let workflows: [GitHubWorkflowDTO]
}
