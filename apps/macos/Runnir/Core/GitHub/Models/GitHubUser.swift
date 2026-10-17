import Foundation

struct GitHubUser: Codable, Equatable, Sendable {
    let id: Int64
    let login: String
    let name: String?
}
