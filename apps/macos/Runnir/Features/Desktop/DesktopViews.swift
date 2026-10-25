import SwiftUI
import AppKit
import Observation

struct BrandLogo: View {
    @Environment(\.colorScheme) private var scheme
    var markOnly = false
    var height: CGFloat = 32
    var width: CGFloat? = nil
    var wordmarkOnly = false

    /// Decoded once per variant instead of on every redraw.
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor private static func image(named name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "assets"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache[name] = image
        return image
    }

    var body: some View {
        let name = (markOnly ? "logo-mark-" : wordmarkOnly ? "logo-wordmark-" : "logo-horizontal-") + (scheme == .dark ? "light" : "dark")
        if let image = Self.image(named: name) {
            Image(nsImage: image).resizable().scaledToFit().frame(width: width, height: height).accessibilityLabel("Runnir")
        } else {
            Text("Runnir").font(.title2.weight(.semibold))
        }
    }
}

struct StartupSplashView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false
    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 57)
            BrandLogo(markOnly: true, height: 74, width: 76)
            BrandLogo(height: 31, width: 124, wordmarkOnly: true).padding(.top, 10)
            VStack(spacing: 10) {
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 2).fill(RunnirTheme.border)
                    RoundedRectangle(cornerRadius: 2).fill(RunnirTheme.primary).frame(width: 90)
                        .offset(x: animate ? proxy.size.width - 90 : 0)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: animate)
                }.frame(width: 300, height: 3).accessibilityLabel("Loading workspaces")
                Text("Loading workspaces...").font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
            }.padding(.top, 22)
            Spacer()
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(RunnirTheme.mutedForeground).padding(.bottom, 13)
        }
        .frame(width: 480, height: 280)
        .background(RunnirTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onAppear { animate = true }
    }
}

/// Runnir's public repository, as an icon button with the GitHub mark
/// (Primer Octicons, MIT).
struct ProjectLink: View {
    nonisolated static let url = URL(string: "https://github.com/dil-eight/runnir")!
    @Environment(\.openURL) private var openURL
    @State private var hovering = false

    var body: some View {
        Button { openURL(Self.url) } label: {
            Image("GitHubMark").resizable().scaledToFit().frame(width: 15, height: 15)
                .foregroundStyle(hovering ? RunnirTheme.foreground : RunnirTheme.secondaryForeground)
                .frame(width: 28, height: 28)
                .background(hovering ? RunnirTheme.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.hit)
        .onHover { hovering = $0 }
        .help("Open Runnir on GitHub")
        .accessibilityLabel("Open Runnir on GitHub")
    }
}

/// A workspace's first letter on a color taken from its id, like an IDE's
/// project badge; the same workspace keeps its color across launches.
struct WorkspaceBadge: View {
    let name: String
    let id: UUID
    var size: CGFloat = 18

    nonisolated static let palette: [Color] = [RunnirTheme.primary, RunnirTheme.info, RunnirTheme.success, RunnirTheme.destructive, RunnirTheme.syntaxKey]

    nonisolated static func initial(_ name: String) -> String {
        guard let first = name.first else { return "?" }
        return String(first).uppercased()
    }

    /// An index into `palette` from the id's first byte.
    nonisolated static func colorIndex(_ id: UUID) -> Int { Int(id.uuid.0) % palette.count }

    var body: some View {
        Text(Self.initial(name))
            .font(.system(size: size * 0.56, weight: .bold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Self.palette[Self.colorIndex(id)], in: RoundedRectangle(cornerRadius: size * 0.24))
            .accessibilityHidden(true)
    }
}

struct WorkspaceManagerView: View {
    @Bindable var desktop: DesktopCoordinator
    @State private var tab: ManagerTab = .workspaces

    enum ManagerTab: Hashable { case workspaces, github }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                BrandLogo(height: 51, width: 140)
                Spacer()
                ProjectLink().buttonStyle(.hit)
                if !desktop.snapshot.workspaces.isEmpty {
                    Button { desktop.importRepository() } label: {
                        Label("Import Repository...", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(DesignButtonStyle(primary: true))
                    .disabled(desktop.persistenceBlocked)
                }
            }
            .frame(height: 51).padding(.bottom, 16)

            HStack(spacing: 4) {
                Button("Workspaces") { tab = .workspaces }.handPointer().buttonStyle(WorkflowTabStyle(selected: tab == .workspaces))
                Button("GitHub") { tab = .github }.handPointer().buttonStyle(WorkflowTabStyle(selected: tab == .github))
                    .accessibilityIdentifier("manager-github-tab")
                Spacer()
            }.padding(.bottom, 14)

            if let message = desktop.message {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(RunnirTheme.warning)
                    Text(message).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    if desktop.persistenceBlocked {
                        Button("Back Up and Reset...") { desktop.resetUnreadableSession() }
                    } else {
                        Button { desktop.message = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.hit).help("Dismiss message")
                    }
                }
                .padding(12).background(RunnirTheme.surface, in: RoundedRectangle(cornerRadius: 6))
                .padding(.bottom, 16)
            }

            if tab == .github {
                GitHubRepositoriesView(desktop: desktop)
            } else if desktop.snapshot.workspaces.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "folder").font(.system(size: 26, weight: .light))
                        .foregroundStyle(RunnirTheme.primary).frame(width: 56, height: 56).background(RunnirTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                    Text("Import a repository to begin").font(.system(size: 18, weight: .semibold))
                    Text("Choose a local Git working tree. You can connect GitHub later.")
                        .font(.system(size: 13)).foregroundStyle(RunnirTheme.secondaryForeground).multilineTextAlignment(.center).frame(maxWidth: 420)
                    Button { desktop.importRepository() } label: {
                        Label("Import Repository...", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(DesignButtonStyle(primary: true))
                    .disabled(desktop.persistenceBlocked)
                    .accessibilityIdentifier("import-repository")
                    Label("No repository files are changed when you import.", systemImage: "lock")
                        .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack {
                    Text("RECENT WORKSPACES").font(.system(size: 11, weight: .medium)).foregroundStyle(RunnirTheme.secondaryForeground)
                    Spacer()
                }.padding(.horizontal, 12).padding(.bottom, 8)
                DesignDivider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(desktop.snapshot.workspaces.sorted { $0.lastOpenedAt > $1.lastOpenedAt }) { workspace in
                            WorkspaceRegistryRow(workspace: workspace, desktop: desktop)
                            DesignDivider()
                        }
                    }
                }.frame(height: CGFloat(min(desktop.snapshot.workspaces.count, 6)) * 63)
                Label("Closing a window does not remove its workspace.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(RunnirTheme.secondaryForeground).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 16)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 48).padding(.top, 38).padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RunnirTheme.background)
        .tint(RunnirTheme.primary)
        .ignoresSafeArea()
        .settingsOverlay(desktop: desktop, windowID: DesktopCoordinator.managerWindowID)
    }
}

private struct WorkspaceRegistryRow: View {
    let workspace: WorkspaceRecord
    let desktop: DesktopCoordinator
    var body: some View {
        let count = desktop.openCount(workspace.id)
        HStack(spacing: 14) {
            Image(systemName: "folder").font(.system(size: 18)).frame(width: 20).foregroundStyle(RunnirTheme.secondaryForeground)
            VStack(alignment: .leading, spacing: 4) {
                Text(workspace.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text(workspace.path).font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground).lineLimit(1).truncationMode(.middle)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if count > 0 {
                Label("Open · \(count) \(count == 1 ? "window" : "windows")", systemImage: "macwindow")
                    .font(.system(size: 12)).foregroundStyle(RunnirTheme.success).frame(width: 170, alignment: .leading)
                Button("Focus") { desktop.focus(workspace.id) }
            } else {
                Label("Registered", systemImage: "folder").font(.system(size: 12))
                    .foregroundStyle(RunnirTheme.secondaryForeground).frame(width: 170, alignment: .leading)
            }
            if count != 1 {
                Button(count > 0 ? "New Window" : "Open") { desktop.openRegistered(workspace) }
                    .accessibilityIdentifier("open-workspace-\(workspace.id)")
            }
            Menu {
                Button("Open New Window") { desktop.openRegistered(workspace) }
                Button("Locate / Grant Access...") { desktop.importRepository(relinkID: workspace.id) }
                Button("Remove Registration", role: .destructive) { desktop.removeRegistration(workspace) }.disabled(count > 0)
                    .help("Forget this workspace in Runnir and delete its saved activity and local run history on this Mac. The repository's files stay.")
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.button).buttonStyle(.plain).pointerStyle(.link).menuIndicator(.hidden).fixedSize().help("Workspace actions")
        }
        .buttonStyle(DesignButtonStyle()).padding(.horizontal, 12).frame(height: 62)
    }
}

enum YAMLSyntaxHighlighting {
    enum Token: CaseIterable {
        case comment, string, key, literal

