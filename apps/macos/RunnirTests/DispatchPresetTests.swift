import Foundation
import Testing
@testable import Runnir

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("presets-" + UUID().uuidString, isDirectory: true)
}

private final class FailingPresetStore: DispatchPresetStoring, @unchecked Sendable {
    var saves = 0
    func load() throws -> [DispatchPreset] { throw DesktopStoreError.invalidState }
    func save(_ presets: [DispatchPreset]) throws { saves += 1 }
}

@Suite
struct DispatchPresetStoreTests {
    @Test
    func presetsRoundTripInAPrivateFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileDispatchPresetStore(directory: directory)
        #expect(try store.load().isEmpty)
        let preset = DispatchPreset(id: UUID(), name: "Staging defaults", workspaceID: UUID(), workflowPath: ".github/workflows/deploy.yml",
                                    ref: "main", inputs: ["environment": "staging"], updatedAt: Date(timeIntervalSince1970: 1_000))
        try store.save([preset])
        #expect(try store.load() == [preset])
        let mode = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test
    func aDamagedFileIsRefusedNotGuessed() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = FileDispatchPresetStore(directory: directory)
        try Data(#"{"version":2,"presets":[]}"#.utf8).write(to: store.fileURL)
        #expect(throws: (any Error).self) { try store.load() }
        try Data("not json".utf8).write(to: store.fileURL)
        #expect(throws: (any Error).self) { try store.load() }
    }

