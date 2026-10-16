import Foundation
import AppKit
import Testing
@testable import Runnir

@MainActor
struct CodePreviewLayoutTests {
    @Test func wrappingKeepsLogicalLinesIntact() {
        let long = CodePreviewLayout(source: "name: CI\n" + String(repeating: "x", count: 200))
        #expect(long.lines.count == 2)
        #expect(long.lines[1] == String(repeating: "x", count: 200))
        #expect(String(long.highlightedLines[1].characters) == long.lines[1])
    }

    @Test func highlightsTokensWithoutChangingSourceOrConfusingQuotedComments() {
        let source = "  name: \"CI # not a comment\" # comment"
        let styled = YAMLSyntaxHighlighting.highlight(source)
        #expect(String(styled.characters) == source)
        #expect(styled.runs.contains { $0.foregroundColor == RunnirTheme.syntaxKey })
        #expect(styled.runs.contains { $0.foregroundColor == RunnirTheme.syntaxString })
        #expect(styled.runs.contains { $0.foregroundColor == RunnirTheme.mutedForeground })
        let literal = YAMLSyntaxHighlighting.highlight("enabled: true\n")
        #expect(literal.runs.contains { $0.foregroundColor == RunnirTheme.syntaxLiteral })
        #expect(String(YAMLSyntaxHighlighting.highlight("title: 'Привет 👋'").characters) == "title: 'Привет 👋'")
    }

    @Test func preservesIndentationBlankLinesAndUpdatesOnSelection() {
        let model = WorkspaceFilesModel()
        model.source = "  steps:\n\n    - run: echo hello\n"
        #expect(model.sourceLayout.lines == ["  steps:", "", "    - run: echo hello", ""])
        model.source = ""
        #expect(model.sourceLayout.lines == [""])
        #expect(model.sourceLayout.highlightedLines.count == 1)
    }

    @Test func gutterAccommodatesLargeLineNumbers() {
        let layout = CodePreviewLayout(source: String(repeating: "\n", count: 9999))
        #expect(layout.lines.count == 10000)
        #expect(layout.gutterWidth > 28)
    }
}

