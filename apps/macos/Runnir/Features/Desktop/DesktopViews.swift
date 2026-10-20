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

struct ProjectLink: View {
    var body: some View {
        Link(destination: URL(string: "https://github.com/dil-eight/runnir")!) {
            Image(systemName: "arrow.up.right.square")
        }
        .help("Open Runnir on GitHub")
        .accessibilityLabel("Open Runnir on GitHub")
    }
}

struct WorkspaceManagerView: View {
    @Bindable var desktop: DesktopCoordinator

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                BrandLogo(height: 51, width: 140)
                Spacer()
                ProjectLink().buttonStyle(.plain)
                if !desktop.snapshot.workspaces.isEmpty {
                    Button { desktop.importRepository() } label: {
                        Label("Import Repository...", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(DesignButtonStyle(primary: true))
                    .disabled(desktop.persistenceBlocked)
                }
            }
            .frame(height: 51).padding(.bottom, 22)

            if let message = desktop.message {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(RunnirTheme.warning)
                    Text(message).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    if desktop.persistenceBlocked {
                        Button("Back Up and Reset...") { desktop.resetUnreadableSession() }
                    } else {
                        Button { desktop.message = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).help("Dismiss message")
                    }
                }
                .padding(12).background(RunnirTheme.surface, in: RoundedRectangle(cornerRadius: 6))
                .padding(.bottom, 16)
            }

            if desktop.snapshot.workspaces.isEmpty {
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
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("Workspace actions")
        }
        .buttonStyle(DesignButtonStyle()).padding(.horizontal, 12).frame(height: 62)
    }
}

enum YAMLSyntaxHighlighting {
    private static let expression = try? NSRegularExpression(pattern:
        #"\G(?:(?<comment>(?<!\S)[#].*$)|(?<string>"(?:\\.|[^"\\])*"|'(?:''|[^'])*')|(?<key>[A-Za-z_][A-Za-z0-9_.-]*(?=\s*:(?:\s|$)))|(?<literal>(?<![\w.-])(?:true|false|null|~|[-+]?\d+(?:\.\d+)?)(?![\w.-]))|[^\s]+|\s+)"#)

    static func highlight(_ line: String) -> AttributedString {
        var result = AttributedString(line)
        guard let expression else { return result }
        let colors: [(String, Color)] = [
            ("comment", RunnirTheme.mutedForeground), ("string", RunnirTheme.syntaxString),
            ("key", RunnirTheme.syntaxKey), ("literal", RunnirTheme.syntaxLiteral)
        ]
        for match in expression.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
            for (name, color) in colors {
                guard let range = Range(match.range(withName: name), in: line),
                      let start = AttributedString.Index(range.lowerBound, within: result),
                      let end = AttributedString.Index(range.upperBound, within: result) else { continue }
                result[start..<end].foregroundColor = color
            }
        }
        return result
    }
}

struct CodePreviewLayout {
    let lines: [String]
    let highlightedLines: [AttributedString]
    let gutterWidth: CGFloat

    init(source: String) {
        lines = source.components(separatedBy: "\n")
        highlightedLines = lines.map(YAMLSyntaxHighlighting.highlight)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        gutterWidth = max(28, ceil((String(lines.count) as NSString).size(withAttributes: [.font: font]).width))
    }
}

@MainActor
@Observable
final class WorkspaceFilesModel {
    var files: [LocalWorkflowFile] = []
    var selected: LocalWorkflowFile?
    var source = "" {
        didSet { sourceLayout = CodePreviewLayout(source: source) }
    }
    private(set) var sourceLayout = CodePreviewLayout(source: "")
    var isLoading = false
    var error: String?
    private var sourceTask: Task<Void, Never>?

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