        var colorToken: RunnirColorToken {
            switch self {
            case .comment: .mutedForeground
            case .string: .syntaxString
            case .key: .syntaxKey
            case .literal: .syntaxLiteral
            }
        }
    }

    private static let expression = try? NSRegularExpression(pattern:
        #"\G(?:(?<comment>(?<!\S)[#].*$)|(?<string>"(?:\\.|[^"\\])*"|'(?:''|[^'])*')|(?<key>[A-Za-z_][A-Za-z0-9_.-]*(?=\s*:(?:\s|$)))|(?<literal>(?<![\w.-])(?:true|false|null|~|[-+]?\d+(?:\.\d+)?)(?![\w.-]))|[^\s]+|\s+)"#)

    /// The colored tokens of one line, as UTF-16 ranges within it.
    static func tokens(in line: String) -> [(range: NSRange, token: Token)] {
        guard let expression else { return [] }
        var tokens: [(NSRange, Token)] = []
        for match in expression.matches(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
            for token in Token.allCases {
                let range = match.range(withName: "\(token)")
                if range.location != NSNotFound, range.length > 0 { tokens.append((range, token)) }
            }
        }
        return tokens
    }

    static func highlight(_ line: String) -> AttributedString {
        var result = AttributedString(line)
        for (range, token) in tokens(in: line) {
            guard let swiftRange = Range(range, in: line),
                  let start = AttributedString.Index(swiftRange.lowerBound, within: result),
                  let end = AttributedString.Index(swiftRange.upperBound, within: result) else { continue }
            result[start..<end].foregroundColor = token.colorToken.color
        }
        return result
    }
}

/// The workflow files of one window and the one open in its editor: the
/// text being edited, the version saved on disk it started from, and what
/// actionlint found in the saved files.
@MainActor
@Observable
final class WorkspaceFilesModel {
    enum DiskChange: Equatable {
        /// A save was refused: the file changed on disk after it was loaded.
        case conflict
        /// A reload found the file changed on disk while it had edits here.
        case changedOnDisk
    }

    var files: [LocalWorkflowFile] = []
    var selected: LocalWorkflowFile?
    /// The text in the editor. Once it moves away from the text an edit was
    /// made for, the edit is done (applied, or typed over), so an editor shown
    /// again later does not apply it a second time after an undo.
    var source = "" {
        didSet { if let pendingEdit, source != pendingEdit.before { self.pendingEdit = nil } }
    }
    /// The file as loaded from or last saved to disk.
    private(set) var savedSource = ""
    /// SHA-256 of `savedSource`'s bytes, which a save must still find on disk.
    private(set) var savedDigest: String?
    private(set) var isWritable = true
    private(set) var isSaving = false
    /// The open file is being read; a rename waits for it.
    private(set) var isLoadingSource = false
    private(set) var saveError: String?
    private(set) var diskChange: DiskChange?
    var isLoading = false
    var error: String?
    private var sourceTask: Task<Void, Never>?
    /// Changes whenever another file or version is loaded, so a save that
    /// finishes afterwards does not overwrite what is shown now.
    private var loadGeneration = 0
    /// An edit the editor applies as one undoable change (the concurrency block).
    private(set) var pendingEdit: CodeEditorEdit?
    /// Why the last suggested edit was not made, shown over the editor.
    private(set) var editNotice: String?
    private var editCount = 0

    /// The editor holds changes that are not on disk.
    var isDirty: Bool { selected != nil && savedDigest != nil && source != savedSource }

    /// The last actionlint report from the Core, for every workflow file.
    private(set) var validation: CoreValidationReport?
    private(set) var validationError: String?
    private(set) var isValidating = false
    /// A line chosen from the diagnostics, highlighted in the source.
    private(set) var highlightedLine: Int?
    /// Changes on every choice, so choosing the same line again scrolls back to it.
    private(set) var revealCount = 0

    func reveal(line: Int) {
        guard line > 0 else { return }
        highlightedLine = line
        revealCount += 1
    }
    /// A check was asked for while one was running (after a Refresh, say);
    /// it runs once more, so the report matches the files on disk.
    private var validationPending = false

    func validate(hub: CoreHub, workspaceID: UUID) async {
        guard !isValidating else {
            validationPending = true
            return
        }
        isValidating = true
        defer { isValidating = false }
        repeat {
            validationPending = false
            switch await hub.validateWorkflows(workspaceID: workspaceID) {
            case .report(let report):
                validation = report
                validationError = nil
            case .failed(let message):
                validationError = message
            }
        } while validationPending
    }

    func validation(for file: LocalWorkflowFile) -> CoreWorkflowValidation? {
        validation?.validation(for: file.relativePath)
    }

    /// Problems found in a file, nil while it has not been checked.
    func problemCount(for file: LocalWorkflowFile) -> Int? {
        guard let result = validation(for: file) else { return nil }
        return result.diagnostics.count + (result.problem == nil ? 0 : 1)
    }

    /// Lists the files again and reloads the open one when it changed on
    /// disk, unless it has edits: then only the change is noted, and the
    /// edits stay.
    func load(_ reader: RepositoryReader) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            files = try await Task.detached { try reader.workflows() }.value
            error = nil
            if let selected, files.contains(selected) {
                if isDirty { await noticeDiskChange(selected, reader: reader) } else { await reloadIfChanged(selected, reader: reader) }
            } else if !isDirty {
                selected = files.first
                if let selected { select(selected, reader: reader) }
            }
        } catch { self.error = "Workflow files could not be read. Check access and keep files inside this repository." }
    }

    /// Opens a file in the editor; edits to the previous one are dropped, so
    /// callers ask first (see `isDirty`).
    func select(_ file: LocalWorkflowFile, reader: RepositoryReader) {
        if selected != file { highlightedLine = nil }
        loadGeneration += 1
        selected = file
        source = ""
        savedSource = ""
        savedDigest = nil
        diskChange = nil
        saveError = nil
        pendingEdit = nil
        editNotice = nil
        sourceTask?.cancel()
        isLoadingSource = true
        sourceTask = Task {
            defer { if !Task.isCancelled { isLoadingSource = false } }
            do {
                let (loaded, writable) = try await Task.detached {
                    (try reader.loadSource(for: file), reader.isWritable(file))
                }.value
                guard !Task.isCancelled else { return }
                savedSource = loaded.text
                savedDigest = loaded.sha256
                source = loaded.text
                isWritable = writable
                error = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "This workflow is unreadable, outside the repository, or exceeds the 512 KiB editor limit."
            }
        }
    }

