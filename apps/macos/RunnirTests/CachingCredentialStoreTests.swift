import Foundation
import Testing
@testable import Runnir

private actor CountingStore: CredentialStoring {
    var stored: String?
    var reads = 0
    var failReads = false
    init(token: String?) { stored = token }
    func setFailReads(_ value: Bool) { failReads = value }
    func token() async throws -> String? {
        reads += 1
        if failReads { throw KeychainError.unhandledStatus(-128) }
        return stored
    }
    func saveToken(_ token: String) async throws { stored = token }
    func removeToken() async throws { stored = nil }
}

struct CachingCredentialStoreTests {
    @Test
    func readsTheBackingStoreOnce() async throws {
        let backing = CountingStore(token: "t")
        let store = CachingCredentialStore(wrapping: backing)
        for _ in 0..<5 { #expect(try await store.token() == "t") }
        #expect(await backing.reads == 1)
    }

    @Test
    func anEmptyResultIsCachedToo() async throws {
        let backing = CountingStore(token: nil)
        let store = CachingCredentialStore(wrapping: backing)
        #expect(try await store.token() == nil)
        #expect(try await store.token() == nil)
        #expect(await backing.reads == 1)
    }

    @Test
    func aDeniedReadIsRetriedLater() async throws {
        let backing = CountingStore(token: "t")
        await backing.setFailReads(true)
        let store = CachingCredentialStore(wrapping: backing)
        await #expect(throws: KeychainError.self) { _ = try await store.token() }
        await backing.setFailReads(false)
        #expect(try await store.token() == "t")
        #expect(await backing.reads == 2)
    }

    @Test
    func writesUpdateTheCacheAndTheBackingStore() async throws {
        let backing = CountingStore(token: nil)
        let store = CachingCredentialStore(wrapping: backing)
        try await store.saveToken("new")
        #expect(try await store.token() == "new")
        #expect(await backing.stored == "new")
        #expect(await backing.reads == 0)
        try await store.removeToken()
        #expect(try await store.token() == nil)
        #expect(await backing.stored == nil)
    }
}