    func load(_ reader: RepositoryReader) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            files = try await Task.detached { try reader.workflows() }.value
            error = nil
            if let selected, files.contains(selected) { select(selected, reader: reader) }
            else { selected = files.first; if let selected { select(selected, reader: reader) } }
        } catch { self.error = "Workflow files could not be read. Check access and keep files inside this repository." }
    }

    func select(_ file: LocalWorkflowFile, reader: RepositoryReader) {
        if selected != file { highlightedLine = nil }
        selected = file
        source = ""
        sourceTask?.cancel()
        sourceTask = Task {
            do {
                let text = try await Task.detached { try reader.source(for: file) }.value
                guard !Task.isCancelled else { return }
                source = text
                error = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "This workflow is unreadable, outside the repository, or exceeds the 512 KiB preview limit."
            }
        }
    }
}

struct DesktopWorkspaceView: View {
    @Environment(AppState.self) private var state
    let desktop: DesktopCoordinator
    let workspace: WorkspaceRecord
    let windowID: UUID
    let reader: RepositoryReader?
    @State private var files = WorkspaceFilesModel()

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
                } else {
                    coreBanner
                    content
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(RunnirTheme.background).foregroundStyle(RunnirTheme.foreground).tint(RunnirTheme.primary)
        .ignoresSafeArea()
        .task { if let reader { await files.load(reader) } }
        .onChange(of: state.selectedSection) { _, value in desktop.selectSection(value, windowID: windowID) }
        .sheet(item: Binding(get: { state.runWorkflowRequest }, set: { state.runWorkflowRequest = $0 })) { request in
            if let session, let hub = desktop.core {
                RunWorkflowSheet(model: DispatchFormModel(workspaceID: workspace.id, hub: hub, workflows: session.remoteWorkflows,
                                                          workflowID: request.workflowID, currentBranch: session.branch)) { run in
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
                                                         jobID: request.jobID, hub: hub),
                              repositoryPath: session.path) { _ in
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
        .sheet(isPresented: Binding(get: { state.showingSwitcher }, set: { state.showingSwitcher = $0 })) {
            WorkspaceSwitcherView(desktop: desktop, currentWorkspaceID: workspace.id, windowID: windowID)
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

    private func menuTitle(_ file: LocalWorkflowFile) -> String {
        guard let count = files.problemCount(for: file), count > 0 else { return file.name }
        return "\(file.name)  ·  \(count) \(count == 1 ? "problem" : "problems")"
    }

    private var runWorkflowHelp: String {
        if session?.githubRepository == nil { return "This working tree has no GitHub remote" }
        if desktop.github?.user == nil { return "Connect GitHub to run workflows" }
        if session?.githubAccess != .ok { return "Runnir can't reach this repository on GitHub" }
        return "Start a workflow_dispatch workflow on GitHub"
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
                    ForEach(files.files) { file in
                        Button(menuTitle(file)) { if let reader { files.select(file, reader: reader) } }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                        Text(files.selected?.name ?? "No workflow").lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 9))
                    }.font(.system(size: 12)).frame(maxWidth: 150)
                        .padding(.horizontal, 10).frame(height: 26)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(RunnirTheme.border))
                }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().disabled(files.files.isEmpty)
                Text("Read-only").font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
            }
            Spacer(minLength: 4)
            if state.selectedSection == .workspace {
                Button("Save") {}.disabled(true).help("Workflow editing is not implemented")
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
                Button { state.runWorkflowRequest = RunWorkflowRequest(workflowID: nil) } label: { Label("Run Workflow...", systemImage: "play") }
                    .buttonStyle(DesignButtonStyle(primary: true))
                    .disabled(session?.githubRepository == nil || desktop.github?.user == nil || session?.githubAccess != .ok)
                    .help(runWorkflowHelp)
            }
            ProjectLink().buttonStyle(.plain)
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
            Color.clear.frame(height: 26)
            BrandLogo(height: 47, width: 128).padding(.leading, 6).padding(.top, 2).padding(.bottom, 14)
            Button { state.showingSwitcher = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "shippingbox").frame(width: 16).foregroundStyle(RunnirTheme.primary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(workspace.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text("Local working tree").font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)).foregroundStyle(RunnirTheme.secondaryForeground)
                }.padding(.horizontal, 10).frame(height: 48)
                    .background(RunnirTheme.surface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(RunnirTheme.border))
            }
            .buttonStyle(.plain)
            .help("Switch workspace (Shift-Command-O)")
            .contextMenu {
                Button("Open Quickly...") { state.showingSwitcher = true }
                Button("Workspace Manager...") { desktop.showManager() }
            }
            Color.clear.frame(height: 10)
            VStack(spacing: 2) {
                ForEach(AppSection.sidebarSections) { section in
                    Button { state.selectedSection = section } label: {
                        HStack(spacing: 10) {
                            Image(systemName: section.symbolName).frame(width: 16)
                                .foregroundStyle(state.selectedSection == section ? RunnirTheme.primary : RunnirTheme.secondaryForeground)
                            Text(section.title)
                            Spacer()
                        }
                        .font(.system(size: 13)).padding(.horizontal, 10).frame(height: 30)
                        .contentShape(Rectangle())
                        .foregroundStyle(state.selectedSection == section ? RunnirTheme.foreground : RunnirTheme.secondaryForeground)
                        .background(state.selectedSection == section ? RunnirTheme.selected : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain).accessibilityAddTraits(state.selectedSection == section ? .isSelected : [])
                }
            }
            Spacer()
            Group {
                if let github = desktop.github {
                    GitHubAccountRow(session: github)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.circle").font(.system(size: 18)).foregroundStyle(RunnirTheme.secondaryForeground)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("GitHub").font(.system(size: 12))
                            Text("Not connected").font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                        }
                    }
                }
            }.padding(.horizontal, 10).frame(height: 45)
            SettingsLink { Label("Settings...", systemImage: "gearshape") }
                .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(RunnirTheme.secondaryForeground)
                .padding(.horizontal, 10).frame(height: 30)
        }
        .padding(.horizontal, 12).padding(.vertical, 14).frame(width: 220)
        .frame(maxHeight: .infinity).background(RunnirTheme.sidebar)
    }

    @ViewBuilder private var content: some View {
        switch state.selectedSection {
        case .dashboard, .repositories, .artifacts:
            overview
        case .workspace:
            VStack(spacing: 0) {
                workspaceTabs
                if state.workspaceTab == .localRun, let run = localRun {
                    LocalRunView(run: run)
                } else {
                    LocalWorkflowBrowser(model: files, canValidate: canValidate, validate: validateWorkflows)
                        .task(id: canValidate) {
                            // The first visit checks the files; later ones keep the last report.
                            if canValidate, files.validation == nil, files.validationError == nil { validateWorkflows() }
                        }
                }
            }
        case .workflows:
            if let session, let hub = desktop.core {
                WorkspaceWorkflowsView(session: session, hub: hub, github: desktop.github, showRun: { run in
                    state.selectedRunID = run.id
                    state.selectedSection = .runs
                }, runWorkflow: { workflow in
                    state.runWorkflowRequest = RunWorkflowRequest(workflowID: workflow.id)
                })
            } else {
                coreUnavailable
            }
        case .runs:
            if let session, let hub = desktop.core {
                WorkspaceRunsView(session: session, hub: hub, github: desktop.github,
                                  selectedRunID: Binding(get: { state.selectedRunID }, set: { state.selectedRunID = $0 }))
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

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 16) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 4) {
                            ForEach(files.files) { file in
                                Button(file.name) { if let reader { files.select(file, reader: reader) } }
                                    .buttonStyle(WorkflowTabStyle(selected: files.selected == file))
                            }
                        }
                    }.scrollIndicators(.hidden)
                    GitHubLinkCard(repository: session?.githubRepository, coreReady: session?.phase == .ready, github: desktop.github,
                                   hub: desktop.core, workspaceID: workspace.id)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
                }
                DesignDivider()
                HStack(alignment: .top, spacing: 40) {
                    VStack(alignment: .leading, spacing: 16) {
                        SectionLabel(title: "RECENT RUNS")
                        DesignDivider()
                        if let session, session.githubRepository != nil {
                            RecentRunsList(session: session, github: desktop.github, hub: desktop.core) { run in
                                state.selectedRunID = run.id
                                state.selectedSection = .runs
                            }
                        } else {
                            UnavailableFeature(title: "No runs available",
                                               detail: "This working tree has no GitHub remote.",
                                               symbol: "play.circle")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 0) {
                        SectionLabel(title: "LOCAL WORKFLOWS").padding(.bottom, 8)
                        DesignDivider()
                        ForEach(files.files) { file in
                            Button {
                                if let reader { files.select(file, reader: reader) }
                                state.selectedSection = .workspace
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(file.name).font(.system(size: 13))
                                        Text("Working tree").font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(RunnirTheme.secondaryForeground)
                                }.padding(.horizontal, 12).frame(height: 48).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            DesignDivider()
                        }
                        if files.files.isEmpty { Text("No workflow files").font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground).padding(12) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if let error = files.error { Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(RunnirTheme.warning) }
            }.padding(.horizontal, 28).padding(.vertical, 24)
        }
    }
}

