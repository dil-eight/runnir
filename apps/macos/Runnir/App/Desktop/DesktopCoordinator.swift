import AppKit
import SwiftUI
import Observation

@MainActor
protocol WorkspaceWindowManaging: AnyObject {
    var record: WorkspaceWindowRecord { get set }
    var grant: (any RepositoryGranting)? { get }
    var window: NSWindow? { get }
    func attach(record: WorkspaceWindowRecord, workspace: WorkspaceRecord, grant: any RepositoryGranting)
    func showWindow(_ sender: Any?)
    func showSwitcher()
    /// Shows where a search result leads, in this window.
    func navigate(to destination: SearchDestination)
    /// What has edits not saved: the workflow file in the editor and
    /// Secrets and Variables; empty when nothing does.
    var unsavedNames: [String] { get }
    /// Saves those edits; false when any could not be saved.
    func saveUnsavedChanges() async -> Bool
}

extension WorkspaceWindowManaging {
    func showSwitcher() {}
    func navigate(to destination: SearchDestination) {}
    var unsavedNames: [String] { [] }
    func saveUnsavedChanges() async -> Bool { true }
}

@MainActor
@Observable
final class DesktopCoordinator {
    private(set) var snapshot = DesktopSnapshot()
    private(set) var isLoading = true
    var message: String?
    private(set) var persistenceBlocked = false
    @ObservationIgnored private var store: (any DesktopStateStoring)?
    @ObservationIgnored private var manager: NSWindow?
    @ObservationIgnored private var pullRequestsWindow: NSWindow?
    /// Settings, shown over one window at a time: opening them in another
    /// window closes them in the first.
    private(set) var settings: SettingsPresentation?
    /// The section Settings open at, the one shown last.
    @ObservationIgnored private var lastSettingsSection: SettingsSection = .account
    /// The Workspace Manager's id among windows that can show Settings.
    static let managerWindowID = UUID()

    /// Shows Settings over a window, at a section or the one shown last.
    func showSettings(in windowID: UUID, section: SettingsSection? = nil) {
        let section = section ?? settings?.section ?? lastSettingsSection
        lastSettingsSection = section
        settings = SettingsPresentation(windowID: windowID, section: section)
    }

    func showSettingsSection(_ section: SettingsSection) {
        guard let settings else { return }
        showSettings(in: settings.windowID, section: section)
    }

    func closeSettings() { settings = nil }

    /// Settings over the window in front: a workspace window, or the
    /// Workspace Manager, opened when no Runnir window is in front.
    func showSettingsInFrontWindow(section: SettingsSection? = nil) {
        if let key = NSApp.keyWindow ?? NSApp.mainWindow,
           let id = windows.first(where: { $0.value.window === key })?.key {
            showSettings(in: id, section: section)
            return
        }
        showManager()
        showSettings(in: Self.managerWindowID, section: section)
    }

    /// The Enterprise servers, for their names in lists and notices; set by
    /// the app delegate.
    @ObservationIgnored var enterpriseServers: EnterpriseServers?

