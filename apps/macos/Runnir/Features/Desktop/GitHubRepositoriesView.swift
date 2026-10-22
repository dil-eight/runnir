import SwiftUI

// MARK: Favorite repositories

/// favorite-repositories.json in the app's support directory: the GitHub
/// repositories starred in the Workspace Manager, by "owner/name", in the
/// order they were starred. Versioned, bounded, written atomically.
struct FileRepositoryFavoritesStore: Sendable {
    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("favorite-repositories.json") }

    static let maxRepositories = 200
    static let maxFileBytes = 256 * 1024

    private struct Snapshot: Codable {
        var version = 1
        var repositories: [String]
    }

    static func live() throws -> FileRepositoryFavoritesStore {
        FileRepositoryFavoritesStore(directory: try RunnirSupportDirectory.url())
    }

    static func isValid(_ names: [String]) -> Bool {
        names.count <= maxRepositories && Set(names.map { $0.lowercased() }).count == names.count
            && names.allSatisfy { GitHubRepositoryName.isValid($0) }
    }

    func load() throws -> [String] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= Self.maxFileBytes else { throw DesktopStoreError.tooLarge }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: fileURL))
        guard snapshot.version == 1, Self.isValid(snapshot.repositories) else { throw DesktopStoreError.invalidState }
        return snapshot.repositories
    }

    func save(_ names: [String]) throws {
        guard Self.isValid(names) else { throw DesktopStoreError.invalidState }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try AtomicFile.write(try encoder.encode(Snapshot(repositories: names)), to: fileURL)
    }
}

enum GitHubRepositoryName {
    /// "owner/name" with the characters GitHub allows; the Core checks again.
    static func isValid(_ fullName: String) -> Bool {
        let parts = fullName.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...39).contains(parts[0].count), (1...100).contains(parts[1].count),
              parts[1] != ".", parts[1] != "..", parts[0].first != "-" else { return false }
        let owner = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let name = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return parts[0].unicodeScalars.allSatisfy { $0.isASCII && owner.contains($0) }
            && parts[1].unicodeScalars.allSatisfy { $0.isASCII && name.contains($0) }
    }
}

/// Starred GitHub repositories, read when created. When the file cannot be
/// read, stars are off for the session and nothing overwrites it.
@MainActor
@Observable
final class RepositoryFavorites {
    private(set) var names: [String] = []
    private(set) var problem: String?
    @ObservationIgnored private let store: FileRepositoryFavoritesStore?
    @ObservationIgnored private var readable = true

    init(store: FileRepositoryFavoritesStore?) {
        self.store = store
        guard let store else { return }
        do {
            names = try store.load()
        } catch {
            readable = false
            problem = "Starred repositories could not be read, so stars are off for now. The file was left as it is."
        }
    }

    var isAvailable: Bool { store != nil && readable }

    /// GitHub names are not case-sensitive.
    func isFavorite(_ fullName: String) -> Bool {
        names.contains { $0.caseInsensitiveCompare(fullName) == .orderedSame }
    }

    @discardableResult
    func toggle(_ fullName: String) -> Bool {
        guard GitHubRepositoryName.isValid(fullName) else { return false }
        var candidate = names
        if let index = candidate.firstIndex(where: { $0.caseInsensitiveCompare(fullName) == .orderedSame }) {
            candidate.remove(at: index)
        } else {
            guard candidate.count < FileRepositoryFavoritesStore.maxRepositories else {
                problem = "At most \(FileRepositoryFavoritesStore.maxRepositories) repositories can be starred."
                return false
            }
            candidate.append(fullName)
        }
        guard let store, readable else {
            problem = problem ?? "Stars are not available."
            return false
        }
        do {
            try store.save(candidate)
            names = candidate
            problem = nil
            return true
        } catch {
            problem = "The star could not be saved. Check available storage and try again."
            return false
        }
    }
}

// MARK: Models