    @Test
    func inputsThatLookSecretAreRecognized() {
        func input(_ name: String, _ description: String = "") -> CoreDispatchInput {
            CoreDispatchInput(name: name, description: description, kind: .string, required: false, defaultValue: "", options: [])
        }
        #expect(DispatchPreset.looksSecret(input("deploy_token")))
        #expect(DispatchPreset.looksSecret(input("API_KEY")))
        #expect(DispatchPreset.looksSecret(input("value", "The password for the staging database")))
        #expect(DispatchPreset.looksSecret(input("ssh_key")))
        #expect(DispatchPreset.looksSecret(input("deployKey")))
        #expect(DispatchPreset.looksSecret(input("github-pat")))
        #expect(DispatchPreset.looksSecret(input("code", "One-time OTP code")))
        #expect(!DispatchPreset.looksSecret(input("environment")))
        #expect(!DispatchPreset.looksSecret(input("author")))
        #expect(!DispatchPreset.looksSecret(input("keyboard_layout")))
        #expect(!DispatchPreset.looksSecret(input("pattern")))
        #expect(DispatchPreset.words("deployKey_v2 Name") == ["deploy", "key", "v2", "name"])
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DispatchPresetLibraryTests {
    @Test
    func presetsAreAddedRenamedUpdatedAndRemoved() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = DispatchPresetLibrary(store: FileDispatchPresetStore(directory: directory))
        library.prepare()
        let workspace = UUID()
        let path = ".github/workflows/deploy.yml"
        let preset = try #require(library.add(name: "  Staging  ", workspaceID: workspace, workflowPath: path, ref: "main", inputs: ["env": "staging"]))
        #expect(preset.name == "Staging")
        #expect(library.rename(preset.id, to: "Staging EU"))
        #expect(library.update(preset.id, ref: "release", inputs: ["env": "prod"]))
        #expect(library.add(name: " ", workspaceID: workspace, workflowPath: path, ref: "main", inputs: [:]) == nil)
        #expect(library.problem != nil)

        // A fresh library reads what was saved.
        let reread = DispatchPresetLibrary(store: FileDispatchPresetStore(directory: directory))
        reread.prepare()
        let saved = try #require(reread.presets(workspaceID: workspace, workflowPath: path).first)
        #expect(saved.name == "Staging EU" && saved.ref == "release" && saved.inputs == ["env": "prod"])
        #expect(reread.presets(workspaceID: UUID(), workflowPath: path).isEmpty)

        reread.removeAll(workspaceID: workspace)
        #expect(try FileDispatchPresetStore(directory: directory).load().isEmpty)
    }

    @Test
    func anUnreadableFileTurnsPresetsOffWithoutOverwritingIt() {
        let store = FailingPresetStore()
        let library = DispatchPresetLibrary(store: store)
        library.prepare()
        #expect(!library.isAvailable)
        #expect(library.problem?.contains("could not be read") == true)
        #expect(library.add(name: "x", workspaceID: UUID(), workflowPath: ".github/workflows/a.yml", ref: "main", inputs: [:]) == nil)
        #expect(store.saves == 0, "an unreadable file is never overwritten")
    }

    @Test
    func aWorkflowHoldsAtMostFiftyPresets() {
        let library = DispatchPresetLibrary(store: FileDispatchPresetStore(directory: temporaryDirectory()))
        library.prepare()
        let workspace = UUID()
        for index in 0..<DispatchPresetLibrary.perWorkflowLimit {
            #expect(library.add(name: "p\(index)", workspaceID: workspace, workflowPath: "w", ref: "main", inputs: [:]) != nil)
        }
        #expect(library.add(name: "one more", workspaceID: workspace, workflowPath: "w", ref: "main", inputs: [:]) == nil)
        #expect(library.add(name: "other workflow", workspaceID: workspace, workflowPath: "x", ref: "main", inputs: [:]) != nil)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DispatchPresetFormTests {
    private let workflow = CoreGitHubWorkflow(id: 1, name: "Deploy", path: ".github/workflows/deploy.yml", state: "active", htmlURL: nil)
    private let inputs = [
        CoreDispatchInput(name: "environment", description: "", kind: .choice, required: true, defaultValue: "staging", options: ["staging", "production"]),
        CoreDispatchInput(name: "version", description: "", kind: .string, required: false, defaultValue: "", options: []),
        CoreDispatchInput(name: "deploy_token", description: "", kind: .string, required: false, defaultValue: "", options: []),
    ]

    private func rig() async -> (DispatchFormModel, DispatchPresetLibrary, FakeProvider, URL) {
        let provider = FakeProvider()
        let hub = CoreHub(provider: provider)
        hub.startMonitoring()
        provider.ready()
        provider.core.setBranch("feature", for: "/repo/linked")
        provider.core.dispatchDefinition = CoreDispatchDefinition(access: .ok, dispatchable: true, inputs: inputs, parseError: nil)
        let workspace = UUID()
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/linked")
        _ = await eventually { hub.session(for: workspace)?.githubAccess == .ok }
        let directory = temporaryDirectory()
        let library = DispatchPresetLibrary(store: FileDispatchPresetStore(directory: directory))
        let form = DispatchFormModel(workspaceID: workspace, hub: hub, workflows: [workflow], workflowID: nil,
                                     currentBranch: "feature", presets: library)
        await form.load()
        return (form, library, provider, directory)
    }

    @Test
    func aSavedPresetKeepsBranchAndValuesButNoSecrets() async throws {
        let (form, library, _, directory) = await rig()
        defer { try? FileManager.default.removeItem(at: directory) }
        form.values["environment"] = "production"
        form.values["version"] = "1.4.0"
        form.values["deploy_token"] = "ghp_should_never_be_saved"
        #expect(form.inputsLeftOutOfPresets == ["deploy_token"])
        #expect(form.saveAsPreset(named: "Production"))
        let saved = try #require(library.presets(workspaceID: form.workspaceID, workflowPath: workflow.path).first)
        #expect(saved.ref == "feature")
        #expect(saved.inputs == ["environment": "production", "version": "1.4.0"])
        let file = try String(contentsOf: FileDispatchPresetStore(directory: directory).fileURL, encoding: .utf8)
        #expect(!file.contains("ghp_should_never_be_saved"))

        #expect(form.appliedPreset?.id == saved.id && !form.presetIsModified)
        form.values["version"] = "1.5.0"
        #expect(form.presetIsModified)
        #expect(form.updateAppliedPreset())
        #expect(!form.presetIsModified)
        #expect(library.preset(id: saved.id)?.inputs["version"] == "1.5.0")
    }

    @Test
    func aPresetChosenOnTheOverviewIsAppliedWhenTheSheetOpens() async throws {
        let provider = FakeProvider()
        let hub = CoreHub(provider: provider)
        hub.startMonitoring()
        provider.ready()
        provider.core.setBranch("feature", for: "/repo/linked")
        provider.core.dispatchDefinition = CoreDispatchDefinition(access: .ok, dispatchable: true, inputs: inputs, parseError: nil)
        let workspace = UUID()
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/linked")
        _ = await eventually { hub.session(for: workspace)?.githubAccess == .ok }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = DispatchPresetLibrary(store: FileDispatchPresetStore(directory: directory))
        let preset = try #require(library.add(name: "Production", workspaceID: workspace, workflowPath: workflow.path,
                                              ref: "feature", inputs: ["environment": "production"]))

        let form = DispatchFormModel(workspaceID: workspace, hub: hub, workflows: [workflow], workflowID: workflow.id,
                                     currentBranch: "feature", presets: library, presetID: preset.id)
        await form.load()
        #expect(await eventually { form.values["environment"] == "production" })
        #expect(form.appliedPresetID == preset.id)
    }

