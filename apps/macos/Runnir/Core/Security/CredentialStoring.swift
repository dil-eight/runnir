import Foundation

protocol CredentialStoring: Sendable {
    func token() async throws -> String?
    func saveToken(_ token: String) async throws
    func removeToken() async throws
}
