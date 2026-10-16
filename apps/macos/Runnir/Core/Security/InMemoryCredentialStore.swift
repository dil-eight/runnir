import Foundation

actor InMemoryCredentialStore: CredentialStoring {
    private var storedToken: String?

    init(token: String? = nil) {
        self.storedToken = token
    }

    func token() async throws -> String? {
        storedToken
    }

    func saveToken(_ token: String) async throws {
        storedToken = token
    }

    func removeToken() async throws {
        storedToken = nil
    }
}
