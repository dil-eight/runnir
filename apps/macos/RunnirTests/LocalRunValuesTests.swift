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

@MainActor
@Suite struct WorkspaceValuesModelTests {
    private let workspace = UUID()
    private let token = LocalRunValueKey(kind: .secret, name: "NPM_TOKEN")
    private let region = LocalRunValueKey(kind: .variable, name: "REGION")

    private func workflows() -> [CoreWorkflow] {
        [CoreWorkflow(id: ".github/workflows/ci.yml", name: "CI", triggers: ["push"], jobs: [], parseError: nil,
                      secrets: ["NPM_TOKEN", "SHARED"], variables: ["REGION", "SHARED"]),
         CoreWorkflow(id: ".github/workflows/deploy.yml", name: "Deploy", triggers: ["push"], jobs: [], parseError: nil,
                      secrets: ["NPM_TOKEN"])]
    }

    @Test func rowsMergeWorkflowsAndSavedNames() async {
        let old = LocalRunValueKey(kind: .secret, name: "OLD")
        let store = InMemoryLocalRunValueStore(values: [workspace: [token: "s3cr3t", region: "eu", old: "x"]])
        let model = WorkspaceValuesModel()
        await model.load(workspaceID: workspace, workflows: workflows(), store: store)
        #expect(model.secrets.map(\.key.name) == ["NPM_TOKEN", "SHARED"])
        #expect(model.secrets.first?.workflows == ["ci.yml", "deploy.yml"])
        #expect(model.secrets.first?.saved == true)
        #expect(model.secrets.last?.saved == false)
        #expect(model.variables.map(\.key.name) == ["REGION", "SHARED"])
        #expect(model.unused.map(\.key) == [old])
        // Variables show without asking; secrets stay hidden.
        #expect(model.text(for: region) == "eu")
        #expect(model.text(for: token) == "")
    }

    @Test func editsArePendingUntilSave() async throws {
        let store = InMemoryLocalRunValueStore()
        let model = WorkspaceValuesModel()
        await model.load(workspaceID: workspace, workflows: workflows(), store: store)
        model.setText("typed", for: token)
        #expect(model.isDirty)
        #expect(try await store.value(workspaceID: workspace, key: token) == nil)
        model.revert()
        #expect(!model.isDirty)
        #expect(model.text(for: token) == "")
        model.setText("typed", for: token)
        #expect(await model.save(workspaceID: workspace, store: store))
        #expect(try await store.value(workspaceID: workspace, key: token) == "typed")
        #expect(!model.isDirty)
        #expect(model.secrets.first?.saved == true)
        model.forget(token)
        #expect(model.isDirty)
        #expect(await model.save(workspaceID: workspace, store: store))
        #expect(try await store.value(workspaceID: workspace, key: token) == nil)
        #expect(model.secrets.first?.saved == false)
    }

    @Test func forgettingAnUnusedValueRemovesItsRow() async throws {
        let old = LocalRunValueKey(kind: .variable, name: "OLD")
        let store = InMemoryLocalRunValueStore(values: [workspace: [old: "x"]])
        let model = WorkspaceValuesModel()
        await model.load(workspaceID: workspace, workflows: workflows(), store: store)
        model.forget(old)
        #expect(await model.save(workspaceID: workspace, store: store))
        #expect(model.unused.isEmpty)
        #expect(try await store.keys(workspaceID: workspace).isEmpty)
    }

    @Test func revealAsksTheOwnerFirst() async {
        let store = InMemoryLocalRunValueStore(values: [workspace: [token: "s3cr3t"]])
        let model = WorkspaceValuesModel()
        await model.load(workspaceID: workspace, workflows: workflows(), store: store)
        await model.reveal(token, workspaceID: workspace, store: store) { _ in .declined }
        #expect(model.text(for: token) == "")
        var reason = ""
        await model.reveal(token, workspaceID: workspace, store: store) { reason = $0; return .confirmed }
        #expect(model.text(for: token) == "s3cr3t")
        #expect(reason == "show the saved value of NPM_TOKEN")
        model.hideSecrets()
        #expect(model.text(for: token) == "")
    }

    @Test func refusedReadsAreMarked() async {
        let store = InMemoryLocalRunValueStore(values: [workspace: [token: "s3cr3t", region: "eu"]])
        await store.setFailReads(true)
        let model = WorkspaceValuesModel()
        await model.load(workspaceID: workspace, workflows: workflows(), store: store)
        #expect(model.refused == [region])
        await model.reveal(token, workspaceID: workspace, store: store) { _ in .confirmed }
        #expect(model.refused == [region, token])
    }

    @Test func importFillsMatchingNamesAndCountsTheRest() async {
        let model = WorkspaceValuesModel()
        await model.load(workspaceID: workspace, workflows: workflows(), store: InMemoryLocalRunValueStore())
        model.apply(CoreEnvFile(entries: [
            CoreEnvEntry(name: "NPM_TOKEN", value: "from-file", encrypted: false, line: 1),
            CoreEnvEntry(name: "SHARED", value: "both", encrypted: false, line: 2),
            CoreEnvEntry(name: "UNUSED", value: "x", encrypted: false, line: 3),
            CoreEnvEntry(name: "REGION", value: "", encrypted: true, line: 4),
        ], problems: [CoreEnvProblem(line: 5, message: "Not a NAME=value line.")]))
        #expect(model.text(for: token) == "from-file")
        #expect(model.text(for: LocalRunValueKey(kind: .secret, name: "SHARED")) == "both")
        #expect(model.text(for: LocalRunValueKey(kind: .variable, name: "SHARED")) == "both")
        #expect(model.text(for: region) == "")
        #expect(model.importSummary == "Filled 3 values. 1 name is not used by any workflow. 1 value is encrypted by dotenvx and was not imported. Line 5 could not be read.")
    }
}