    /// Drops the edits and loads the file as it is on disk.
    func reloadFromDisk(reader: RepositoryReader) {
        guard let selected else { return }
        select(selected, reader: reader)
    }

    /// Waits until `file` is loaded in the editor, through loads started
    /// meanwhile; false when another file is open or it could not be read.
    func waitUntilLoaded(_ file: LocalWorkflowFile) async -> Bool {
        while let task = sourceTask {
            await task.value
            if sourceTask == task { break }
        }
        return selected == file && savedDigest != nil
    }

    /// Asks the Core for the open file's text with the concurrency block and
    /// hands it to the editor as one undoable edit. Nothing is saved.
    func insertConcurrency(hub: CoreHub, workspaceID: UUID) async {
        guard selected != nil, savedDigest != nil else { return }
        guard isWritable else {
            editNotice = "This workflow file is read-only, so the concurrency block can't be added."
            return
        }
        let before = source
        switch await hub.insertWorkflowConcurrency(workspaceID: workspaceID, content: before) {
        case .inserted(let content, let firstLine, _)?:
            // Typing or a reload while the Core answered: the answer is for older text.
            guard source == before else {
                editNotice = "The file changed while the block was prepared, so it was not added. Try again."
                return
            }
            guard let edit = CodeEditorEdit(from: before, to: content, id: editCount + 1) else { return }
            editCount += 1
            editNotice = nil
            pendingEdit = edit
            reveal(line: firstLine)
        case .refused(let refusal)?:
            editNotice = refusal.message
        case nil:
            editNotice = "Runnir Core could not add the block. Try again once it is ready."
        }
    }

    func dismissEditNotice() { editNotice = nil }

    /// Saves the editor's text through the Core. A file that changed on disk
    /// since it was loaded is only replaced with `overwrite`.
    @discardableResult
    func save(hub: CoreHub, workspaceID: UUID, overwrite: Bool = false) async -> Bool {
        guard let file = selected, let base = savedDigest, isDirty || overwrite, !isSaving else { return !isDirty }
        isSaving = true
        defer { isSaving = false }
        let content = source
        let generation = loadGeneration
        let outcome = await hub.saveWorkflowFile(workspaceID: workspaceID, workflowID: file.relativePath, content: content,
                                                 baseSHA256: base, overwrite: overwrite)
        // Another file, or the disk version, was loaded while saving.
        guard generation == loadGeneration else { return false }
        switch outcome {
        case .saved(let digest):
            // Typing during the save stays an edit on top of what was saved.
            savedSource = content
            savedDigest = digest
            diskChange = nil
            saveError = nil
            return true
        case .conflict:
            diskChange = .conflict
            saveError = nil
            return false
        case .failed(let message):
            saveError = message
            return false
        }
    }

    /// Adds a workflow file through the Core and lists the files again; the
    /// caller opens it (asking first when the open file has edits).
    func create(fileName: String, hub: CoreHub, workspaceID: UUID, reader: RepositoryReader) async -> CoreHub.WorkflowFileChange {
        let outcome = await hub.createWorkflowFile(workspaceID: workspaceID, fileName: fileName)
        if case .done = outcome { await relist(reader) }
        return outcome
    }

    /// Renames the open file through the Core. The editor keeps its text,
    /// edits included: only the name changed, so the version it started
    /// from is still the one on disk.
    func renameSelected(to fileName: String, hub: CoreHub, workspaceID: UUID, reader: RepositoryReader) async -> CoreHub.WorkflowFileChange {
        guard let file = selected, !isLoadingSource, !isSaving else { return .failed("Wait until the file has loaded and saved, then rename it.") }
        let outcome = await hub.renameWorkflowFile(workspaceID: workspaceID, workflowID: file.relativePath, newFileName: fileName)
        if case .done(let id) = outcome {
            await relist(reader)
            if selected == file {
                let renamed = LocalWorkflowFile(relativePath: id)
                // A file that could not be read is tried again under its new name.
                if savedDigest == nil { select(renamed, reader: reader) } else { selected = renamed }
            }
        }
        return outcome
    }

    private func relist(_ reader: RepositoryReader) async {
        do {
            files = try await Task.detached { try reader.workflows() }.value
            error = nil
        } catch { self.error = "Workflow files could not be read. Check access and keep files inside this repository." }
    }

    /// Loads the open, unedited file again only when its bytes on disk
    /// changed, so a check that reloads files leaves an edit being prepared
    /// for it (the concurrency block) alone.
    private func reloadIfChanged(_ file: LocalWorkflowFile, reader: RepositoryReader) async {
        // A load in progress reads the file as it is now.
        guard !isLoadingSource else { return }
        if savedDigest != nil {
            let read = try? await Task.detached(operation: { (try reader.loadSource(for: file), reader.isWritable(file)) }).value
            // Another file, edits or a new load since: that state wins.
            guard selected == file, !isDirty, !isLoadingSource else { return }
            if let read, read.0.sha256 == savedDigest {
                isWritable = read.1
                return
            }
        }
        select(file, reader: reader)
    }