/// The Workspace Manager's GitHub tab: the repositories the token reaches,
/// with search, an owner filter and stars. The last list read stays shown
/// when a reload fails.
@MainActor
@Observable
final class GitHubRepositoriesModel {
    private(set) var access: CoreGitHubAccess?
    private(set) var installations: [CoreGitHubInstallation] = []
    private(set) var repositories: [CoreGitHubAccountRepository] = []
    private(set) var truncated = false
    /// A personal token lists what it reaches; it has no installations.
    private(set) var credentialKind: CoreGitHubCredentialKind = .appUser
    private(set) var loadedAt: Date?
    /// The GitHub login the list was read for.
    private(set) var loadedLogin: String?
    private(set) var isLoading = false
    var search = ""
    /// An installation account, or nil for all of them.
    var owner: String?
    var starredOnly = false
    var selectedFullName: String?

    func load(hub: CoreHub, login: String?) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        // Another account's list, stars aside, is not this one's.
        if login != loadedLogin {
            installations = []
            repositories = []
            truncated = false
            loadedAt = nil
            loadedLogin = nil
            selectedFullName = nil
            owner = nil
        }
        let account = await hub.accountRepositories()
        access = account.access
        guard account.access == .ok else {
            if account.access == .signedOut || account.access == .tokenRejected {
                repositories = []
                installations = []
                loadedAt = nil
            }
            return
        }
        installations = account.installations
        repositories = account.repositories
        truncated = account.truncated
        credentialKind = account.credentialKind
        loadedAt = Date()
        loadedLogin = login
        if let selected = selectedFullName, !repositories.contains(where: { $0.fullName == selected }) { selectedFullName = nil }
        if let owner, !installations.contains(where: { $0.account == owner }) { self.owner = nil }
    }

    /// Opening the tab reads the list again only when it is missing, failed,
    /// older than five minutes or another account's; Refresh always reads it.
    func needsReload(for login: String?) -> Bool {
        guard access == .ok, let loadedAt, login == loadedLogin else { return true }
        return Date().timeIntervalSince(loadedAt) > 300
    }

    var selected: CoreGitHubAccountRepository? {
        repositories.first { $0.fullName == selectedFullName }
    }

    /// The list as filtered: starred ones first, in the order starred, then
    /// the rest newest push first.
    func visible(favorites: RepositoryFavorites) -> [CoreGitHubAccountRepository] {
        let filtered = repositories.filter { repository in
            (owner == nil || repository.owner.caseInsensitiveCompare(owner!) == .orderedSame)
                && (!starredOnly || favorites.isFavorite(repository.fullName))
                && Self.matches(repository, search)
        }
        let rank = Dictionary(favorites.names.enumerated().map { ($1.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let starred = filtered.filter { rank[$0.fullName.lowercased()] != nil }
            .sorted { rank[$0.fullName.lowercased()]! < rank[$1.fullName.lowercased()]! }
        return starred + filtered.filter { rank[$0.fullName.lowercased()] == nil }
    }

    /// Every word of the query is in the name, owner or description.
    static func matches(_ repository: CoreGitHubAccountRepository, _ query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let text = (repository.fullName + " " + repository.description).lowercased()
        return words.allSatisfy { text.contains($0) }
    }
}

/// One repository picked in the GitHub tab: its workflows with their latest
/// runs and its newest runs, read by name through the Core.
@MainActor
@Observable
final class RemoteRepositoryModel {
    let fullName: String
    private(set) var workflows: CoreGitHubResult<CoreGitHubWorkflow>?
    private(set) var runs: CoreGitHubResult<CoreWorkflowRun>?
    private(set) var isLoading = false

    init(fullName: String) {
        self.fullName = fullName
    }

    var target: CoreHub.GitHubTarget { .repository(fullName) }

    func load(hub: CoreHub) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        async let workflows = hub.workflows(of: target)
        async let runs = hub.runs(of: target, limit: 30)
        let (loadedWorkflows, loadedRuns) = await (workflows, runs)
        // A failed read keeps what was shown; the access says why.
        if loadedWorkflows.access == .ok || self.workflows == nil { self.workflows = loadedWorkflows }
        else { self.workflows = CoreGitHubResult(access: loadedWorkflows.access, items: self.workflows?.items ?? []) }
        if loadedRuns.access == .ok || self.runs == nil { self.runs = loadedRuns }
        else { self.runs = CoreGitHubResult(access: loadedRuns.access, items: self.runs?.items ?? []) }
    }

    var access: CoreGitHubAccess? {
        guard let workflows else { return nil }
        return workflows.access == .ok ? runs?.access : workflows.access
    }

    func latestRun(_ workflow: CoreGitHubWorkflow) -> CoreWorkflowRun? {
        runs?.items.first { $0.workflowID == workflow.id }
    }

    var hasActiveRuns: Bool { runs?.items.contains { $0.outcome.isActive } ?? false }
}

// MARK: Views

/// The Workspace Manager's GitHub tab (S04): repositories of the accounts
/// where the Runnir Desktop app is installed, and the selected one's
/// workflows and runs. A repository opens as a workspace when a local clone
/// is registered; workflows can be started without one.
struct GitHubRepositoriesView: View {
    @Bindable var desktop: DesktopCoordinator
    @State private var showingConnect = false
    @Environment(\.openURL) private var openURL

    private var model: GitHubRepositoriesModel { desktop.githubRepositories }

    var body: some View {
        Group {
            if let github = desktop.github, let hub = desktop.core {
                if case .restoring = github.connection {
                    // Not signed out yet: the saved sign-in is being read,
                    // which can wait for the Keychain to allow it.
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking the saved sign-in...") }
                        .font(.system(size: 13)).foregroundStyle(RunnirTheme.secondaryForeground)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if github.user == nil {
                    signedOut
                } else {
                    browser(hub: hub)
                        // Again once the Core has the token of a new sign-in.
                        .task(id: "\(github.user?.login ?? "")|\(hub.credentialGeneration)") {
                            let login = github.user?.login
                            if model.needsReload(for: login) { await model.load(hub: hub, login: login) }
                        }
                }
            } else {
                UnavailableFeature(title: "GitHub is not available", detail: "Runnir Core or the GitHub account is not set up in this build.", symbol: "exclamationmark.triangle")
            }
        }
        .sheet(isPresented: $showingConnect) { if let github = desktop.github { GitHubConnectView(session: github) } }
        // Registered clones are matched to GitHub repositories right away,
        // not only once they are opened.
        .task(id: "\(desktop.snapshot.workspaces.map(\.id))|\(coreReady)") { await desktop.findGitHubOrigins() }
    }

    private var coreReady: Bool {
        if case .ready = desktop.core?.status { return true }
        return false
    }

    private var signedOut: some View {
        let again = desktop.github?.signedOutAccess == .tokenRejected
        return VStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.questionmark").font(.system(size: 26, weight: .light)).foregroundStyle(RunnirTheme.primary)
            Text(again ? "Sign in to GitHub again" : "Connect GitHub to see your repositories").font(.system(size: 16, weight: .semibold))
            Text(again ? "GitHub no longer accepts the saved sign-in, for example because it was revoked. Sign in again to see your repositories."
                       : "Runnir lists the repositories where the Runnir Desktop app is installed, with their workflows and runs.")
                .font(.system(size: 13)).foregroundStyle(RunnirTheme.secondaryForeground).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button(again ? "Sign In Again..." : "Connect GitHub...") { showingConnect = true }.buttonStyle(DesignButtonStyle(primary: true))
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func browser(hub: CoreHub) -> some View {
        HStack(spacing: 0) {
            list(hub: hub).frame(width: 330)
            DesignDivider(vertical: true)
            Group {
                if let repository = model.selected {
                    RemoteRepositoryDetail(repository: repository, desktop: desktop, hub: hub)
                        .id(repository.fullName)
                } else {
                    UnavailableFeature(title: "Choose a repository", detail: "Its workflows, their latest runs and recent runs appear here.", symbol: "shippingbox")
                        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(RunnirTheme.border))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func list(hub: CoreHub) -> some View {
        @Bindable var model = model
        let visible = model.visible(favorites: desktop.repositoryFavorites)
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Search repositories", text: $model.search).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("repository-search")
                Button { Task { await model.load(hub: hub, login: desktop.github?.user?.login) } } label: {
                    Image(systemName: "arrow.clockwise")
                }.buttonStyle(.borderless).disabled(model.isLoading).help("Read the repositories from GitHub again")
            }.padding(10)
            HStack(spacing: 8) {
                Picker("Owner", selection: $model.owner) {
                    Text("All owners").tag(String?.none)
                    ForEach(model.installations) { installation in
                        Text(installation.account).tag(Optional(installation.account))
                    }
                }.labelsHidden().fixedSize()
                Toggle("Starred", isOn: $model.starredOnly).toggleStyle(.checkbox).font(.system(size: 12))
                Spacer()
            }.padding(.horizontal, 10).padding(.bottom, 8)
            DesignDivider()
            listStatus
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visible) { repository in
                        RepositoryListRow(repository: repository, selected: repository.fullName == model.selectedFullName,
                                          starred: desktop.repositoryFavorites.isFavorite(repository.fullName),
                                          hasWorkspace: desktop.workspace(forGitHubRepository: repository.fullName) != nil,
                                          canStar: desktop.repositoryFavorites.isAvailable,
                                          select: { model.selectedFullName = repository.fullName },
                                          toggleStar: { desktop.repositoryFavorites.toggle(repository.fullName) })
                        DesignDivider()
                    }
                }
            }
            if visible.isEmpty, !model.repositories.isEmpty {
                Text("No repositories match.").font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground).padding(16)
            }
            Spacer(minLength: 0)
            footer
        }
    }

    @ViewBuilder private var listStatus: some View {
        if model.isLoading && model.repositories.isEmpty {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading repositories...") }
                .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground).padding(16)
        } else if let access = model.access, let help = Self.listHelp(access, credential: desktop.core?.credentialKind) {
            GitHubAccessNotice(help: help, style: .banner, github: desktop.github) {
                if let hub = desktop.core { Task { await model.load(hub: hub, login: desktop.github?.user?.login) } }
            }.padding(8)
        } else if model.access == .ok, model.installations.isEmpty, !model.credentialKind.isPersonal {
            GitHubAccessNotice(help: GitHubAccessHelp(title: "Runnir Desktop is not installed yet",
                                                      message: "Install the Runnir Desktop app on your account or an organization, and choose the repositories it may reach.",
                                                      fix: .giveAccess(GitHubAccessHelp.installationURL)),
                               style: .banner, github: desktop.github).padding(8)
        }
        // Installations that wait for an owner: suspended, or new permissions.
        ForEach(model.installations.filter { $0.suspended || !$0.missingPermissions.isEmpty }) { installation in
            if let help = installation.suspended
                ? GitHubAccessHelp.installationBlocker(installation, purpose: .read, refused: true)
                : GitHubAccessHelp.pendingPermissions(installation) {
                GitHubAccessNotice(help: help, style: .banner, github: desktop.github).padding(.horizontal, 8).padding(.bottom, 8)
            }
        }
        if let problem = desktop.repositoryFavorites.problem {
            Label(problem, systemImage: "star.slash").font(.system(size: 11)).foregroundStyle(RunnirTheme.warning).padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            DesignDivider()
            HStack {
                Text(countText).font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                Spacer()
                if model.credentialKind.isPersonal {
                    Button("Token Settings...") { openURL(GitHubAccessHelp.tokenSettingsURL(model.credentialKind)) }
                        .buttonStyle(.link).font(.system(size: 11))
                        .help("Signed in with a personal access token: the repositories it reaches are set on GitHub")
                } else {
                    Button("More Repositories...") { openURL(GitHubAppConfiguration.runnirDesktop.installationURL) }
                        .buttonStyle(.link).font(.system(size: 11))
                        .help("Install Runnir Desktop on more accounts or repositories on GitHub")
                }
            }.padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private var countText: String {
        let count = model.repositories.count
        let base = count == 1 ? "1 repository" : "\(count) repositories"
        return model.truncated ? base + " (the first 1,000)" : base
    }

    /// The list's banner: the account's repositories are not about one
    /// repository, so refusals point at the app's installations.
    static func listHelp(_ access: CoreGitHubAccess, credential: CoreGitHubCredentialKind? = nil) -> GitHubAccessHelp? {
        switch access {
        case .ok, .noRemote: return nil
        case .notVisible, .permissionMissing:
            if let credential, credential.isPersonal {
                return GitHubAccessHelp(title: "GitHub did not let this token list repositories",
                                        message: "Check the token's repository access and permissions on GitHub. The list shows what was read last.",
                                        fix: .editToken(GitHubAccessHelp.tokenSettingsURL(credential)))
            }
            return GitHubAccessHelp(title: "GitHub did not let Runnir list repositories",
                                    message: "Check where the Runnir Desktop app is installed and what it may reach. The list shows what was read last.",
                                    fix: .giveAccess(GitHubAccessHelp.installationURL))
        default:
            return GitHubAccessHelp.forAccess(access, repository: "your account", purpose: .read, credential: credential)
        }
    }
}

private struct RepositoryListRow: View {
    let repository: CoreGitHubAccountRepository
    let selected: Bool
    let starred: Bool
    let hasWorkspace: Bool
    let canStar: Bool
    let select: () -> Void
    let toggleStar: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggleStar) {
                Image(systemName: starred ? "star.fill" : "star")
                    .foregroundStyle(starred ? RunnirTheme.warning : RunnirTheme.mutedForeground)
            }
            .buttonStyle(.plain).disabled(!canStar)
            .help(starred ? "Remove from starred" : "Star this repository")
            .accessibilityLabel(starred ? "Remove from starred" : "Star")
            Button(action: select) {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 0) {
                            Text(repository.owner + "/").foregroundStyle(RunnirTheme.secondaryForeground)
                            Text(repository.name).fontWeight(.medium)
                        }.font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                        HStack(spacing: 6) {
                            if repository.visibility != "public" { badge(repository.visibility.capitalized) }
                            if repository.archived { badge("Archived") }
                            if hasWorkspace { badge("Workspace") }
                            if let pushed = repository.pushedAt {
                                Text(pushed, format: .relative(presentation: .named)).font(.system(size: 11)).foregroundStyle(RunnirTheme.mutedForeground)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(selected ? RunnirTheme.selected : .clear)
        .accessibilityElement(children: .contain)
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.system(size: 10)).foregroundStyle(RunnirTheme.secondaryForeground)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(RunnirTheme.border))
    }
}

