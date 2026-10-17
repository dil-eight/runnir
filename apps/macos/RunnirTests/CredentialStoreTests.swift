import Testing
@testable import Runnir

struct CredentialStoreTests {
    @Test
    func inMemoryCredentialStoreSavesAndRemovesToken() async throws {
        let store = InMemoryCredentialStore()

        try await store.saveToken("secret")
        #expect(try await store.token() == "secret")

        try await store.removeToken()
        #expect(try await store.token() == nil)
    }
}