    private func noticeDiskChange(_ file: LocalWorkflowFile, reader: RepositoryReader) async {
        guard let loaded = try? await Task.detached(operation: { try reader.loadSource(for: file) }).value else { return }
        if loaded.sha256 != savedDigest, diskChange == nil { diskChange = .changedOnDisk }
    }
}

struct DesktopWorkspaceView: View {
    @Environment(AppState.self) private var state
    let desktop: DesktopCoordinator
    let workspace: WorkspaceRecord
    let windowID: UUID
    let reader: RepositoryReader?
    private var files: WorkspaceFilesModel { state.files }
    @State private var fileNameRequest: WorkflowFileNameRequest?
    /// What stops starting a workflow here, shown as an alert.
    @State private var accessHelp: GitHubAccessHelp?
    /// A file created from the name sheet, opened once the sheet is gone so
    /// a question about unsaved edits does not sit on top of it.
    @State private var openAfterSheet: String?
    @State private var hoveringSwitcher = false
    @State private var reportingBug = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            DesignDivider(vertical: true)
            VStack(spacing: 0) {
                toolbar
                DesignDivider()
                if reader == nil {
                    ContentUnavailableView {
                        Label("Locate this repository", systemImage: "folder.badge.questionmark")
                    } description: {
                        Text("The folder is missing or its access needs to be renewed. Your saved workspace has been retained.")
                    } actions: {
                        Button("Locate / Grant Access...") { desktop.importRepository(relinkID: workspace.id, reuseWindowID: windowID) }
                    }
                    // Fills the column so the toolbar stays at the top.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    coreBanner
                    content
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(RunnirTheme.background).foregroundStyle(RunnirTheme.foreground).tint(RunnirTheme.primary)
        .overlay(alignment: .topLeading) { switcherPanel }
        .ignoresSafeArea()
        .settingsOverlay(desktop: desktop, windowID: windowID)
        .sheet(isPresented: $reportingBug) {
            BugReportSheet(draft: BugReportDraft.current(coreVersion: desktop.core?.status.coreVersion))
        }
        .task { if let reader { await files.load(reader) } }
        .onChange(of: state.selectedSection) { _, value in desktop.selectSection(value, windowID: windowID) }
        .onChange(of: state.runsMode) { _, value in desktop.selectRunsMode(value, windowID: windowID) }
        // Once the Core has opened the working tree: its origin's GitHub
        // repository key, or none ("") when the origin is on no GitHub server.
        .onChange(of: session?.phase == .ready ? (session?.githubRef?.key ?? "") : nil, initial: true) { _, value in
            guard let value else { return }
            desktop.noteGitHubRepository(value.isEmpty ? nil : value, workspaceID: workspace.id)
        }
        .sheet(item: Binding(get: { state.runWorkflowRequest }, set: { state.runWorkflowRequest = $0 })) { request in
            if let session, let hub = desktop.core {
                RunWorkflowSheet(model: DispatchFormModel(workspaceID: workspace.id, hub: hub, workflows: session.remoteWorkflows,
                                                          workflowID: request.workflowID, currentBranch: session.branch,
                                                          presets: desktop.presets, presetID: request.presetID),
                                 github: desktop.github) { run in
                    state.selectedRunID = run.id
                    state.selectedSection = .runs
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    UnavailableFeature(title: "Runnir Core is not ready",
                                       detail: "Workflows can be started once the Core has opened this repository.", symbol: "hourglass")
                    HStack { Spacer(); Button("Close") { state.runWorkflowRequest = nil }.keyboardShortcut(.cancelAction) }
                        .buttonStyle(DesignButtonStyle())
                }
                .padding(20).frame(width: 420)
            }
        }
        .sheet(item: Binding(get: { state.localRunRequest }, set: { state.localRunRequest = $0 })) { request in
            if let session, let hub = desktop.core {
                LocalRunSheet(model: LocalRunReviewModel(workspaceID: workspace.id, workflowID: request.workflowID,
                                                         jobs: session.workflows.first { $0.id == request.workflowID }?.jobs ?? [],
                                                         jobID: request.jobID, hub: hub, values: desktop.localRunValues),
                              repositoryPath: session.path,
                              unsavedFile: files.isDirty && files.selected?.relativePath == request.workflowID ? files.selected?.name : nil,
                              manageValues: { state.selectedSection = .secrets }) { _ in
                    state.selectedSection = .workspace
                    state.workspaceTab = .localRun
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    UnavailableFeature(title: "Runnir Core is not ready",
                                       detail: "Local runs can be reviewed once the Core has opened this repository.", symbol: "hourglass")
                    HStack { Spacer(); Button("Close") { state.localRunRequest = nil }.keyboardShortcut(.cancelAction) }
                        .buttonStyle(DesignButtonStyle())
                }
                .padding(20).frame(width: 420)
            }
        }
        .sheet(item: $fileNameRequest, onDismiss: {
            guard let id = openAfterSheet else { return }
            openAfterSheet = nil
            open(LocalWorkflowFile(relativePath: id))
        }) { request in
            WorkflowFileNameSheet(request: request, files: files.files) { name in
                switch request {
                case .create: await createFile(named: name)
                case .rename: await renameSelected(to: name)
                }
            }
        }
        .githubAccessAlert($accessHelp, github: desktop.github)
        // What the repository allows (push, the owner's installation) is read
        // once GitHub answers, and again after a new sign-in.
        .task(id: "\(session?.githubAccess == .ok)|\(desktop.core?.credentialGeneration ?? 0)") {
            if session?.githubAccess == .ok { await desktop.core?.githubRepository(workspaceID: workspace.id) }
        }
    }

    private var session: RepositorySession? { desktop.core?.session(for: workspace.id) }

    private var canValidate: Bool { desktop.core != nil && session?.phase == .ready }

    /// Checks the files on disk and reloads the ones shown, so diagnostics
    /// and the source on screen describe the same content.
    private func validateWorkflows() {
        guard let hub = desktop.core else { return }
        if let reader { Task { await files.load(reader) } }
        Task { await files.validate(hub: hub, workspaceID: workspace.id) }
    }

    /// Opens a file in the editor, asking first, in a sheet on this window,
    /// when the open one has unsaved edits; true once that file is loaded.
    private func openAndLoad(_ file: LocalWorkflowFile) async -> Bool {
        guard let reader else { return false }
        if file != files.selected {
            if files.isDirty, let current = files.selected {
                let choice = await UnsavedChangesPrompt.ask(fileName: current.name, sheetOn: desktop.window(windowID))
                // Answered for the file that was open when asked.
                guard files.selected == current else { return false }
                switch choice {
                case .save:
                    guard await saveAndRevalidate() else { return false }
                case .discard:
                    break
                case .cancel:
                    return false
                }
            }
            files.select(file, reader: reader)
        }
        return await files.waitUntilLoaded(file)
    }

    private func open(_ file: LocalWorkflowFile) {
        Task { _ = await openAndLoad(file) }
    }

    /// Opens a workflow file in the editor with the suggested concurrency
    /// block as an unsaved edit; the user reviews, saves and commits it.
    private func addConcurrency(path: String) {
        guard let hub = desktop.core else { return }
        let file = LocalWorkflowFile(relativePath: path)
        state.selectedSection = .workspace
        state.workspaceTab = .editor
        Task {
            guard await openAndLoad(file) else { return }
            await files.insertConcurrency(hub: hub, workspaceID: workspace.id)
        }
    }

    private func askForFileName(_ request: WorkflowFileNameRequest) {
        openAfterSheet = nil
        fileNameRequest = request
    }

    /// Adds a workflow file through the Core; it opens when the sheet closes.
    private func createFile(named name: String) async -> String? {
        guard let reader, let hub = desktop.core else { return "Runnir Core is not ready. Files are created by the Core." }
        switch await files.create(fileName: name, hub: hub, workspaceID: workspace.id, reader: reader) {
        case .done(let id):
            openAfterSheet = id
            Task { await files.validate(hub: hub, workspaceID: workspace.id) }
            return nil
        case .failed(let message):
            return message
        }
    }

    /// Renames the open file; its presets, star and Overview selection follow.
    private func renameSelected(to name: String) async -> String? {
        guard let reader, let hub = desktop.core, let old = files.selected else { return "Runnir Core is not ready. Files are renamed by the Core." }
        switch await files.renameSelected(to: name, hub: hub, workspaceID: workspace.id, reader: reader) {
        case .done(let id):
            desktop.workflowRenamed(workspaceID: workspace.id, from: old.relativePath, to: id)
            if state.overviewWorkflowPath == old.relativePath { state.overviewWorkflowPath = id }
            Task { await files.validate(hub: hub, workspaceID: workspace.id) }
            return nil
        case .failed(let message):
            return message
        }
    }

    private var renameHelp: String {
        if !canValidate { return "Files are renamed by Runnir Core, which has not opened this repository yet" }
        if files.isSaving { return "Wait for the save to finish" }
        if files.isLoadingSource { return "Wait for the file to open" }
        return "Rename this workflow file; unsaved edits stay in the editor"
    }

    private func save(overwrite: Bool = false) {
        Task { await saveAndRevalidate(overwrite: overwrite) }
    }

    /// Saves the editor through the Core, then checks the saved files again.
    @discardableResult
    private func saveAndRevalidate(overwrite: Bool = false) async -> Bool {
        guard let hub = desktop.core else { return false }
        let saved = await files.save(hub: hub, workspaceID: workspace.id, overwrite: overwrite)
        if saved { await files.validate(hub: hub, workspaceID: workspace.id) }
        return saved
    }

    private var saveHelp: String {
        if !files.isWritable { return "This file is read-only" }
        if !canValidate { return "Files are saved by Runnir Core, which has not opened this repository yet" }
        if !files.isDirty { return "No unsaved changes" }
        return "Save this workflow file and check it again"
    }

    @ViewBuilder private var editorStatus: some View {
        if files.isDirty {
            Label("Edited · unsaved", systemImage: "pencil")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(RunnirTheme.warning)
                .padding(.horizontal, 8).frame(height: 22)
                .background(RunnirTheme.warning.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
        } else if files.selected != nil, !files.isWritable {
            Text("Read-only").font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
        }
    }

    private func menuTitle(_ file: LocalWorkflowFile) -> String {
        let name = desktop.favorites.isFavorite(file.relativePath, workspaceID: workspace.id) ? "★ \(file.name)" : file.name
        guard let count = files.problemCount(for: file), count > 0 else { return name }
        return "\(name)  ·  \(count) \(count == 1 ? "problem" : "problems")"
    }

    private var runWorkflowHelp: String {
        runBlocker?.title ?? "Start a workflow_dispatch workflow on GitHub"
    }

    /// What stops starting a workflow here, known before trying: no sign-in,
    /// GitHub refusing the repository, an owner's pending approval, or no
    /// write access.
    private var runBlocker: GitHubAccessHelp? {
        guard let session else { return GitHubAccessHelp.forAccess(.unavailable, repository: nil, purpose: .run) }
        guard let repository = session.githubRepository else { return GitHubAccessHelp.noRemote(originHost: session.originHost) }
        // An Enterprise server's sign-in is its token; the Core says when
        // it has none.
        let enterprise = !(session.githubServerID ?? "").isEmpty
        if !enterprise, desktop.github?.user == nil {
            return GitHubAccessHelp.forAccess(desktop.github?.signedOutAccess ?? .signedOut, repository: repository, purpose: .run)
        }
        if let access = session.githubAccess, access != .ok {
            return desktop.core?.accessHelp(access, workspaceID: workspace.id, purpose: .run, details: session.githubDetails)
                ?? GitHubAccessHelp.forAccess(access, repository: repository, purpose: .run, details: session.githubDetails)
        }
        return GitHubAccessHelp.blocker(for: .run, repository: repository, details: session.githubDetails)
    }

    /// Opens Run Workflow, or says in an alert what has to happen first.
    private func requestRun(workflowID: Int64?, presetID: UUID? = nil) {
        if let blocker = runBlocker {
            accessHelp = blocker
            return
        }
        state.runWorkflowRequest = RunWorkflowRequest(workflowID: workflowID, presetID: presetID)
    }

    private var coreSummary: String { session?.summary ?? "Working tree" }
    private var coreDetail: String { session?.detail ?? "Branch and workflows reported by Runnir Core" }

    /// Offers to restart the Core when it stopped or could not start.
    @ViewBuilder private var coreBanner: some View {
        if let core = desktop.core, core.status.needsRecovery {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(RunnirTheme.warning)
                Text(bannerText(core.status)).font(.system(size: 12))
                Spacer(minLength: 4)
                if let log = CoreProcessSupervisor.logURL, FileManager.default.fileExists(atPath: log.path) {
                    Button("Show Log") { NSWorkspace.shared.activateFileViewerSelecting([log]) }
                        .help("The Core's diagnostics for this and the previous launch")
                }
                Button("Restart Core") { Task { await core.recover() } }
            }
            .buttonStyle(DesignButtonStyle()).padding(.horizontal, 20).frame(height: 40)
            .background(RunnirTheme.warning.opacity(0.12))
            DesignDivider()
        }
    }

    private func bannerText(_ status: CoreHub.Status) -> String {
        switch status {
        case .lost: "Runnir Core stopped or stopped responding. Workflow data may be out of date."
        case .failed(let reason): "Runnir Core is not running. \(reason)"
        default: ""
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text(state.selectedSection.title).font(.system(size: 15, weight: .semibold))
            if state.selectedSection == .workspace {
                Menu {
                    ForEach(desktop.favorites.ordered(files.files, workspaceID: workspace.id, path: \.relativePath)) { file in
                        Button(menuTitle(file)) { open(file) }
                    }
                    if !files.files.isEmpty { Divider() }
                    Button("New Workflow File...") { askForFileName(.create) }
                        .disabled(!canValidate)
                        .help(canValidate ? "Add a workflow file to .github/workflows" : "Files are created by Runnir Core, which has not opened this repository yet")
                    if let file = files.selected {
                        Button("Rename \(file.name)...") { askForFileName(.rename(file)) }
                            .disabled(!canValidate || files.isSaving || files.isLoadingSource)
                            .help(renameHelp)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                        Text(files.selected?.name ?? "No workflow").lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 9))
                    }.font(.system(size: 12)).frame(maxWidth: 150)
                        .padding(.horizontal, 10).frame(height: 26)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(RunnirTheme.border))
                }.menuStyle(.button).buttonStyle(.plain).pointerStyle(.link).menuIndicator(.hidden).fixedSize().disabled(reader == nil)
                editorStatus
            }
            Spacer(minLength: 4)
            if state.selectedSection == .workspace {
                Button(files.isSaving ? "Saving..." : "Save") { save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!files.isDirty || files.isSaving || !canValidate || !files.isWritable)
                    .help(saveHelp)
                Button(files.isValidating ? "Validating..." : "Validate") { validateWorkflows() }
                    .disabled(!canValidate || files.isValidating)
                    .help(canValidate ? "Check every workflow file with actionlint, offline" : "Validation runs in Runnir Core, which has not opened this repository yet")
                localRunButtons
            } else {
                Label(coreSummary, systemImage: "arrow.triangle.branch")
                    .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                    .lineLimit(1).help(coreDetail)
                Button("Refresh") {
                    if let reader { Task { await files.load(reader) } }
                    Task {
                        await desktop.core?.refresh(workspaceID: workspace.id)
                        // Keep diagnostics in step with the files on disk.
                        if files.validation != nil { validateWorkflows() }
                    }
                }
                .disabled(reader == nil || files.isLoading || session?.isRefreshing == true).help("Refresh local workflows")
                Button { requestRun(workflowID: nil) } label: { Label("Run Workflow...", systemImage: "play") }
                    .buttonStyle(DesignButtonStyle(primary: true))
                    .disabled(session?.githubRepository == nil)
                    .help(runWorkflowHelp)
            }
            ProjectLink().buttonStyle(.hit)
        }
        .buttonStyle(DesignButtonStyle()).padding(.horizontal, 20).frame(height: 52)
    }

