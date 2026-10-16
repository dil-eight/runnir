import Foundation

struct Repository: Identifiable, Equatable, Sendable {
    let id: Int64
    let owner: String
    let name: String
    let fullName: String
    let defaultBranch: String
    let visibility: RepositoryVisibility
}

enum RepositoryVisibility: String, Codable, Equatable, Sendable {
    case `private`
    case `public`
    case `internal`

    var displayName: String {
        rawValue.capitalized
    }
}
