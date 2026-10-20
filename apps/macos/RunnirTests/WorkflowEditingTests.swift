import AppKit
import Foundation
import Testing
@testable import Runnir

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct WorkflowEditingTests {
    private static let original = "name: CI\non: push\njobs:\n  lint:\n    runs-on: ubuntu-latest\n"

    /// A repository on disk with one workflow, its reader, and a ready hub
    /// whose fake Core holds the same file.
    private func setUp() async throws -> (root: URL, reader: RepositoryReader, hub: CoreHub, core: FakeCore, workspace: UUID) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".github/workflows"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Self.original.write(to: root.appendingPathComponent(".github/workflows/ci.yml"), atomically: true, encoding: .utf8)
        let reader = try RepositoryReader(root: root)
        let provider = FakeProvider()
        provider.core.savedFiles[".github/workflows/ci.yml"] = Self.original
        let hub = CoreHub(provider: provider)
        hub.startMonitoring()
        provider.ready()
        _ = await eventually { hub.status == .ready(version: "fake") }
        let workspace = UUID()
        hub.attach(windowID: UUID(), workspaceID: workspace, path: root.path)
        _ = await eventually { hub.session(for: workspace)?.phase == .ready }
        return (root, reader, hub, provider.core, workspace)
    }

    private func loaded(_ reader: RepositoryReader) async -> WorkspaceFilesModel {
        let model = WorkspaceFilesModel()
        await model.load(reader)
        _ = await eventually { model.savedDigest != nil }
        return model
    }

    @Test func editsAreDirtyUntilSaved() async throws {
        let (root, reader, hub, core, workspace) = try await setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = await loaded(reader)
        #expect(model.source == Self.original)
        #expect(model.savedDigest == WorkflowDigest.sha256(Self.original))
        #expect(model.isWritable)
        #expect(!model.isDirty)

        model.source = Self.original + "# edited\n"
        #expect(model.isDirty)
        #expect(await model.save(hub: hub, workspaceID: workspace))
        #expect(!model.isDirty)
        #expect(core.saves.last?.content == Self.original + "# edited\n")
        #expect(model.savedDigest == WorkflowDigest.sha256(Self.original + "# edited\n"))
    }

    @Test func aFileChangedElsewhereIsAConflictUntilOverwritten() async throws {
        let (root, reader, hub, core, workspace) = try await setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = await loaded(reader)
        core.savedFiles[".github/workflows/ci.yml"] = "name: Changed elsewhere\n"
        model.source = "mine\n"
        #expect(await model.save(hub: hub, workspaceID: workspace) == false)
        #expect(model.diskChange == .conflict)
        #expect(model.isDirty)
        #expect(core.savedFiles[".github/workflows/ci.yml"] == "name: Changed elsewhere\n")

        #expect(await model.save(hub: hub, workspaceID: workspace, overwrite: true))
        #expect(model.diskChange == nil)
        #expect(core.saves.last?.overwrite == true)
        #expect(core.savedFiles[".github/workflows/ci.yml"] == "mine\n")
    }

    @Test func aFailedSaveKeepsTheEditsAndSaysWhy() async throws {
        let (root, reader, hub, core, workspace) = try await setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = await loaded(reader)
        core.saveError = .failedPrecondition("the workflow file is read-only")
        model.source = "mine\n"
        #expect(await model.save(hub: hub, workspaceID: workspace) == false)
        #expect(model.saveError == "The workflow file is read-only.")
        #expect(model.source == "mine\n")
        #expect(model.isDirty)
    }

    @Test func reloadingKeepsEditsAndNoticesChangesOnDisk() async throws {
        let (root, reader, _, _, _) = try await setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(".github/workflows/ci.yml")
        let model = await loaded(reader)

        // Clean: a reload shows the new file.
        try "name: Outside\n".write(to: file, atomically: true, encoding: .utf8)
        await model.load(reader)
        _ = await eventually { model.source == "name: Outside\n" }
        #expect(model.source == "name: Outside\n")
        #expect(model.diskChange == nil)

        // Edited: a reload keeps the edits and says the file changed.
        model.source = "mine\n"
        try "name: Outside again\n".write(to: file, atomically: true, encoding: .utf8)
        await model.load(reader)
        #expect(model.source == "mine\n")
        #expect(model.diskChange == .changedOnDisk)

        model.reloadFromDisk(reader: reader)
        _ = await eventually { model.source == "name: Outside again\n" }
        #expect(!model.isDirty)
        #expect(model.diskChange == nil)
    }

    @Test func aReadOnlyFileOpensReadOnly() async throws {
        let (root, reader, _, _, _) = try await setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: root.appendingPathComponent(".github/workflows/ci.yml").path)
        let model = await loaded(reader)
        #expect(!model.isWritable)
    }

    @Test func lineStartsCountEveryLineBreak() {
        #expect(CodeEditor.lineStarts(of: "") == [0])
        #expect(CodeEditor.lineStarts(of: "a") == [0])
        #expect(CodeEditor.lineStarts(of: "a\n") == [0, 2])
        #expect(CodeEditor.lineStarts(of: "a\nb\n\nc") == [0, 2, 4, 5])
        #expect(CodeEditor.lineStarts(of: "a\r\nb") == [0, 3])
        #expect(CodeEditor.lineStarts(of: "é\n👋\n") == [0, 2, 5])
    }

    @Test func unsavedPromptIsTheMacOne() {
        let alert = UnsavedChangesPrompt.alert(for: ["ci.yml"])
        #expect(alert.messageText == "Do you want to save the changes you made to ci.yml?")
        #expect(alert.informativeText == "Your changes will be lost if you don't save them.")
        #expect(alert.buttons.map(\.title) == ["Save", "Don't Save", "Cancel"])
        #expect(alert.buttons[0].keyEquivalent == "\r")
        #expect(UnsavedChangesPrompt.title(for: ["ci.yml", "release.yml"]) == "Do you want to save the changes you made to 2 workflow files?")
    }

    @Test func tokenizerKeepsTheOldColors() {
        let tokens = YAMLSyntaxHighlighting.tokens(in: "  name: \"CI # x\" # comment")
        #expect(tokens.map(\.token) == [.key, .string, .comment])
        #expect(tokens.first?.range == NSRange(location: 2, length: 4))
    }

    @Test func aSaveThatEndsAfterAReloadLeavesTheReloadAlone() async throws {
        let (root, reader, hub, core, workspace) = try await setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = await loaded(reader)
        core.saveDelay = .milliseconds(300)
        model.source = "mine\n"
        let save = Task { await model.save(hub: hub, workspaceID: workspace) }
        try await Task.sleep(for: .milliseconds(50))
        model.reloadFromDisk(reader: reader)
        _ = await eventually { model.savedDigest != nil }
        #expect(await save.value == false)
        #expect(model.source == Self.original)
        #expect(model.savedDigest == WorkflowDigest.sha256(Self.original))
        #expect(!model.isDirty)
    }

    @Test func locatingTheSameWorkspaceKeepsTheEdits() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let workspace = WorkspaceRecord(id: UUID(), path: root.path, name: "repo", bookmark: Data(), lastOpenedAt: Date())
        let record = WorkspaceWindowRecord(id: UUID(), workspaceID: workspace.id)
        let controller = WorkspaceWindowController(record: record, workspace: workspace, grant: nil, desktop: DesktopCoordinator())
        let files = try #require(controller.files)
        files.source = "edited"

        controller.attach(record: record, workspace: workspace, grant: StubGrant(root: root))
        #expect(controller.files === files)

        let other = WorkspaceRecord(id: UUID(), path: root.path, name: "other", bookmark: Data(), lastOpenedAt: Date())
        controller.attach(record: WorkspaceWindowRecord(id: record.id, workspaceID: other.id), workspace: other, grant: StubGrant(root: root))
        #expect(controller.files !== files)
        controller.close()
    }
}

@MainActor
private final class StubGrant: RepositoryGranting {
    let url: URL
    let reader: RepositoryReader
    init(root: URL) {
        url = root
        reader = try! RepositoryReader(root: root)
    }
    func stop() {}
}