    private var localRun: LocalRunModel? { session?.localRun }

    @ViewBuilder private var localRunButtons: some View {
        if state.workspaceTab == .localRun, let run = localRun {
            if run.isFinished {
                Button { state.localRunRequest = LocalRunRequest(workflowID: run.plan.workflowID, jobID: run.plan.jobID.isEmpty ? nil : run.plan.jobID) } label: {
                    Label("Run Again...", systemImage: "arrow.clockwise")
                }
                .buttonStyle(DesignButtonStyle(primary: true)).disabled(!canValidate)
                .help("Review and start this run again")
            } else {
                Button(role: .destructive) { if let hub = desktop.core { Task { await run.stop(hub: hub) } } } label: {
                    Label(run.stopRequested ? "Stopping..." : "Stop", systemImage: "stop.fill")
                }
                .buttonStyle(DesignButtonStyle()).foregroundStyle(RunnirTheme.destructive).disabled(run.stopRequested)
                .help("Stop act and remove this run's containers")
            }
        } else {
            Button {
                if let file = files.selected { state.localRunRequest = LocalRunRequest(workflowID: file.relativePath, jobID: nil) }
            } label: { Label("Run Locally...", systemImage: "play") }
                .buttonStyle(DesignButtonStyle(primary: true))
                .disabled(!canValidate || files.selected == nil || localRun.map { !$0.isFinished } == true)
                .help(runLocallyHelp)
        }
    }

    private var runLocallyHelp: String {
        if localRun.map({ !$0.isFinished }) == true { return "A local run of this workspace is in progress" }
        if !canValidate { return "Local runs start in Runnir Core, which has not opened this repository yet" }
        if files.selected == nil { return "Choose a workflow file first" }
        return "Review tools, compatibility and access, then run this workflow with act"
    }