private struct LocalWorkflowBrowser: View {
    @Bindable var model: WorkspaceFilesModel
    let canValidate: Bool
    let validate: () -> Void

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
                                .frame(maxWidth: .infinity, minHeight: 130, alignment: .leading)
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
                } else if model.selected == nil {
                    UnavailableFeature(title: "No workflows", detail: "No YAML files in .github/workflows.", symbol: "doc.text").padding(20)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(model.sourceLayout.lines.indices, id: \.self) { index in
                                    let line = model.sourceLayout.lines[index]
                                    let number = index + 1
                                    HStack(alignment: .top, spacing: 14) {
                                        Text("\(number)").foregroundStyle(flagged.contains(number) ? RunnirTheme.destructive : RunnirTheme.mutedForeground)
                                            .lineLimit(1).frame(width: model.sourceLayout.gutterWidth, alignment: .trailing).accessibilityHidden(true)
                                        Text(line.isEmpty ? AttributedString(" ") : model.sourceLayout.highlightedLines[index])
                                            .foregroundStyle(RunnirTheme.foreground).textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }.font(.system(size: 12, design: .monospaced)).lineSpacing(3)
                                        .frame(minHeight: 20, alignment: .top)
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
                                        .background(number == model.highlightedLine ? RunnirTheme.destructive.opacity(0.14)
                                                    : flagged.contains(number) ? RunnirTheme.destructive.opacity(0.06) : .clear)
                                        .id(number)
                                }
                            }.padding(.vertical, 8)
                        }.scrollIndicators(.visible)
                        .onChange(of: model.revealCount) {
                            if let line = model.highlightedLine { withAnimation { proxy.scrollTo(line, anchor: .center) } }
                        }
                    }
                }
                Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(RunnirTheme.editor)
    }
}