/// The selected repository: open it as a workspace or on GitHub, its
/// workflows with their latest runs, and its newest runs.
private struct RemoteRepositoryDetail: View {
    let repository: CoreGitHubAccountRepository
    let desktop: DesktopCoordinator
    let hub: CoreHub
    @State private var model: RemoteRepositoryModel
    @State private var runRequest: RunWorkflowRequest?
    /// What stops starting a workflow, shown as an alert.
    @State private var accessHelp: GitHubAccessHelp?
    @Environment(\.openURL) private var openURL

    /// The installation the repository came from, with any permissions
    /// waiting for an owner.
    private var installation: CoreGitHubInstallation? {
        desktop.githubRepositories.installations.first { $0.id == repository.installationID }
    }

    /// The repository as the access help needs it.
    private var details: CoreGitHubRepository {
        CoreGitHubRepository(access: .ok, fullName: repository.fullName, visibility: repository.visibility,
                             defaultBranch: repository.defaultBranch, htmlURL: repository.htmlURL,
                             canPush: repository.canPush, installation: installation)
    }

    /// Opens Run Workflow, or says in an alert what has to happen first.
    private func requestRun(_ workflow: CoreGitHubWorkflow) {
        if let blocker = GitHubAccessHelp.blocker(for: .run, repository: repository, installation: installation) {
            accessHelp = blocker
            return
        }
        runRequest = RunWorkflowRequest(workflowID: workflow.id)
    }