@MainActor
struct ThemeTokenTests {
    @Test func everyTokenResolvesForBothAppearances() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            for token in RunnirColorToken.allCases {
                let expected = (name == .darkAqua ? token.palette.dark : token.palette.light).nsColor
                #expect(token.resolved(for: appearance) == expected)
            }
        }
    }

    @Test func keepsPenPaletteAndUsesDistinctButtonForegrounds() {
        #expect(RunnirColorToken.background.palette.dark.rawValue == 0x181B20)
        #expect(RunnirColorToken.primary.palette.dark.rawValue == 0x7C9CFF)
        #expect(RunnirColorToken.primaryForeground.palette.light == .white)
        #expect(RunnirColorToken.primaryForeground.palette.dark == .neutral950)
    }

    @Test func bodyButtonsAndStatusTokensHaveReadableContrast() {
        for dark in [false, true] {
            func value(_ token: RunnirColorToken) -> RunnirPalette {
                dark ? token.palette.dark : token.palette.light
            }
            for token in [RunnirColorToken.foreground, .secondaryForeground, .success, .warning, .destructive, .info] {
                #expect(contrast(value(token), value(.background)) >= 4.5)
            }
            #expect(contrast(value(.primaryForeground), value(.primary)) >= 4.5)
            #expect(contrast(value(.secondaryContent), value(.secondary)) >= 4.5)
        }
    }

    private func contrast(_ first: RunnirPalette, _ second: RunnirPalette) -> Double {
        func luminance(_ color: RunnirPalette) -> Double {
            let channels = [16, 8, 0].map { shift -> Double in
                let value = Double((color.rawValue >> shift) & 255) / 255
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
        }
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

struct DesktopStateTests {
    @Test func sidebarMatchesPenWithoutRemovingLegacyDestinations() {
        #expect(AppSection.sidebarSections == [.dashboard, .workflows, .runs, .workspace])
        #expect(AppSection.dashboard.title == "Overview")
        #expect(AppSection.allCases.contains(.repositories))
        #expect(AppSection.allCases.contains(.artifacts))
    }

    @Test func manualClosePersistsWithoutResurrectingOnReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileDesktopStateStore(directory: directory)
        let workspace = WorkspaceRecord(id: UUID(), path: "/test/repo", name: "repo", bookmark: Data(), lastOpenedAt: Date())
        let first = WorkspaceWindowRecord(id: UUID(), workspaceID: workspace.id)
        let second = WorkspaceWindowRecord(id: UUID(), workspaceID: workspace.id, section: .workspace)
        var state = DesktopSnapshot(workspaces: [workspace], windows: [first, second])
        try store.save(state)
        state.closeWindow(first.id)
        try store.save(state)
        let reloaded = try store.load()
        #expect(reloaded.windows == [second])
        #expect(reloaded.workspaces == [workspace])
        state.closeWindow(second.id)
        try store.save(state)
        #expect(try store.load().windows.isEmpty)
        #expect(try store.load().workspaces.count == 1)
    }

    @Test func reassociationDoesNotChangeOtherWindow() throws {
        let a = WorkspaceRecord(id: UUID(), path: "/a", name: "a", bookmark: Data(), lastOpenedAt: Date())
        let b = WorkspaceRecord(id: UUID(), path: "/b", name: "b", bookmark: Data(), lastOpenedAt: Date())
        let first = WorkspaceWindowRecord(id: UUID(), workspaceID: a.id, section: .workspace)
        let second = WorkspaceWindowRecord(id: UUID(), workspaceID: a.id, section: .runs)
        var state = DesktopSnapshot(workspaces: [a, b], windows: [first, second])
        state.associate(windowID: first.id, workspaceID: b.id)
        #expect(state.windows[0].id == first.id)
        #expect(state.windows[0].workspaceID == b.id)
        #expect(state.windows[0].section == .dashboard)
        #expect(state.windows[1] == second)
        try state.validate()
    }

    @Test func invalidUpdateDoesNotReplaceCommittedState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileDesktopStateStore(directory: directory)
        try store.save(DesktopSnapshot())
        let invalid = DesktopSnapshot(windows: [WorkspaceWindowRecord(id: UUID(), workspaceID: UUID())])
        #expect(throws: (any Error).self) { try store.save(invalid) }
        #expect(try store.load() == DesktopSnapshot())
    }

    @Test func unknownSchemaAndCorruptStateAreNotSilentlyReset() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileDesktopStateStore(directory: directory)
        var invalid = DesktopSnapshot()
        invalid.version = 99
        #expect(throws: (any Error).self) { try store.save(invalid) }
        try store.save(DesktopSnapshot())
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: store.stateURL)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(try Data(contentsOf: store.stateURL) == corrupt)
    }

    @Test func detectsDuplicateIdentitiesAndInvalidGeometry() {
        let workspace = WorkspaceRecord(id: UUID(), path: "/a", name: "a", bookmark: Data(), lastOpenedAt: Date())
        #expect(throws: (any Error).self) { try DesktopSnapshot(workspaces: [workspace, workspace]).validate() }
        let window = WorkspaceWindowRecord(id: UUID(), workspaceID: workspace.id,
            frame: WindowGeometry(x: 0, y: 0, width: -1, height: 800))
        #expect(throws: (any Error).self) { try DesktopSnapshot(workspaces: [workspace], windows: [window]).validate() }
    }
}

struct RepositoryReaderTests {
    @Test func readsOnlyWorkflowFilesWithoutCreatingConfig() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(".github/workflows")
        try Data("name: Build\non: push\n".utf8).write(to: directory.appendingPathComponent("build.yml"))
        try Data("ignored".utf8).write(to: directory.appendingPathComponent("notes.txt"))
        let reader = RepositoryReader(root: root)
        #expect(try RepositoryReader.canonicalRepository(root).path == root.path)
        let files = try reader.workflows()
        #expect(files.map(\.name) == ["build.yml"])
        #expect(try reader.source(for: files[0]).contains("Build"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".runnir").path))
    }

    @Test func rejectsTraversalAndSymlinkEscape() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = RepositoryReader(root: root)
        #expect(throws: (any Error).self) { try reader.scopedURL("../private.txt") }
        #expect(throws: (any Error).self) { try reader.scopedURL("/etc/passwd") }
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(".github/workflows/escape.yml").path,
                                                   withDestinationPath: "/etc/passwd")
        #expect(throws: (any Error).self) { try reader.workflows() }
    }

    @Test func boundsSourceSize() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = LocalWorkflowFile(relativePath: ".github/workflows/large.yaml")
        try Data(repeating: 65, count: 512 * 1024 + 1).write(to: root.appendingPathComponent(file.relativePath))
        #expect(throws: (any Error).self) { try RepositoryReader(root: root).source(for: file) }
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".github/workflows"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: false)
        return root
    }
}