    /// Enterprise server names by server id.
    var enterpriseServerNames: [String: String] {
        Dictionary((enterpriseServers?.servers ?? []).map { ($0.ref.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    /// An Enterprise server's name; nil for github.com or an unknown id.
    func serverName(for serverID: String?) -> String? {
        guard let serverID, !serverID.isEmpty else { return nil }
        return enterpriseServerNames[serverID]
    }
    @ObservationIgnored private var splash: NSWindow?
    @ObservationIgnored private var windows: [UUID: any WorkspaceWindowManaging] = [:]
    @ObservationIgnored private let makeGrant: (WorkspaceRecord) throws -> any RepositoryGranting
    @ObservationIgnored private let makeWorkspaceWindow: (WorkspaceWindowRecord, WorkspaceRecord, (any RepositoryGranting)?, DesktopCoordinator) -> any WorkspaceWindowManaging
    @ObservationIgnored private var geometryTask: Task<Void, Never>?
    @ObservationIgnored private var bootTask: Task<Void, Never>?
    @ObservationIgnored var terminationInProgress = false
    /// Asks before quitting or closing a window stops a local run; tests
    /// replace it.
    @ObservationIgnored var confirmStoppingLocalRuns: @MainActor (LocalRunStopPrompt) -> Bool = LocalRunStopPrompt.ask
    /// Asks before unsaved workflow edits would be lost; tests replace it.
    @ObservationIgnored var confirmUnsavedChanges: @MainActor ([String]) -> UnsavedChoice = UnsavedChangesPrompt.ask(files:)
    let accountState = AppState()
    /// The app's connection to the single Core process; nil in tests that do not need it.
    let core: CoreHub?
    /// The app-wide GitHub account; nil in tests that do not need it.
    let github: GitHubSession?
    /// Saved Run Workflow presets, kept on this Mac.
    let presets: DispatchPresetLibrary
    /// Favorite workflows of each workspace, kept on this Mac.
    let favorites: WorkflowFavorites
    /// Workflows whose concurrency suggestion the user turned off, per workspace.
    let hintDismissals: ConcurrencyHintDismissals
    /// Repositories starred in the Workspace Manager's GitHub tab.
    let repositoryFavorites: RepositoryFavorites
    /// The GitHub tab's list, kept while the Manager is closed.
    let githubRepositories = GitHubRepositoriesModel()
    /// The user's pull requests, for the menu bar and the Pull Requests window.
    let pullRequests: PullRequestsModel
    /// The user's failed and running runs across repositories (B39), for
    /// the Runs tab and the menu bar icon.
    let watchedRuns: WatchedRunsModel
    /// The Pull Requests window's global shortcut.
    let shortcuts = GlobalShortcutCenter()
    /// Secrets and variables for local runs, per workspace.
    let localRunValues: any LocalRunValueStoring
    /// The notifications Runnir sent, for the bell of every window.
    let inbox: NotificationInbox

    init(store: (any DesktopStateStoring)? = nil,
         core: CoreHub? = nil,
         github: GitHubSession? = nil,
         presets: DispatchPresetLibrary = DispatchPresetLibrary(store: nil),
         favorites: WorkflowFavorites = WorkflowFavorites(store: nil),
         hintDismissals: ConcurrencyHintDismissals = ConcurrencyHintDismissals(),
         repositoryFavorites: RepositoryFavorites = RepositoryFavorites(store: nil),
         pullRequests: PullRequestsModel = PullRequestsModel(store: nil),
         watchedRuns: WatchedRunsModel = WatchedRunsModel(store: nil),
         localRunValues: any LocalRunValueStoring = InMemoryLocalRunValueStore(),
         inbox: NotificationInbox = NotificationInbox(store: nil),
         makeGrant: @escaping (WorkspaceRecord) throws -> any RepositoryGranting = { try RepositoryGrant(record: $0) },
         makeWorkspaceWindow: @escaping (WorkspaceWindowRecord, WorkspaceRecord, (any RepositoryGranting)?, DesktopCoordinator) -> any WorkspaceWindowManaging = {
             WorkspaceWindowController(record: $0, workspace: $1, grant: $2, desktop: $3)
         }) {
        self.store = store
        self.core = core
        self.github = github
        self.presets = presets
        self.favorites = favorites
        self.hintDismissals = hintDismissals
        self.repositoryFavorites = repositoryFavorites
        self.pullRequests = pullRequests
        self.watchedRuns = watchedRuns
        self.localRunValues = localRunValues
        self.inbox = inbox
        self.makeGrant = makeGrant
        self.makeWorkspaceWindow = makeWorkspaceWindow
    }

    func loadSession() async {
        do {
            let storage: any DesktopStateStoring
            if let store { storage = store } else { storage = try FileDesktopStateStore.live() }
            store = storage
            let loaded = try await Task.detached { try storage.load() }.value
            guard !Task.isCancelled, !terminationInProgress else { return }
            snapshot = loaded
        } catch {
            guard !terminationInProgress else { return }
            persistenceBlocked = true
            message = "Local session could not be read. Your repository files have not been changed."
        }
        isLoading = false
    }

    func start() {
        guard bootTask == nil else { return }
        splash = makeWindow(size: NSSize(width: 480, height: 280), title: "Runnir", borderless: true)
        splash?.contentViewController = NSHostingController(rootView: StartupSplashView())
        splash?.makeKeyAndOrderFront(nil)
        bootTask = Task {
            await loadSession()
            guard !Task.isCancelled, !terminationInProgress else { return }
            for record in snapshot.windows { restore(record) }
            #if DEBUG
            importFoldersFromTestEnvironment()
            #endif
            if windows.isEmpty { showManager() }
            splash?.close()
            splash = nil
        }
    }

    #if DEBUG
    /// Debug-only hook for UI tests and the resource measurement script: with
    /// `--ui-testing`, folders listed in RUNNIR_UI_TEST_IMPORT_PATHS (colon
    /// separated) are registered and opened as if chosen in the open panel, so
    /// their bookmarks belong to this app.
    private func importFoldersFromTestEnvironment() {
        let environment = ProcessInfo.processInfo.environment
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing"),
              let list = environment["RUNNIR_UI_TEST_IMPORT_PATHS"] else { return }
        for path in list.split(separator: ":") where !path.isEmpty {
            register(selected: URL(fileURLWithPath: String(path), isDirectory: true))
        }
    }
    #endif

    func showManager() {
        if manager == nil {
            // Wide enough for the GitHub tab's list next to a repository.
            let window = makeWindow(size: NSSize(width: 1000, height: 660), title: "Workspaces")
            window.minSize = NSSize(width: 820, height: 520)
            window.contentViewController = NSHostingController(rootView: WorkspaceManagerView(desktop: self).handPointerButtons())
            window.setContentSize(NSSize(width: 1000, height: 660))
            window.identifier = NSUserInterfaceItemIdentifier("workspace-manager")
            // Only the close button: the Manager is not minimized or zoomed.
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.collectionBehavior.insert(.fullScreenNone)
            manager = window
        }
        manager?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The Pull Requests window: open pull requests with their CI and those
    /// closed in the last day, or the user's runs across repositories.
    func showPullRequests() {
        if pullRequestsWindow == nil {
            let window = makeWindow(size: NSSize(width: 560, height: 640), title: "Pull Requests")
            window.minSize = NSSize(width: 480, height: 360)
            let hosting = NSHostingController(rootView: PullRequestsWindowView(model: pullRequests, desktop: self)
                .environment(\.openRunnirSettings) { [weak self] section in self?.showSettingsInFrontWindow(section: section) }
                .handPointerButtons())
            // The window's title follows the tab: "Pull Requests" or "Runs".
            hosting.sceneBridgingOptions = [.title]
            window.contentViewController = hosting
            window.setContentSize(NSSize(width: 560, height: 640))
            window.identifier = NSUserInterfaceItemIdentifier("pull-requests")
            // The shortcut works from any app: the window comes to the Space
            // the user is on instead of switching to its own.
            window.collectionBehavior.insert(.moveToActiveSpace)
            pullRequestsWindow = window
        }
        guard let window = pullRequestsWindow else { return }
        // Runnir may be hidden or the window minimized when the shortcut is
        // pressed in another app.
        if NSApp.isHidden { NSApp.unhide(nil) }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // In front even when macOS keeps another app active.
        window.orderFrontRegardless()
    }

    /// "Open Quickly": the switcher in the key workspace window, or the
    /// Workspace Manager when no workspace window is in front.
    func showSwitcher() {
        if let controller = windows.values.first(where: { $0.window?.isKeyWindow == true }) {
            controller.showSwitcher()
        } else {
            showManager()
        }
    }

    /// The window of a workspace window record, for sheets shown on it.
    func window(_ windowID: UUID) -> NSWindow? { windows[windowID]?.window }

    func openCount(_ workspaceID: UUID) -> Int {
        windows.values.filter { $0.record.workspaceID == workspaceID }.count
    }

    func focus(_ workspaceID: UUID) {
        windows.values.first { $0.record.workspaceID == workspaceID }?.window?.makeKeyAndOrderFront(nil)
        manager?.orderOut(nil)
    }

    func importRepository(relinkID: UUID? = nil, reuseWindowID: UUID? = nil) {
        guard !isLoading, !persistenceBlocked else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = relinkID == nil ? "Import Repository" : "Locate Repository"
        panel.message = "Choose a local Git working tree. Runnir changes a workflow file in it only when you save that file."
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        register(selected: selected, relinkID: relinkID, reuseWindowID: reuseWindowID)
    }

    /// Registers a chosen folder and opens it in a window. The open panel and the
    /// debug import hook both end here.
    private func register(selected: URL, relinkID: UUID? = nil, reuseWindowID: UUID? = nil) {
        // A new window would not fit: say so before saving a registration.
        if relinkID == nil, reuseWindowID == nil, snapshot.windows.count >= DesktopSnapshot.maxWindows {
            message = Self.tooManyWindowsMessage
            return
        }
        let accessing = selected.startAccessingSecurityScopedResource()
        defer { if accessing { selected.stopAccessingSecurityScopedResource() } }
        do {
            let root = try RepositoryReader.canonicalRepository(selected)
            let bookmark = try selected.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                      includingResourceValuesForKeys: nil, relativeTo: nil)
            var candidate = snapshot
            if let conflicting = candidate.workspaces.first(where: { $0.path == root.path }),
               let relinkID, conflicting.id != relinkID {
                message = "This folder is already registered as another workspace. Open that workspace instead."
                return
            }
            let identity = relinkID ?? candidate.workspaces.first(where: { $0.path == root.path })?.id ?? UUID()
            let record = WorkspaceRecord(id: identity, path: root.path, name: root.lastPathComponent,
                                         bookmark: bookmark, lastOpenedAt: Date())
            if relinkID != nil {
                try relinkWorkspace(record)
                if openCount(identity) > 0 { focus(identity) }
                else { try open(record, reuseWindowID: reuseWindowID) }
            } else {
                candidate.workspaces.removeAll { $0.id == identity }
                candidate.workspaces.append(record)
                try commit(candidate)
                try open(record, reuseWindowID: reuseWindowID)
            }
        } catch RepositoryAccessError.notRepository {
            message = "This folder is not a Git working tree. Choose a folder containing a .git marker."
        } catch DesktopStoreError.tooManyWindows {
            message = Self.tooManyWindowsMessage
        } catch {
            message = "The repository could not be opened. Check folder access or choose Locate to grant access again."
        }
    }

    func relinkWorkspace(_ workspace: WorkspaceRecord) throws {
        guard !isLoading, snapshot.workspaces.contains(where: { $0.id == workspace.id }) else {
            throw DesktopStoreError.invalidState
        }
        var prepared: [(any WorkspaceWindowManaging, any RepositoryGranting)] = []
        do {
            for controller in windows.values where controller.record.workspaceID == workspace.id {
                prepared.append((controller, try makeGrant(workspace)))
            }
            var candidate = snapshot
            candidate.workspaces.removeAll { $0.id == workspace.id }
            candidate.workspaces.append(workspace)
            try commit(candidate)
        } catch {
            for (_, grant) in prepared { grant.stop() }
            throw error
        }
        for (controller, grant) in prepared {
            controller.attach(record: controller.record, workspace: workspace, grant: grant)
            core?.attach(windowID: controller.record.id, workspaceID: workspace.id, path: workspace.path)
        }
    }

    static let tooManyWindowsMessage = "Runnir keeps at most \(DesktopSnapshot.maxWindows) windows open. Close a window to open another."

    func openRegistered(_ workspace: WorkspaceRecord, reuseWindowID: UUID? = nil) {
        do { try open(workspace, reuseWindowID: reuseWindowID) }
        catch DesktopStoreError.tooManyWindows { message = Self.tooManyWindowsMessage }
        catch { message = "Workspace unavailable. Locate the folder to restore access; existing windows are unchanged." }
    }

    private func open(_ workspace: WorkspaceRecord, reuseWindowID: UUID? = nil) throws {
        guard !isLoading else { throw DesktopStoreError.invalidState }
        if reuseWindowID == nil, snapshot.windows.count >= DesktopSnapshot.maxWindows { throw DesktopStoreError.tooManyWindows }
        let grant = try makeGrant(workspace)
        let workspace = reconcile(workspace, with: grant)
        var candidate = snapshot
        if let index = candidate.workspaces.firstIndex(where: { $0.id == workspace.id }) {
            candidate.workspaces[index].lastOpenedAt = Date()
        }
        if let reuseWindowID, let current = windows[reuseWindowID] {
            if current.record.workspaceID != workspace.id, case let names = current.unsavedNames, !names.isEmpty {
                switch confirmUnsavedChanges(names) {
                case .cancel:
                    grant.stop()
                    return
                case .save:
                    grant.stop()
                    Task {
                        if await current.saveUnsavedChanges() { openRegistered(workspace, reuseWindowID: reuseWindowID) }
                    }
                    return
                case .discard:
                    break
                }
            }
            // Another workspace in this window closes the current one when
            // this was its last window, which stops its local run.
            if current.record.workspaceID != workspace.id, let core, let run = core.localRunEnding(withWindow: reuseWindowID),
               !confirmStoppingLocalRuns(LocalRunStopPrompt(action: .switchWorkspace, runs: [core.describe(run)])) {
                grant.stop()
                return
            }
            candidate.associate(windowID: reuseWindowID, workspaceID: workspace.id)
            guard let record = candidate.windows.first(where: { $0.id == reuseWindowID }) else {
                grant.stop()
                return
            }
            do { try commit(candidate) } catch { grant.stop(); throw error }
            current.attach(record: record, workspace: workspace, grant: grant)
            core?.attach(windowID: reuseWindowID, workspaceID: workspace.id, path: workspace.path)
            current.window?.makeKeyAndOrderFront(nil)
        } else {
            let record = WorkspaceWindowRecord(id: UUID(), workspaceID: workspace.id)
            candidate.windows.append(record)
            do { try commit(candidate) } catch { grant.stop(); throw error }
            let reference = frontWorkspaceWindow?.frame
            let controller = makeWorkspaceWindow(record, workspace, grant, self)
            // A new window opens down and to the right of the one in front,
            // not on top of it.
            if let reference, let window = controller.window {
                let screen = NSScreen.screens.first { $0.frame.intersects(reference) }?.visibleFrame ?? reference
                window.setFrame(Self.cascadedFrame(size: window.frame.size, after: reference, in: screen), display: false)
            }
            windows[record.id] = controller
            core?.attach(windowID: record.id, workspaceID: workspace.id, path: workspace.path)
            controller.showWindow(nil)
        }
        manager?.orderOut(nil)
        message = nil
    }

    /// The workspace window nearest the front.
    private var frontWorkspaceWindow: NSWindow? {
        NSApp?.orderedWindows.first { window in windows.values.contains { $0.window === window } && window.isVisible }
    }

    /// Where a new window goes: its top left 26 points right of and below
    /// `reference`'s, back to the top left of `screen` when it would not fit.
    static func cascadedFrame(size: NSSize, after reference: NSRect, in screen: NSRect, step: CGFloat = 26) -> NSRect {
        var frame = NSRect(x: reference.minX + step, y: reference.maxY - step - size.height, width: size.width, height: size.height)
        if frame.maxX > screen.maxX || frame.minY < screen.minY {
            frame.origin = NSPoint(x: screen.minX + step, y: screen.maxY - step - size.height)
        }
        return frame
    }

    private func restore(_ record: WorkspaceWindowRecord) {
        guard var workspace = snapshot.workspaces.first(where: { $0.id == record.workspaceID }) else { return }
        let grant = try? makeGrant(workspace)
        if let grant { workspace = reconcile(workspace, with: grant) }
        let controller = makeWorkspaceWindow(record, workspace, grant, self)
        windows[record.id] = controller
        // Without a grant the folder is missing; the window offers to locate it.
        if grant != nil { core?.attach(windowID: record.id, workspaceID: workspace.id, path: workspace.path) }
        controller.showWindow(nil)
    }

    /// Keeps a workspace record in step with what its grant resolved: a fresh
    /// bookmark for a stale one, and the folder's current path after a move,
    /// so the next launch and the Core use the right folder. A name that was
    /// the old folder name follows a rename. When saving fails the resolved
    /// values are still used for this session.
    private func reconcile(_ workspace: WorkspaceRecord, with grant: any RepositoryGranting) -> WorkspaceRecord {
        var updated = workspace
        if let bookmark = grant.refreshedBookmark { updated.bookmark = bookmark }
        if grant.url.path != workspace.path {
            updated.path = grant.url.path
            if workspace.name == URL(fileURLWithPath: workspace.path).lastPathComponent {
                updated.name = grant.url.lastPathComponent
            }
        }
        guard updated != workspace,
              let index = snapshot.workspaces.firstIndex(where: { $0.id == workspace.id }) else { return updated }
        var candidate = snapshot
        candidate.workspaces[index].bookmark = updated.bookmark
        candidate.workspaces[index].path = updated.path
        candidate.workspaces[index].name = updated.name
        try? commit(candidate)
        return updated
    }

    func removeRegistration(_ workspace: WorkspaceRecord) {
        guard openCount(workspace.id) == 0 else { return }
        var candidate = snapshot
        candidate.workspaces.removeAll { $0.id == workspace.id }
        do {
            try commit(candidate)
            presets.removeAll(workspaceID: workspace.id)
            favorites.removeAll(workspaceID: workspace.id)
            hintDismissals.removeAll(workspaceID: workspace.id)
            Task { [localRunValues] in try? await localRunValues.removeAll(workspaceID: workspace.id) }
            // Its saved activity and local run history go too. A Core that is
            // not running leaves them; Settings › Storage then lists them as
            // a removed workspace to delete.
            if let core {
                Task { [weak self] in
                    if await !core.deleteWorkspaceData(workspace.id) {
                        self?.message = "\(workspace.name) was removed, but its saved data could not be deleted now. Settings › Storage lists it as a removed workspace."
                    }
                }
            }
        }
        catch { message = "Registration could not be removed. Repository files were not changed." }
    }

    /// The registered workspace whose origin is this repository, by its
    /// `GitHubRepositoryRef.key` ("owner/name" on github.com, "<server
    /// id>:owner/name" on an Enterprise server; not case-sensitive); the most
    /// recently opened when several are. A malformed key matches nothing; it
    /// never makes the registry unreadable.
    func workspace(forGitHubRepository key: String) -> WorkspaceRecord? {
        guard GitHubRepositoryRef(key: key) != nil else { return nil }
        return snapshot.workspaces
            .filter { $0.githubRepository?.caseInsensitiveCompare(key) == .orderedSame }
            .max { $0.lastOpenedAt < $1.lastOpenedAt }
    }

    func workspace(for ref: GitHubRepositoryRef) -> WorkspaceRecord? {
        workspace(forGitHubRepository: ref.key)
    }

    /// Remembers which GitHub repository a workspace's origin points at, by
    /// its key, so the GitHub tab can open its local clone.
    func noteGitHubRepository(_ key: String?, workspaceID: UUID) {
        guard let index = snapshot.workspaces.firstIndex(where: { $0.id == workspaceID }),
              snapshot.workspaces[index].githubRepository != key,
              key.map({ GitHubRepositoryRef(key: $0) != nil }) ?? true else { return }
        var candidate = snapshot
        candidate.workspaces[index].githubRepository = key
        try? commit(candidate)
    }

    /// Registered working trees whose origin Runnir asked about this launch.
    @ObservationIgnored private var originsAsked: Set<UUID> = []

    /// Finds the GitHub repository of registered working trees that Runnir
    /// has not opened since it began to remember it, so the GitHub tab can
    /// open their clones at once. Each is asked once per launch, through
    /// the Core, without opening it.
    func findGitHubOrigins() async {
        guard let core, !isLoading, !persistenceBlocked else { return }
        let pending = snapshot.workspaces.filter { $0.githubRepository == nil && !originsAsked.contains($0.id) }
        guard !pending.isEmpty, let found = await core.githubOrigins(paths: pending.map(\.path)) else { return }
        originsAsked.formUnion(pending.map(\.id))
        var candidate = snapshot
        var changed = false
        for index in candidate.workspaces.indices where candidate.workspaces[index].githubRepository == nil {
            guard let ref = found[candidate.workspaces[index].path], GitHubRepositoryRef(key: ref.key) != nil else { continue }
            candidate.workspaces[index].githubRepository = ref.key
            changed = true
        }
        if changed { try? commit(candidate) }
    }

    /// An entry of the bell's list was chosen: it is read, and what the
    /// notification was about opens, as when its notification is clicked.
    func openInboxEntry(_ entry: InboxEntry) {
        inbox.markRead(entry.id)
        if let url = entry.url {
            NSWorkspace.shared.open(url)
        } else if let id = entry.workspaceID, let workspace = snapshot.workspaces.first(where: { $0.id == id }) {
            openOrFocus(workspace)
        }
    }

    /// A search result was chosen in a window. Settings open over that window,
    /// a pull request opens on GitHub, anything else is shown in a window of
    /// the result's workspace: this one when it is the same, else the one
    /// opened or brought forward for it.
    func open(_ destination: SearchDestination, workspaceID: UUID?, from windowID: UUID) {
        switch destination {
        case .setting(let section):
            showSettings(in: windowID, section: section)
        case .pullRequest(let url):
            if let url { NSWorkspace.shared.open(url) }
        case .run, .runsList, .workflow, .localRuns:
            guard let workspaceID, let workspace = snapshot.workspaces.first(where: { $0.id == workspaceID }) else { return }
            if let own = windows[windowID], own.record.workspaceID == workspaceID {
                own.navigate(to: destination)
                return
            }
            showRun(destination, workspaceID: workspaceID)
        }
    }

    /// Shows a run in a window of its workspace, opened or brought forward,
    /// as a global search result does (B43).
    func showRun(_ destination: SearchDestination, workspaceID: UUID) {
        guard let workspace = snapshot.workspaces.first(where: { $0.id == workspaceID }) else { return }
        openOrFocus(workspace)
        windows.values.first { $0.record.workspaceID == workspaceID }?.navigate(to: destination)
    }

    /// What the Runs tab watches: workspaces' repositories, then starred ones (B39).
    var watchedRepositories: [CoreWatchedRepository] {
        WatchedRepositories.of(workspaces: snapshot.workspaces, isOpen: { openCount($0) > 0 }, starred: repositoryFavorites.names)
    }

    func openOrFocus(_ workspace: WorkspaceRecord) {
        if openCount(workspace.id) > 0 { focus(workspace.id) } else { openRegistered(workspace) }
    }

    /// A workflow file of a workspace was renamed: its star moves with it,
    /// and its presets are copied to the new name (see
    /// `DispatchPresetLibrary.copyWorkflowPresets`).
    func workflowRenamed(workspaceID: UUID, from oldPath: String, to newPath: String) {
        presets.copyWorkflowPresets(workspaceID: workspaceID, from: oldPath, to: newPath)
        favorites.moveWorkflow(workspaceID: workspaceID, from: oldPath, to: newPath)
    }

    func selectSection(_ section: AppSection, windowID: UUID) {
        guard let index = snapshot.windows.firstIndex(where: { $0.id == windowID }) else { return }
        var candidate = snapshot
        candidate.windows[index].section = section
        do { try commit(candidate); windows[windowID]?.record.section = section }
        catch { message = "Window navigation could not be saved." }
    }

    func selectRunsMode(_ mode: RunsMode, windowID: UUID) {
        guard let index = snapshot.windows.firstIndex(where: { $0.id == windowID }) else { return }
        var candidate = snapshot
        candidate.windows[index].runsMode = mode
        do { try commit(candidate); windows[windowID]?.record.runsMode = mode }
        catch { message = "Window navigation could not be saved." }
    }

    func shouldClose(_ id: UUID) -> Bool {
        if terminationInProgress { return true }
        if let controller = windows[id], case let names = controller.unsavedNames, !names.isEmpty {
            switch confirmUnsavedChanges(names) {
            case .cancel:
                return false
            case .save:
                // The window closes once the file is saved; a failed save
                // keeps it open with the reason in the editor.
                Task {
                    if await controller.saveUnsavedChanges() { controller.window?.performClose(nil) }
                }
                return false
            case .discard:
                break
            }
        }
        // The workspace's last window closes the repository in the Core,
        // which stops its local run.
        if let core, let run = core.localRunEnding(withWindow: id),
           !confirmStoppingLocalRuns(LocalRunStopPrompt(action: .closeWindow, runs: [core.describe(run)])) {
            return false
        }
        var candidate = snapshot
        candidate.closeWindow(id)
        do { try commit(candidate); return true }
        catch {
            showPersistenceAlert("The window could not be removed from the saved session. It will stay open so you can retry.")
            return false
        }
    }

    func didClose(_ id: UUID) {
        guard !terminationInProgress else { return }
        let grant = windows.removeValue(forKey: id)?.grant
        // The folder access ends only once the Core has closed the repository,
        // so a scan still running in the Core never loses it midway.
        if let core {
            core.detach(windowID: id) { grant?.stop() }
        } else {
            grant?.stop()
        }
    }

    func geometryChanged() {
        guard !terminationInProgress else { return }
        geometryTask?.cancel()
        geometryTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            do { try saveGeometry() } catch { message = "Window positions could not be saved." }
        }
    }

    private func saveGeometry() throws {
        var candidate = snapshot
        for index in candidate.windows.indices {
            if let frame = windows[candidate.windows[index].id]?.window?.frame {
                candidate.windows[index].frame = WindowGeometry(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
            }
        }
        try commit(candidate)
    }

    enum QuitDecision: Equatable {
        case proceed, cancel, saveFirst
    }

    /// Whether quitting can go ahead with the unsaved workflow edits of all
    /// windows: asks once for all of them.
    func unsavedEditsQuitDecision() -> QuitDecision {
        let names = windows.values.flatMap(\.unsavedNames).sorted()
        guard !names.isEmpty else { return .proceed }
        switch confirmUnsavedChanges(names) {
        case .save: return .saveFirst
        case .discard: return .proceed
        case .cancel: return .cancel
        }
    }

    /// Saves every window's unsaved edits; false when any could not be saved.
    func saveAllUnsavedWorkflows() async -> Bool {
        var saved = true
        for controller in windows.values where !controller.unsavedNames.isEmpty {
            if !(await controller.saveUnsavedChanges()) { saved = false }
        }
        return saved
    }

    /// Quitting stops the Core and with it every local run; asks first.
    func confirmQuitStopsLocalRuns() -> Bool {
        guard let core else { return true }
        let runs = core.activeLocalRuns
        guard !runs.isEmpty else { return true }
        return confirmStoppingLocalRuns(LocalRunStopPrompt(action: .quit, runs: runs.map(core.describe)))
    }

    func prepareToQuit() -> Bool {
        bootTask?.cancel()
        geometryTask?.cancel()
        guard !isLoading, !persistenceBlocked else { terminationInProgress = true; return true }
        do {
            try saveGeometry()
            terminationInProgress = true
            return true
        } catch {
            showPersistenceAlert("The current session could not be saved. Quit was cancelled; retry after checking available storage.")
            return false
        }
    }

    private func commit(_ candidate: DesktopSnapshot) throws {
        guard !isLoading, !persistenceBlocked, let store else { throw DesktopStoreError.ioFailure }
        try store.save(candidate)
        snapshot = candidate
    }

    func resetUnreadableSession() {
        guard persistenceBlocked, let fileStore = store as? FileDesktopStateStore else { return }
        let alert = NSAlert()
        alert.messageText = "Reset local workspace registration and session?"
        alert.informativeText = "The unreadable file will be preserved as a backup. Repository files, Keychain and other workspace data will not be deleted."
        alert.addButton(withTitle: "Back Up and Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            if FileManager.default.fileExists(atPath: fileStore.stateURL.path) {
                try FileManager.default.copyItem(at: fileStore.stateURL,
                    to: fileStore.directory.appendingPathComponent("desktop-state-unreadable-\(UUID().uuidString).json"))
            }
            try fileStore.save(DesktopSnapshot())
            snapshot = DesktopSnapshot()
            persistenceBlocked = false
            message = nil
        } catch { message = "The backup/reset failed. The original session has been preserved." }
    }

    private func showPersistenceAlert(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "Could not save session"
        alert.informativeText = text
        alert.runModal()
    }

    private func makeWindow(size: NSSize, title: String, borderless: Bool = false) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: borderless ? [.borderless] : [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .windowBackgroundColor
        window.center()
        return window
    }
}

@MainActor
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate, WorkspaceWindowManaging {
    var record: WorkspaceWindowRecord
    var grant: (any RepositoryGranting)?
    private let desktop: DesktopCoordinator
    private var state: AppState?

    init(record: WorkspaceWindowRecord, workspace: WorkspaceRecord, grant: (any RepositoryGranting)?, desktop: DesktopCoordinator) {
        self.record = record
        self.grant = grant
        self.desktop = desktop
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.minSize = NSSize(width: 980, height: 640)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.identifier = NSUserInterfaceItemIdentifier(record.id.uuidString)
        window.delegate = self
        window.center()
        if let saved = record.frame {
            let visible = NSScreen.screens.map(\.visibleFrame)
            let frame = NSRect(x: saved.x, y: saved.y, width: saved.width, height: saved.height)
            let screen = visible.max { $0.intersection(frame).width * $0.intersection(frame).height
                < $1.intersection(frame).width * $1.intersection(frame).height } ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
            let width = min(max(frame.width, 980), screen.width)
            let height = min(max(frame.height, 640), screen.height)
            window.setFrame(NSRect(x: min(max(frame.minX, screen.minX), screen.maxX - width),
                                   y: min(max(frame.minY, screen.minY), screen.maxY - height), width: width, height: height), display: false)
        }
        installContent(workspace)
    }

    required init?(coder: NSCoder) { nil }

    func attach(record: WorkspaceWindowRecord, workspace: WorkspaceRecord, grant: any RepositoryGranting) {
        // The same workspace with renewed folder access (Locate) keeps the
        // editor and Secrets and Variables with any edits in them; another
        // workspace starts fresh.
        let kept = record.workspaceID == self.record.workspaceID ? state : nil
        self.grant?.stop()
        self.grant = grant
        self.record = record
        installContent(workspace, keeping: kept)
    }

    /// The window's editor, for tests.
    var files: WorkspaceFilesModel? { state?.files }
    /// The window's Secrets and Variables, for tests.
    var values: WorkspaceValuesModel? { state?.values }

    private func installContent(_ workspace: WorkspaceRecord, keeping kept: AppState? = nil) {
        let frame = window?.frame
        let state = kept.map { AppState(files: $0.files, values: $0.values) } ?? AppState()
        self.state = state
        state.selectedSection = record.section.restored
        state.runsMode = record.runsMode ?? .list
        window?.title = workspace.name + " - Runnir"
        window?.contentViewController = NSHostingController(rootView:
            DesktopWorkspaceView(desktop: desktop, workspace: workspace, windowID: record.id, reader: grant?.reader)
                .environment(state)
                .handPointerButtons())
        if let frame { window?.setFrame(frame, display: false) }
    }

    func showSwitcher() {
        window?.makeKeyAndOrderFront(nil)
        state?.showingSwitcher = true
    }

    func navigate(to destination: SearchDestination) {
        window?.makeKeyAndOrderFront(nil)
        state?.go(to: destination)
    }

    var unsavedNames: [String] {
        var names: [String] = []
        if let files = state?.files, files.isDirty, let name = files.selected?.name { names.append(name) }
        if state?.values.isDirty == true { names.append("Secrets and Variables") }
        return names
    }

    func saveUnsavedChanges() async -> Bool {
        guard let state else { return true }
        var saved = true
        if state.files.isDirty {
            guard let core = desktop.core else { return false }
            saved = await state.files.save(hub: core, workspaceID: record.workspaceID)
            if saved { await state.files.validate(hub: core, workspaceID: record.workspaceID) }
        }
        if state.values.isDirty {
            saved = await state.values.save(workspaceID: record.workspaceID, store: desktop.localRunValues) && saved
        }
        return saved
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { desktop.shouldClose(record.id) }
    func windowWillClose(_ notification: Notification) { desktop.didClose(record.id) }
    func windowDidMove(_ notification: Notification) { desktop.geometryChanged() }
    func windowDidResize(_ notification: Notification) { desktop.geometryChanged() }
}

@MainActor
final class DesktopAppDelegate: NSObject, NSApplicationDelegate {
    let desktop: DesktopCoordinator
    /// The app's single Core process. Closing windows never stops it; quitting does.
    let core: CoreProcessSupervisor
    let coreHub: CoreHub
    let github: GitHubSession
    /// Enterprise servers next to github.com, with their Keychain tokens.
    let enterpriseServers: EnterpriseServers
    /// Sends run notifications; set once the app has launched.
    private var runNotifier: RunNotifier?

    override init() {
        let supervisor = CoreProcessSupervisor.bundled()
        let hub = CoreHub(provider: supervisor)
        core = supervisor
        coreHub = hub
        // One shared store: the Keychain is read once per launch.
        let credentials = CachingCredentialStore.keychain
        let api = GitHubRESTClient(baseURL: URL(string: "https://api.github.com")!, credentialStore: credentials)
        github = GitHubSession(
            deviceFlow: GitHubDeviceFlowClient(configuration: .runnirDesktop),
            credentials: credentials,
            api: api,
            openURL: { NSWorkspace.shared.open($0) }
        )
        enterpriseServers = EnterpriseServers.live()
        desktop = DesktopCoordinator(core: hub, github: github,
                                     presets: DispatchPresetLibrary(store: try? FileDispatchPresetStore.live()),
                                     favorites: WorkflowFavorites(store: try? FileWorkflowFavoritesStore.live()),
                                     repositoryFavorites: RepositoryFavorites(store: try? FileRepositoryFavoritesStore.live()),
                                     pullRequests: PullRequestsModel(store: try? FileDismissalStore.live(FileDismissalStore.pullRequestsFile)),
                                     watchedRuns: WatchedRunsModel(store: try? FileDismissalStore.live(FileDismissalStore.runsFile)),
                                     localRunValues: KeychainLocalRunValueStore(),
                                     inbox: NotificationInbox(store: try? FileNotificationInboxStore.live()))
        super.init()
        // The Core holds the token only while the user is signed in.
        hub.githubTokenProvider = { [github] in await github.currentToken() }
        github.onCredentialChange = { [hub] in hub.githubCredentialChanged() }
        github.tokenChecker = { [hub] token in await hub.checkGitHubToken(token) }
        hub.onGitHubTokenRejected = { [github] in await github.tokenWasRejected() }
        hub.enterpriseCredentialsProvider = { [enterpriseServers] in
            var out: [(server: GitHubServerRef, token: String)] = []
            for server in enterpriseServers.servers {
                if let token = await enterpriseServers.token(for: server.id) { out.append((server.ref, token)) }
            }
            return out
        }
        enterpriseServers.onChange = { [hub] in hub.githubCredentialChanged() }
        desktop.enterpriseServers = enterpriseServers
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              NSClassFromString("XCTestCase") == nil else { return }
        desktop.start()
        coreHub.startMonitoring()
        Task { [github] in await github.restore() }
        desktop.shortcuts.action = { [desktop] in desktop.showPullRequests() }
        desktop.shortcuts.applySettings()
        // Notifications from this Mac when pull request checks or local runs finish.
        let notifier = RunNotifier.live(inbox: desktop.inbox)
        notifier.showWorkspace = { [desktop] id in
            if let workspace = desktop.snapshot.workspaces.first(where: { $0.id == id }) { desktop.openOrFocus(workspace) }
        }
        runNotifier = notifier
        desktop.pullRequests.onChecksFinished = { [notifier] pr in notifier.notify(.checksFinished(pr)) }
        coreHub.onLocalRunFinished = { [notifier, desktop] run, folder in
            // The workspace's name as Runnir shows it; the folder's when it was closed.
            let name = desktop.snapshot.workspaces.first { $0.id == run.workspaceID }?.name ?? folder
            notifier.notify(.localRunFinished(run, workspaceName: name))
        }
        // Signed in to github.com or to any Enterprise server.
        desktop.pullRequests.startPolling(hub: coreHub, isSignedIn: { [github, coreHub] in github.user != nil || !coreHub.signedInServers.isEmpty })
        // The user's runs across repositories, asked again when what is watched changes.
        desktop.watchedRuns.repositories = { [desktop] in desktop.watchedRepositories }
        desktop.watchedRuns.startPolling(hub: coreHub, isSignedIn: { [github, coreHub] in github.user != nil || !coreHub.signedInServers.isEmpty })
        // A failed start shows up as the hub's status, with a restart offer in each window.
        Task { [core] in _ = try? await core.start() }
    }

    /// What macOS no longer holds of the notifications it showed was closed
    /// there, which reads it here too.
    func applicationDidBecomeActive(_ notification: Notification) {
        Task { [runNotifier] in await runNotifier?.reconcile() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        core.terminateImmediately()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { desktop.showManager() }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch desktop.unsavedEditsQuitDecision() {
        case .cancel:
            return .terminateCancel
        case .proceed:
            return finishTermination() ? .terminateNow : .terminateCancel
        case .saveFirst:
            // Saving goes through the Core; quit waits for it.
            Task { @MainActor in
                let saved = await desktop.saveAllUnsavedWorkflows()
                sender.reply(toApplicationShouldTerminate: saved && finishTermination())
            }
            return .terminateLater
        }
    }

    private func finishTermination() -> Bool {
        desktop.confirmQuitStopsLocalRuns() && desktop.prepareToQuit()
    }
}