    /// Editor and Local run tabs of the Workspace section.
    @ViewBuilder private var workspaceTabs: some View {
        if let run = localRun {
            HStack(spacing: 4) {
                Button("Editor") { state.workspaceTab = .editor }.buttonStyle(WorkflowTabStyle(selected: state.workspaceTab == .editor))
                Button { state.workspaceTab = .localRun } label: {
                    HStack(spacing: 6) {
                        LocalJobIcon(state: run.isFinished ? (run.state == .succeeded ? .succeeded : run.state == .cancelled ? .cancelled : .failed) : .running)
                            .font(.system(size: 11))
                        Text("Local run")
                    }
                }.buttonStyle(WorkflowTabStyle(selected: state.workspaceTab == .localRun))
                Spacer()
            }.padding(.horizontal, 16).frame(height: 36)
            DesignDivider()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            // The title bar row: the window's buttons, then the workspace
            // switcher next to them, centered on the buttons (y = 16).
            HStack(spacing: 0) {
                Color.clear.frame(width: 64)
                workspaceSwitcherButton
                Spacer(minLength: 0)
            }
            .frame(height: 32)
            Color.clear.frame(height: 8)
            BrandLogo(height: 47, width: 128).padding(.leading, 6).padding(.top, 2).padding(.bottom, 14)
            VStack(spacing: 2) {
                ForEach(AppSection.sidebarSections) { section in
                    Button { state.selectedSection = section } label: {
                        SidebarItemLabel(title: section.title, symbol: section.symbolName, selected: state.selectedSection == section)
                    }.buttonStyle(.hit).accessibilityAddTraits(state.selectedSection == section ? .isSelected : [])
                }
            }
            Spacer()
            Group {
                if let github = desktop.github {
                    GitHubAccountRow(session: github)
                } else {
                    HStack(spacing: 10) {
                        SidebarIcon(symbol: "person.crop.circle")
                            .foregroundStyle(RunnirTheme.secondaryForeground)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("GitHub").font(.system(size: 12))
                            Text("Not connected").font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }.padding(.horizontal, 10).frame(height: 45)
            Button { reportingBug = true } label: { SidebarItemLabel(title: "Report a Bug...", symbol: "ladybug") }
                .buttonStyle(.hit)
                .help("Open a bug report for Runnir on GitHub")
                .accessibilityIdentifier("report-bug")
            Button { desktop.showSettings(in: windowID) } label: { SidebarItemLabel(title: "Settings...", symbol: "gearshape") }
                .buttonStyle(.hit)
        }
        .padding(.horizontal, 12).padding(.bottom, 14).frame(width: 220)
        .frame(maxHeight: .infinity).background(RunnirTheme.sidebar)
    }

    /// The workspace's name in the title bar; opens the switcher under it.
    private var workspaceSwitcherButton: some View {
        Button { state.showingSwitcher = true } label: {
            HStack(spacing: 6) {
                WorkspaceBadge(name: workspace.name, id: workspace.id)
                Text(workspace.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(RunnirTheme.secondaryForeground)
            }
            .padding(.horizontal, 5).frame(height: 26)
            .background(hoveringSwitcher ? RunnirTheme.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.hit)
        .onHover { hoveringSwitcher = $0 }
        .frame(maxWidth: 140, alignment: .leading)
        .help(WorkspaceSwitcher.abbreviate(workspace.path))
        .accessibilityLabel("Workspace \(workspace.name)")
        .accessibilityHint("Switches to another workspace")
        .accessibilityIdentifier("workspace-switcher")
        .contextMenu {
            Button("Open Quickly...") { state.showingSwitcher = true }
            Button("Workspace Manager...") { desktop.showManager() }
        }
    }

    /// The switcher drops down from the title, left-aligned with it as in
    /// JetBrains IDEs; a click outside closes it.
    @ViewBuilder private var switcherPanel: some View {
        if state.showingSwitcher {
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001)
                    // No hand pointer: a click outside the switcher closes it.
                    .onTapGesture { state.showingSwitcher = false }
                WorkspaceSwitcherView(desktop: desktop, currentWorkspaceID: workspace.id, windowID: windowID,
                                      close: { state.showingSwitcher = false })
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(RunnirTheme.border))
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
                    .padding(.leading, 82).padding(.top, 34)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch state.selectedSection {
        case .dashboard, .repositories, .artifacts:
            WorkspaceOverview(workspaceID: workspace.id, session: session, hub: desktop.core, github: desktop.github, files: files,
                              favorites: desktop.favorites, presets: desktop.presets,
                              openRun: { run in
                                  state.selectedRunID = run.id
                                  state.selectedSection = .runs
                              },
                              openRuns: { state.selectedSection = .runs },
                              openFile: { file in
                                  state.selectedSection = .workspace
                                  state.workspaceTab = .editor
                                  open(file)
                              },
                              runWorkflow: { workflowID, presetID in requestRun(workflowID: workflowID, presetID: presetID) },
                              selectedPath: Binding(get: { state.overviewWorkflowPath }, set: { state.overviewWorkflowPath = $0 }))
        case .workspace:
            VStack(spacing: 0) {
                workspaceTabs
                if state.workspaceTab == .localRun, let run = localRun {
                    LocalRunView(run: run)
                } else {
                    LocalWorkflowBrowser(model: files, canValidate: canValidate, validate: validateWorkflows,
                                         reload: { if let reader { files.reloadFromDisk(reader: reader) } },
                                         saveAnyway: { save(overwrite: true) },
                                         newFile: { askForFileName(.create) })
                        .task(id: canValidate) {
                            // The first visit checks the files; later ones keep the last report.
                            if canValidate, files.validation == nil, files.validationError == nil { validateWorkflows() }
                        }
                }
            }
        case .workflows:
            if let session, let hub = desktop.core {
                WorkspaceWorkflowsView(session: session, hub: hub, github: desktop.github, favorites: desktop.favorites, showRun: { run in
                    state.selectedRunID = run.id
                    state.selectedSection = .runs
                }, runWorkflow: { workflow in requestRun(workflowID: workflow.id) })
            } else {
                coreUnavailable
            }
        case .secrets:
            if let session, let hub = desktop.core {
                WorkspaceValuesView(model: state.values, workspaceID: workspace.id, session: session, hub: hub, store: desktop.localRunValues)
            } else {
                coreUnavailable
            }
        case .runs:
            if let session, let hub = desktop.core {
                WorkspaceRunsView(session: session, hub: hub, github: desktop.github,
                                  selectedRunID: Binding(get: { state.selectedRunID }, set: { state.selectedRunID = $0 }),
                                  mode: Binding(get: { state.runsMode }, set: { state.runsMode = $0 }),
                                  dismissals: desktop.hintDismissals,
                                  addConcurrency: { path in addConcurrency(path: path) })
            } else {
                coreUnavailable
            }
        }
    }

    /// Shown in a GitHub section while no Core session exists for this window.
    private var coreUnavailable: some View {
        UnavailableFeature(title: "Waiting for Runnir Core",
                           detail: "GitHub workflows and runs appear here once the Core has opened this repository.",
                           symbol: "hourglass")
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct LocalWorkflowBrowser: View {
    @Bindable var model: WorkspaceFilesModel
    let canValidate: Bool
    let validate: () -> Void
    let reload: () -> Void
    let saveAnyway: () -> Void
    let newFile: () -> Void

    var body: some View {
        HSplitView {
                sourcePanel.frame(minWidth: 240, idealWidth: 380, maxWidth: .infinity)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionLabel(title: "PIPELINE PREVIEW")
                            Text(model.selected?.relativePath ?? "No workflow selected")
                                .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground).lineLimit(2)
                            UnavailableFeature(title: "Preview unavailable", detail: "Workflow analysis is not implemented yet.", symbol: "point.3.connected.trianglepath.dotted")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "shippingbox").foregroundStyle(RunnirTheme.secondaryForeground)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Run this workflow locally").font(.system(size: 12, weight: .medium))
                                Text("Run Locally checks act and your container engine, shows what the run can access, and starts nothing until you confirm.")
                                    .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }.padding(14).background(RunnirTheme.surface, in: RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 22) {
                                Text(diagnosticsTitle).foregroundStyle(RunnirTheme.foreground)
                                Text("Suggestions · later").foregroundStyle(RunnirTheme.mutedForeground)
                            }.font(.system(size: 13)).padding(.horizontal, 12)
                            DesignDivider()
                            DiagnosticsPanel(model: model, canValidate: canValidate, validate: validate).padding(.horizontal, 12)
                        }
                    }.padding(.horizontal, 24).padding(.vertical, 20)
                }.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var diagnosticsTitle: String {
        guard let file = model.selected, let count = model.problemCount(for: file), count > 0 else { return "Diagnostics" }
        return "Diagnostics  \(count)"
    }

    private var sourcePanel: some View {
        let flagged = Set(model.selected.flatMap { model.validation(for: $0)?.diagnostics.map(\.line) } ?? [])
        return VStack(spacing: 0) {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).padding(20)
                Spacer(minLength: 0)
            } else if model.selected == nil {
                VStack(alignment: .leading, spacing: 12) {
                    UnavailableFeature(title: "No workflows", detail: "No YAML files in .github/workflows.", symbol: "doc.text")
                    if !model.isLoading {
                        Button("New Workflow File...", action: newFile).buttonStyle(DesignButtonStyle()).disabled(!canValidate)
                            .help(canValidate ? "Add a workflow file with one job you can run by hand" : "Files are created by Runnir Core, which has not opened this repository yet")
                    }
                }.padding(20)
                Spacer(minLength: 0)
            } else {
                editorBanner
                CodeEditor(text: $model.source, flaggedLines: model.isDirty ? [] : flagged, highlightedLine: model.highlightedLine,
                           revealCount: model.revealCount, isEditable: model.isWritable && model.savedDigest != nil, edit: model.pendingEdit)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(RunnirTheme.editor)
    }

    /// Why the editor cannot simply save: the file changed on disk, the
    /// last save failed, or the file is read-only.
    @ViewBuilder private var editorBanner: some View {
        if let change = model.diskChange {
            banner(change == .conflict
                   ? "\(model.selected?.name ?? "This file") changed on disk after you opened it, so your changes were not saved."
                   : "\(model.selected?.name ?? "This file") changed on disk. Your edits are still here and have not been saved.",
                   symbol: "exclamationmark.triangle", tint: RunnirTheme.warning) {
                Button("Reload from Disk", action: reload).help("Discard your edits and open the file as it is on disk")
                Button("Save Anyway", action: saveAnyway).help("Replace the file on disk with your version")
            }
        } else if let error = model.saveError {
            banner(error, symbol: "exclamationmark.triangle", tint: RunnirTheme.warning) { EmptyView() }
        } else if let notice = model.editNotice {
            banner(notice, symbol: "info.circle", tint: RunnirTheme.info) {
                Button("Dismiss") { model.dismissEditNotice() }
            }
        } else if !model.isWritable {
            banner("This file is read-only. Change its permissions to edit it here.", symbol: "lock", tint: RunnirTheme.secondaryForeground) { EmptyView() }
        }
    }

    private func banner<Actions: View>(_ text: String, symbol: String, tint: Color, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                actions()
            }
            .buttonStyle(DesignButtonStyle()).padding(.horizontal, 12).padding(.vertical, 8).background(tint.opacity(0.1))
            DesignDivider()
        }
    }
}