/// actionlint findings for the selected workflow file, from the Core.
private struct DiagnosticsPanel: View {
    @Bindable var model: WorkspaceFilesModel
    let canValidate: Bool
    let validate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
            if let action { Button(action, action: validate).buttonStyle(.link).font(.system(size: 12)) }
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
        .buttonStyle(.plain)
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
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: primary ? .medium : .regular))
            .padding(.horizontal, 14).frame(height: 30)
            .foregroundStyle(primary ? RunnirTheme.primaryForeground : RunnirTheme.secondaryContent)
            .background(primary ? RunnirTheme.primary : RunnirTheme.secondary, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(primary ? .clear : RunnirTheme.border))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct WorkflowTabStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13)).padding(.horizontal, 11).frame(height: 26)
            .foregroundStyle(selected ? RunnirTheme.foreground : RunnirTheme.secondaryForeground)
            .background(selected ? RunnirTheme.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
            .opacity(configuration.isPressed ? 0.7 : 1)
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
private struct GitHubLinkCard: View {
    let repository: String?
    let coreReady: Bool
    let github: GitHubSession?
    let hub: CoreHub?
    let workspaceID: UUID
    var installationURL: URL = GitHubAppConfiguration.runnirDesktop.installationURL
    @Environment(\.openURL) private var openURL
    @State private var details: CoreGitHubRepository?
    @State private var attempt = 0
    @State private var showingConnect = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(title).font(.system(size: 14, weight: .semibold))
            }
            if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground) }
            HStack(spacing: 8) { buttons }.buttonStyle(DesignButtonStyle())
        }
        .task(id: checkKey) { await check() }
        .sheet(isPresented: $showingConnect) { if let github { GitHubConnectView(session: github) } }
    }

    private var checkKey: String { "\(repository ?? "")|\(github?.user?.login ?? "")|\(coreReady)|\(attempt)" }

    private func check() async {
        details = nil
        guard repository != nil, coreReady, github?.user != nil, let hub else { return }
        details = await hub.githubRepository(workspaceID: workspaceID)
    }

    private enum Display { case reading, noRemote, signedOut, checking, linked(CoreGitHubRepository), notVisible, failed(String) }

    private var display: Display {
        guard repository != nil else { return coreReady ? .noRemote : .reading }
        guard let github, github.user != nil else { return .signedOut }
        guard let details else { return .checking }
        switch details.access {
        case .ok: return .linked(details)
        case .noRemote: return .noRemote
        case .signedOut, .tokenRejected: return .signedOut
        case .notVisible: return .notVisible
        case .rateLimited(let until):
            return .failed(until.map { "GitHub is limiting requests until \($0.formatted(date: .omitted, time: .shortened))." }
                           ?? "GitHub is limiting requests. Try again in a moment.")
        case .unavailable: return .failed("GitHub could not be reached. Try again in a moment.")
        }
    }

    private var title: String {
        let name = repository ?? ""
        switch display {
        case .reading: return "Reading the repository..."
        case .noRemote: return "No GitHub remote"
        case .signedOut: return name
        case .checking: return "Checking access to \(name)..."
        case .linked(let linked): return linked.fullName.isEmpty ? name : linked.fullName
        case .notVisible: return "Runnir can't see \(name)"
        case .failed: return name
        }
    }

    private var detail: String? {
        switch display {
        case .reading, .checking: return nil
        case .noRemote: return "This working tree has no origin remote on github.com, so there are no GitHub runs to show for it."
        case .signedOut: return "Connect GitHub to see workflow runs and job status for this repository."
        case .linked(let linked): return "\(linked.visibility.capitalized) · default branch \(linked.defaultBranch)"
        case .notVisible:
            return "Runnir Desktop only sees repositories it is installed on. Install it on this repository on GitHub, then check again."
        case .failed(let message): return message
        }
    }

    private var symbol: String {
        switch display {
        case .linked: "checkmark.circle"
        case .notVisible, .failed: "exclamationmark.triangle"
        default: "point.3.connected.trianglepath.dotted"
        }
    }

    private var tint: Color {
        switch display {
        case .linked: RunnirTheme.success
        case .notVisible, .failed: RunnirTheme.warning
        default: RunnirTheme.secondaryForeground
        }
    }

    @ViewBuilder private var buttons: some View {
        switch display {
        case .signedOut:
            Button("Connect GitHub...") { showingConnect = true }
        case .linked(let linked):
            if let url = linked.htmlURL ?? URL(string: "https://github.com/\(linked.fullName)") {
                Button("Open on GitHub") { openURL(url) }
            }
        case .notVisible:
            Button("Give Runnir Access...") { openURL(installationURL) }
            Button("Check Again") { attempt += 1 }
        case .failed:
            Button("Check Again") { attempt += 1 }
        default:
            EmptyView()
        }
    }
}