    @Test
    func applyingAPresetSwitchesBranchThenFillsTheInputs() async throws {
        let (form, library, _, directory) = await rig()
        defer { try? FileManager.default.removeItem(at: directory) }
        let preset = try #require(library.add(name: "Main release", workspaceID: form.workspaceID, workflowPath: workflow.path,
                                              ref: "main", inputs: ["environment": "production", "version": "2.0.0"]))
        form.values["version"] = "typed"
        form.apply(preset)
        #expect(await eventually { form.ref == "main" && !form.isLoadingDefinition && form.values["version"] == "2.0.0" })
        #expect(form.values["environment"] == "production")
        #expect(form.values["deploy_token"] == "", "inputs the preset does not hold start from their defaults")
        #expect(form.presetNotes.isEmpty)
        #expect(!form.presetIsModified)
    }

    @Test
    func aPresetFromAnOlderSchemaSaysWhatNoLongerApplies() async throws {
        let (form, library, _, directory) = await rig()
        defer { try? FileManager.default.removeItem(at: directory) }
        let preset = try #require(library.add(name: "Old", workspaceID: form.workspaceID, workflowPath: workflow.path,
                                              ref: "gone-branch", inputs: ["environment": "qa", "region": "eu", "version": "3.0"]))
        form.apply(preset)
        #expect(form.ref == "feature")
        #expect(form.values["version"] == "3.0")
        #expect(form.values["environment"] == "staging")
        #expect(form.presetNotes.count == 3)
        #expect(form.presetNotes.contains { $0.contains("gone-branch") })
        #expect(form.presetNotes.contains { $0.contains("\"region\" is no longer an input") })
        #expect(form.presetNotes.contains { $0.contains("\"environment\" no longer offers qa") })
        #expect(form.presetIsModified, "the form differs from what the preset holds")
    }

    @Test
    func choosingAnotherWorkflowForgetsTheAppliedPreset() async throws {
        let (form, library, _, directory) = await rig()
        defer { try? FileManager.default.removeItem(at: directory) }
        let preset = try #require(library.add(name: "P", workspaceID: form.workspaceID, workflowPath: workflow.path, ref: "feature", inputs: [:]))
        form.apply(preset)
        #expect(form.appliedPresetID == preset.id)
        form.select(workflowID: 1)
        #expect(form.appliedPresetID == nil && form.presetNotes.isEmpty)
        form.apply(preset)
        form.deleteAppliedPreset()
        #expect(form.appliedPresetID == nil && library.presets(workspaceID: form.workspaceID, workflowPath: workflow.path).isEmpty)
    }
}