/// actionlint findings for the selected workflow file, from the Core.
private struct DiagnosticsPanel: View {
    @Bindable var model: WorkspaceFilesModel
    let canValidate: Bool
    let validate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isDirty {
                Label("These results are for the saved file. Save to check your edits.", systemImage: "pencil")
                    .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
            }
            if let problem = model.validation?.configProblem {
                Label("The repository's actionlint config was not used: \(problem)", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(RunnirTheme.warning).fixedSize(horizontal: false, vertical: true)
            }
            content
        }
    }

    @ViewBuilder private var content: some View {
        if model.isValidating && model.validation == nil {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking with actionlint...") }
                .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
        } else if let message = model.validationError, model.validation == nil {
            note(message, symbol: "exclamationmark.triangle", tint: RunnirTheme.warning, action: canValidate ? "Try Again" : nil)
        } else if model.validation == nil {
            note(canValidate ? "Not checked yet." : "Validation runs in Runnir Core once it has opened this repository.",
                 symbol: "checklist", tint: RunnirTheme.secondaryForeground, action: canValidate ? "Validate" : nil)
        } else if let file = model.selected, let result = model.validation(for: file) {
            if let problem = result.problem {
                note("Not checked: \(problem).", symbol: "exclamationmark.triangle", tint: RunnirTheme.warning, action: nil)
            } else if result.diagnostics.isEmpty {
                note("No problems found by \(model.validation?.validator ?? "actionlint").", symbol: "checkmark.circle",
                     tint: RunnirTheme.success, action: nil)
            } else {
                ForEach(Array(result.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                    DiagnosticRow(diagnostic: diagnostic, file: file, selected: diagnostic.line == model.highlightedLine) {
                        model.reveal(line: diagnostic.line)
                    }
                }
                if result.truncated {
                    Text("Only the first \(result.diagnostics.count) problems are shown.")
                        .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                }
            }
            if let error = model.validationError {
                Label("The last check failed: \(error)", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(RunnirTheme.warning)
            }
        } else {
            note("This file was not part of the last check. Validate again.", symbol: "clock.arrow.circlepath",
                 tint: RunnirTheme.secondaryForeground, action: canValidate ? "Validate" : nil)
        }
    }

    private func note(_ text: String, symbol: String, tint: Color, action: String?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let action { Button(action, action: validate).buttonStyle(.link).pointerStyle(.link).font(.system(size: 12)) }
        }
    }
}

private struct DiagnosticRow: View {
    let diagnostic: CoreWorkflowDiagnostic
    let file: LocalWorkflowFile
    let selected: Bool
    let reveal: () -> Void

    var body: some View {
        Button(action: reveal) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(RunnirTheme.destructive).font(.system(size: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(diagnostic.message).font(.system(size: 12)).foregroundStyle(RunnirTheme.foreground)
                        .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                    Text(position + " · " + diagnostic.kind).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(RunnirTheme.secondaryForeground)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5).padding(.horizontal, 6).contentShape(Rectangle())
            .background(selected ? RunnirTheme.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.hit)
        .help(diagnostic.line > 0 ? "Show line \(diagnostic.line) in the source" : "actionlint gave no position")
        .accessibilityLabel("\(diagnostic.message), \(position)")
    }

    private var position: String {
        diagnostic.line > 0 ? "\(file.name):\(diagnostic.line):\(diagnostic.column)" : file.name
    }
}

struct DesignDivider: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(RunnirTheme.border).frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            .accessibilityHidden(true)
    }
}

struct DesignButtonStyle: ButtonStyle {
    var primary = false
    /// 22 points high with 12-point text, for rows and section headers.
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        DesignButtonBody(configuration: configuration, primary: primary, compact: compact)
    }
}