    init(repository: CoreGitHubAccountRepository, desktop: DesktopCoordinator, hub: CoreHub) {
        self.repository = repository
        self.desktop = desktop
        self.hub = hub
        _model = State(initialValue: RemoteRepositoryModel(fullName: repository.fullName))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                workflowsSection
                runsSection
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await model.load(hub: hub) }
        // While a run is queued or in progress, read again every 10 seconds;
        // a run started from here restarts it.
        .task(id: model.hasActiveRuns) {
            guard model.hasActiveRuns else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                await model.load(hub: hub)
            }
        }
        .githubAccessAlert($accessHelp, github: desktop.github)
        .sheet(item: $runRequest) { request in
            RunWorkflowSheet(model: DispatchFormModel(target: model.target, hub: hub, workflows: model.workflows?.items ?? [],
                                                      workflowID: request.workflowID, currentBranch: repository.defaultBranch),
                             github: desktop.github) { run in
                if let url = run.htmlURL { openURL(url) }
            }
            .onDisappear { Task { await model.load(hub: hub) } }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(repository.fullName).font(.system(size: 17, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Button { Task { await model.load(hub: hub) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(model.isLoading).help("Read workflows and runs again")
            }
            if !repository.description.isEmpty {
                Text(repository.description).font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if let workspace = desktop.workspace(forGitHubRepository: repository.fullName) {
                    Button { desktop.openOrFocus(workspace) } label: { Label("Open Workspace", systemImage: "folder") }
                        .buttonStyle(DesignButtonStyle(primary: true))
                        .help("Open \(workspace.name), the local clone registered in Runnir")
                } else {
                    Button { desktop.importRepository() } label: { Label("Add Local Clone...", systemImage: "folder.badge.plus") }
                        .buttonStyle(DesignButtonStyle())
                        .disabled(desktop.persistenceBlocked)
                        .help("Choose a folder where this repository is already cloned. Runnir does not clone repositories.")
                }
                if let url = repository.htmlURL {
                    Button { openURL(url) } label: { Label("Open on GitHub", systemImage: "arrow.up.right.square") }
                        .buttonStyle(DesignButtonStyle())
                }
            }
            // What stops starting workflows here: an owner's pending
            // approval, or no write access.
            if let help = GitHubAccessHelp.blocker(for: .run, repository: repository, installation: installation) {
                GitHubAccessNotice(help: help, style: .note, github: desktop.github)
            }
        }
    }

    private var workflowsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "WORKFLOWS")
            DesignDivider()
            if let access = model.access,
               let help = GitHubAccessHelp.forAccess(access, repository: repository.fullName, purpose: .read, details: details,
                                                     credential: desktop.core?.credentialKind) {
                GitHubAccessNotice(help: help, style: .note, github: desktop.github) { Task { await model.load(hub: hub) } }
            }
            if let workflows = model.workflows {
                if workflows.access == .ok, workflows.items.isEmpty {
                    Text("This repository has no workflows on GitHub.").font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                }
                ForEach(workflows.items) { workflow in
                    HStack(spacing: 10) {
                        if let run = model.latestRun(workflow) {
                            RunOutcomeIcon(outcome: run.outcome, size: 12)
                        } else {
                            Image(systemName: "circle").font(.system(size: 12)).foregroundStyle(RunnirTheme.mutedForeground)
                                .accessibilityLabel("No recent run")
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(workflow.name).font(.system(size: 13)).lineLimit(1)
                            Text(workflow.path).font(.system(size: 11)).foregroundStyle(RunnirTheme.mutedForeground).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if workflow.state != "active" {
                            Text("Disabled").font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                        }
                        if workflow.path.hasPrefix(".github/workflows/") {
                            Button("Run...") { requestRun(workflow) }
                                .buttonStyle(DesignButtonStyle())
                                .disabled(!workflow.canBeStartedByHand || repository.archived)
                                .help(runHelp(workflow))
                        }
                    }.padding(.vertical, 4)
                }
            } else if model.isLoading {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading workflows...") }
                    .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
            }
        }
    }

    private func runHelp(_ workflow: CoreGitHubWorkflow) -> String {
        if repository.archived { return "An archived repository cannot run workflows" }
        if workflow.state != "active" { return "This workflow is disabled on GitHub" }
        if let blocker = GitHubAccessHelp.blocker(for: .run, repository: repository, installation: installation) { return blocker.title }
        return "Choose a branch and inputs, review, then start this workflow on GitHub"
    }

    private var runsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "RECENT RUNS")
            DesignDivider()
            if let runs = model.runs, runs.access == .ok, runs.items.isEmpty {
                Text("No runs yet.").font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
            }
            ForEach(Array((model.runs?.items ?? []).prefix(10))) { run in
                Button { if let url = run.htmlURL { openURL(url) } } label: { RunRow(run: run).contentShape(Rectangle()) }
                    .buttonStyle(.plain).disabled(run.htmlURL == nil).help("Open this run on GitHub")
            }
        }
    }
}
