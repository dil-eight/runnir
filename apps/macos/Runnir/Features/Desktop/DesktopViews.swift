import SwiftUI
import AppKit
import Observation

struct BrandLogo: View {
    @Environment(\.colorScheme) private var scheme
    var markOnly = false
    var height: CGFloat = 32
    var width: CGFloat? = nil
    var wordmarkOnly = false

    var body: some View {
        let name = (markOnly ? "logo-mark-" : wordmarkOnly ? "logo-wordmark-" : "logo-horizontal-") + (scheme == .dark ? "light" : "dark")
        if let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "assets"),
           let image = NSImage(contentsOf: url) {
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
        .sheet(isPresented: Binding(get: { state.showingSwitcher }, set: { state.showingSwitcher = $0 })) {
            WorkspaceSwitcherView(desktop: desktop, currentWorkspaceID: workspace.id, windowID: windowID)
        }
    }

    private var session: RepositorySession? { desktop.core?.session(for: workspace.id) }

    private var coreSummary: String { session?.summary ?? "Working tree" }
    private var coreDetail: String { session?.detail ?? "Branch and workflows reported by Runnir Core" }

    /// Offers to restart the Core when it stopped or could not start.
    @ViewBuilder private var coreBanner: some View {
        if let core = desktop.core, core.status.needsRecovery {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(RunnirTheme.warning)
                Text(bannerText(core.status)).font(.system(size: 12))
                Spacer(minLength: 4)
                Button("Restart Core") { Task { await core.recover() } }
            }
            .buttonStyle(DesignButtonStyle()).padding(.horizontal, 20).frame(height: 40)
            .background(RunnirTheme.warning.opacity(0.12))
            DesignDivider()
        }
    }

    private func bannerText(_ status: CoreHub.Status) -> String {
        switch status {
        case .lost: "Runnir Core stopped unexpectedly. Workflow data may be out of date."
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
                        Button(file.name) { if let reader { files.select(file, reader: reader) } }
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
                Button("Validate") {}.disabled(true).help("actionlint integration is not implemented")
                Button {} label: { Label("Test Locally...", systemImage: "flask") }
                    .buttonStyle(DesignButtonStyle(primary: true)).disabled(true).help("Local execution is not implemented")
            } else {
                Label(coreSummary, systemImage: "arrow.triangle.branch")
                    .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                    .lineLimit(1).help(coreDetail)
                Button("Refresh") {
                    if let reader { Task { await files.load(reader) } }
                    Task { await desktop.core?.refresh(workspaceID: workspace.id) }
                }
                .disabled(reader == nil || files.isLoading || session?.isRefreshing == true).help("Refresh local workflows")
                Button {} label: { Label("Run Workflow...", systemImage: "play") }
                    .buttonStyle(DesignButtonStyle(primary: true)).disabled(true).help("GitHub dispatch is not implemented")
            }
            ProjectLink().buttonStyle(.plain)
        }
        .buttonStyle(DesignButtonStyle()).padding(.horizontal, 20).frame(height: 52)
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
                Divider()
                Button("Artifacts...") { state.selectedSection = .artifacts }
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
        case .dashboard:
            overview
        case .workspace:
            LocalWorkflowBrowser(model: files)
        case .repositories: RepositoriesView()
        case .workflows: WorkflowsView()
        case .runs: RunsView()
        case .artifacts: ArtifactsView()
        }
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
                    GitHubLinkCard(repository: session?.githubRepository, coreReady: session?.phase == .ready, github: desktop.github)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
                }
                DesignDivider()
                HStack(alignment: .top, spacing: 40) {
                    VStack(alignment: .leading, spacing: 16) {
                        SectionLabel(title: "RECENT RUNS")
                        DesignDivider()
                        UnavailableFeature(title: "No runs available",
                                           detail: desktop.github?.user == nil ? "GitHub is not connected." : "Run history is not available yet.",
                                           symbol: "play.circle")
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
                            Image(systemName: "info.circle").foregroundStyle(RunnirTheme.secondaryForeground)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Local testing is not available yet").font(.system(size: 12, weight: .medium))
                                Text("Docker, OrbStack and act integration is planned.").font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                            }
                            Spacer(minLength: 0)
                        }.padding(14).background(RunnirTheme.surface, in: RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(spacing: 22) {
                                Text("Diagnostics").foregroundStyle(RunnirTheme.foreground)
                                Text("Local test").foregroundStyle(RunnirTheme.secondaryForeground)
                                Text("Suggestions · later").foregroundStyle(RunnirTheme.mutedForeground)
                            }.font(.system(size: 13)).padding(.horizontal, 12)
                            DesignDivider()
                            Text("Validation has not been run. actionlint is not connected.")
                                .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground).padding(.horizontal, 12)
                        }
                    }.padding(.horizontal, 24).padding(.vertical, 20)
                }.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sourcePanel: some View {
        VStack(spacing: 0) {
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).padding(20)
                } else if model.selected == nil {
                    UnavailableFeature(title: "No workflows", detail: "No YAML files in .github/workflows.", symbol: "doc.text").padding(20)
                } else {
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(model.sourceLayout.lines.indices, id: \.self) { index in
                                let line = model.sourceLayout.lines[index]
                                HStack(alignment: .top, spacing: 14) {
                                    Text("\(index + 1)").foregroundStyle(RunnirTheme.mutedForeground)
                                        .lineLimit(1).frame(width: model.sourceLayout.gutterWidth, alignment: .trailing).accessibilityHidden(true)
                                    Text(line.isEmpty ? AttributedString(" ") : model.sourceLayout.highlightedLines[index])
                                        .foregroundStyle(RunnirTheme.foreground).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                }.font(.system(size: 12, design: .monospaced)).lineSpacing(3)
                                    .frame(minHeight: 20, alignment: .top)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
                            }
                        }.padding(.vertical, 8)
                    }.scrollIndicators(.visible)
                }
                Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(RunnirTheme.editor)
    }
}