/// A button's look. A primary one is runnir.com's call to action: the
/// accent as a tint (20%, 32% under the pointer) with a 45% accent border.
private struct DesignButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let primary: Bool
    let compact: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: primary && !compact ? 10 : 6)
        configuration.label.font(.system(size: compact ? 12 : 13, weight: primary ? .semibold : .regular))
            .padding(.horizontal, compact ? 10 : primary ? 16 : 14).frame(height: compact ? 22 : 30)
            .foregroundStyle(primary ? RunnirTheme.primaryButtonText : RunnirTheme.secondaryContent)
            .background(primary ? RunnirTheme.primary.opacity(hovering && isEnabled ? 0.32 : 0.2) : RunnirTheme.secondary, in: shape)
            .overlay(shape.stroke(primary ? RunnirTheme.primary.opacity(0.45) : RunnirTheme.border))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .contentShape(shape)
            .pointerStyle(isEnabled ? .link : nil)
            .onHover { hovering = $0 }
    }
}

/// A button drawn by its label alone (rows, icons, sidebar items): the whole
/// label takes the click, not only its text, and the pointer is a hand.
struct HitButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HitButtonBody(configuration: configuration)
    }
}

private struct HitButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .pointerStyle(isEnabled ? .link : nil)
    }
}

extension ButtonStyle where Self == HitButtonStyle {
    static var hit: HitButtonStyle { HitButtonStyle() }
}

extension View {
    /// Something clicked that is not a button of ours (a tapped row, a
    /// native switch or segmented control): the hand pointer over all of it.
    func clickable() -> some View {
        contentShape(Rectangle()).pointerStyle(.link)
    }

    /// A native control that is not a button of the default style (a toggle,
    /// picker, menu, or a link or borderless button): the hand pointer while
    /// it is enabled. Apply it before `.disabled`.
    func handPointer() -> some View {
        modifier(HandPointer())
    }

    /// Every button below that keeps the default style gets the hand pointer,
    /// in its own look. Applied at the root of each window.
    func handPointerButtons() -> some View {
        buttonStyle(HandPointerButtonStyle())
    }
}

/// Draws a button as the style around it would and adds the hand pointer.
/// `Button(configuration)` takes the style outside this one, so a button
/// with a style of its own keeps it.
struct HandPointerButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(configuration).modifier(HandPointer())
    }
}

private struct HandPointer: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    func body(content: Content) -> some View {
        content.pointerStyle(isEnabled ? .link : nil)
    }
}

struct WorkflowTabStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13)).padding(.horizontal, 11).frame(height: 26)
            .foregroundStyle(selected ? RunnirTheme.foreground : RunnirTheme.secondaryForeground)
            .background(selected ? RunnirTheme.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .pointerStyle(.link)
    }
}

/// A sidebar icon fitted into a 16-point square. SF Symbols differ in width
/// (`ladybug` is 17.5 points at 13-point text, `key` 11.5), so centring
/// them in a column still leaves their edges apart; a square they all fill
/// lines them up.
struct SidebarIcon: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol).resizable().scaledToFit().frame(width: 16, height: 16)
    }
}

/// A sidebar row: a 16-point icon column, so the sections, the account and
/// the items under it line up, and the whole row takes the click.
struct SidebarItemLabel: View {
    let title: String
    let symbol: String
    var selected = false

    var body: some View {
        HStack(spacing: 10) {
            SidebarIcon(symbol: symbol)
                .foregroundStyle(selected ? RunnirTheme.primary : RunnirTheme.secondaryForeground)
            Text(title)
            Spacer(minLength: 0)
        }
        .font(.system(size: 13)).padding(.horizontal, 10).frame(height: 30)
        .foregroundStyle(selected ? RunnirTheme.foreground : RunnirTheme.secondaryForeground)
        .background(selected ? RunnirTheme.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
    }
}

struct SectionLabel: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(RunnirTheme.secondaryForeground)
    }
}

struct UnavailableFeature: View {
    let title: String
    let detail: String
    let symbol: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(RunnirTheme.mutedForeground)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview("Workspace Manager / Empty") {
    WorkspaceManagerView(desktop: DesktopCoordinator()).frame(width: 900, height: 600)
}

#Preview("Startup Splash") {
    StartupSplashView()
}

/// Shows which GitHub repository this working tree belongs to (from its origin
/// remote) and whether Runnir can see it, with the step that fixes it when
/// not. The Core reads the repository with the same token it uses for runs, so
/// the card and the run lists agree.
struct GitHubLinkCard: View {
    let repository: String?
    let coreReady: Bool
    let github: GitHubSession?
    let hub: CoreHub?
    let workspaceID: UUID
    @Environment(\.openURL) private var openURL
    @State private var details: CoreGitHubRepository?
    @State private var attempt = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch display {
            case .reading:
                header("Reading the repository...", symbol: "point.3.connected.trianglepath.dotted", tint: RunnirTheme.secondaryForeground)
            case .checking:
                header("Checking access to \(repository ?? "")...", symbol: "point.3.connected.trianglepath.dotted", tint: RunnirTheme.secondaryForeground)
            case .linked(let linked):
                header(linked.fullName.isEmpty ? (repository ?? "") : linked.fullName, symbol: "checkmark.circle", tint: RunnirTheme.success)
                Text("\(linked.visibility.capitalized) · default branch \(linked.defaultBranch)")
                    .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                if let url = linked.htmlURL ?? (isEnterprise ? nil : URL(string: "https://github.com/\(linked.fullName)")) {
                    Button("Open on GitHub") { openURL(url) }.buttonStyle(DesignButtonStyle())
                }
                // Reading works; what waits for an owner, or for write access, is said here.
                if let help = GitHubAccessHelp.blocker(for: .run, repository: linked.fullName.isEmpty ? (repository ?? "") : linked.fullName, details: linked) {
                    GitHubAccessNotice(help: help, style: .note, github: github)
                }
            case .problem(let help):
                GitHubAccessNotice(help: help, style: .note, github: github) { attempt += 1 }
                if case .giveAccess = help.fix {
                    Button("Check Again") { attempt += 1 }.buttonStyle(DesignButtonStyle())
                } else if case .reviewPermissions = help.fix {
                    Button("Check Again") { attempt += 1 }.buttonStyle(DesignButtonStyle())
                }
            }
        }
        .task(id: checkKey) { await check() }
    }

    private func header(_ title: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(title).font(.system(size: 14, weight: .semibold))
        }
    }

    private var checkKey: String { "\(repository ?? "")|\(github?.user?.login ?? "")|\(coreReady)|\(attempt)|\(hub?.credentialGeneration ?? 0)" }

    /// The working tree's origin is on an Enterprise server, whose sign-in
    /// is its token in Settings, not the github.com sign-in.
    private var isEnterprise: Bool { !(hub?.session(for: workspaceID)?.githubServerID ?? "").isEmpty }

    private func check() async {
        details = nil
        guard repository != nil, coreReady, github?.user != nil || isEnterprise, let hub else { return }
        details = await hub.githubRepository(workspaceID: workspaceID)
    }

    private enum Display { case reading, checking, linked(CoreGitHubRepository), problem(GitHubAccessHelp) }

    private var display: Display {
        guard let repository else {
            return coreReady ? .problem(GitHubAccessHelp.noRemote(originHost: hub?.session(for: workspaceID)?.originHost)) : .reading
        }
        if !isEnterprise, github?.user == nil {
            return .problem(GitHubAccessHelp.forAccess(.signedOut, repository: repository, purpose: .read)!)
        }
        guard let details else { return .checking }
        if details.access == .ok { return .linked(details) }
        return .problem(hub?.accessHelp(details.access, workspaceID: workspaceID, purpose: .read, details: details)
                        ?? GitHubAccessHelp.forAccess(.unavailable, repository: repository, purpose: .read)!)
    }
}
