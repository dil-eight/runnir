import Foundation

/// Reads the token from the backing store once and serves it from memory, so
/// the Keychain is consulted once per launch instead of on every API request.
/// A failed read is not cached: after the user denies a Keychain prompt, the
/// next request asks again. Writes go to the backing store first.
actor CachingCredentialStore: CredentialStoring {
    private let backing: any CredentialStoring
    /// `.none`: not loaded yet. `.some(nil)`: loaded, no token.
    private var cached: String??

    init(wrapping backing: any CredentialStoring) {
        self.backing = backing
    }

    /// The app's single Keychain-backed store.
    static let keychain = CachingCredentialStore(wrapping: KeychainCredentialStore())

    func token() async throws -> String? {
        if let cached { return cached }
        let loaded = try await backing.token()
        cached = .some(loaded)
        return loaded
    }

    func saveToken(_ token: String) async throws {
        try await backing.saveToken(token)
        cached = .some(token)
    }

    func removeToken() async throws {
        try await backing.removeToken()
        cached = .some(nil)
    }
}