private struct DesignDivider: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(RunnirTheme.border).frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            .accessibilityHidden(true)
    }
}

private struct DesignButtonStyle: ButtonStyle {
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

private struct WorkflowTabStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13)).padding(.horizontal, 11).frame(height: 26)
            .foregroundStyle(selected ? RunnirTheme.foreground : RunnirTheme.secondaryForeground)
            .background(selected ? RunnirTheme.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct SectionLabel: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(RunnirTheme.secondaryForeground)
    }
}

private struct UnavailableFeature: View {
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
/// remote) and whether Runnir can see it, with the step that fixes it when not.
private struct GitHubLinkCard: View {
    let repository: String?
    let coreReady: Bool
    let github: GitHubSession?
    var installationURL: URL = GitHubAppConfiguration.runnirDesktop.installationURL
    @Environment(\.openURL) private var openURL
    @State private var access: GitHubRepositoryAccess?
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

    private var checkKey: String { "\(repository ?? "")|\(github?.user?.login ?? "")|\(attempt)" }

    private func check() async {
        guard let repository, let github, github.user != nil else { access = nil; return }
        access = nil
        access = await github.access(to: repository)
    }

    private enum Display { case reading, noRemote, signedOut, checking, linked(Repository), notVisible, failed(String) }

    private var display: Display {
        guard let repository else { return coreReady ? .noRemote : .reading }
        _ = repository
        guard let github, github.user != nil else { return .signedOut }
        switch access {
        case nil: return .checking
        case .signedOut: return .signedOut
        case .accessible(let linked): return .linked(linked)
        case .notVisible: return .notVisible
        case .failed(let message): return .failed(message)
        }
    }

    private var title: String {
        let name = repository ?? ""
        switch display {
        case .reading: return "Reading the repository..."
        case .noRemote: return "No GitHub remote"
        case .signedOut: return name
        case .checking: return "Checking access to \(name)..."
        case .linked(let linked): return linked.fullName
        case .notVisible: return "Runnir can't see \(name)"
        case .failed: return name
        }
    }

    private var detail: String? {
        switch display {
        case .reading, .checking: return nil
        case .noRemote: return "This working tree has no origin remote on github.com, so there are no GitHub runs to show for it."
        case .signedOut: return "Connect GitHub to see workflow runs and job status for this repository."
        case .linked(let linked): return "\(linked.visibility.rawValue.capitalized) · default branch \(linked.defaultBranch)"
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
            Button("Open on GitHub") { openURL(URL(string: "https://github.com/\(linked.fullName)")!) }
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
