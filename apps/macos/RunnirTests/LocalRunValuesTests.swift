import Foundation
import Testing
@testable import Runnir

@Suite struct LocalRunValueStoreTests {
    @Test func inMemoryStoreKeepsValuesPerWorkspace() async throws {
        let store = InMemoryLocalRunValueStore()
        let a = UUID(), b = UUID()
        let token = LocalRunValueKey(kind: .secret, name: "NPM_TOKEN")
        let sameName = LocalRunValueKey(kind: .variable, name: "NPM_TOKEN")
        try await store.save(workspaceID: a, key: token, value: "s3cr3t")
        try await store.save(workspaceID: a, key: sameName, value: "eu")
        #expect(try await store.keys(workspaceID: a) == [token, sameName])
        #expect(try await store.keys(workspaceID: b).isEmpty)
        #expect(try await store.value(workspaceID: a, key: token) == "s3cr3t")
        #expect(try await store.value(workspaceID: a, key: sameName) == "eu")
        try await store.remove(workspaceID: a, key: token)
        #expect(try await store.value(workspaceID: a, key: token) == nil)
        try await store.removeAll(workspaceID: a)
        #expect(try await store.keys(workspaceID: a).isEmpty)
    }

    @Test func keychainNamesRoundTrip() {
        let key = LocalRunValueKey(kind: .variable, name: "REGION")
        #expect(KeychainLocalRunValueStore.account(for: key) == "variable:REGION")
        #expect(KeychainLocalRunValueStore.key(fromAccount: "variable:REGION") == key)
        #expect(KeychainLocalRunValueStore.key(fromAccount: "secret:A:B") == LocalRunValueKey(kind: .secret, name: "A:B"))
        #expect(KeychainLocalRunValueStore.key(fromAccount: "other:REGION") == nil)
        #expect(KeychainLocalRunValueStore.key(fromAccount: "secret:") == nil)
        let workspace = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        #expect(KeychainLocalRunValueStore.service(prefix: "dev.runnir.local-run", workspaceID: workspace)
                == "dev.runnir.local-run.6f9619ff-8b86-d011-b42d-00c04fc964ff")
    }

    @Test func keysSortByNameThenKind() {
        let keys = [LocalRunValueKey(kind: .variable, name: "B"), LocalRunValueKey(kind: .variable, name: "A"),
                    LocalRunValueKey(kind: .secret, name: "A")]
        #expect(keys.sorted() == [LocalRunValueKey(kind: .secret, name: "A"), LocalRunValueKey(kind: .variable, name: "A"),
                                  LocalRunValueKey(kind: .variable, name: "B")])
    }
}
