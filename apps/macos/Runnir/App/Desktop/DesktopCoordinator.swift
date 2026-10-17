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
    @ObservationIgnored private var splash: NSWindow?
    @ObservationIgnored private var windows: [UUID: any WorkspaceWindowManaging] = [:]
    @ObservationIgnored private let makeGrant: (WorkspaceRecord) throws -> any RepositoryGranting
    @ObservationIgnored private let makeWorkspaceWindow: (WorkspaceWindowRecord, WorkspaceRecord, (any RepositoryGranting)?, DesktopCoordinator) -> any WorkspaceWindowManaging
    @ObservationIgnored private var geometryTask: Task<Void, Never>?
    @ObservationIgnored private var bootTask: Task<Void, Never>?
    @ObservationIgnored var terminationInProgress = false
    let accountState = AppState()
    /// The app's connection to the single Core process; nil in tests that do not need it.
    let core: CoreHub?

    init(store: (any DesktopStateStoring)? = nil,
         core: CoreHub? = nil,
         makeGrant: @escaping (WorkspaceRecord) throws -> any RepositoryGranting = { try RepositoryGrant(record: $0) },
         makeWorkspaceWindow: @escaping (WorkspaceWindowRecord, WorkspaceRecord, (any RepositoryGranting)?, DesktopCoordinator) -> any WorkspaceWindowManaging = {
             WorkspaceWindowController(record: $0, workspace: $1, grant: $2, desktop: $3)
         }) {
        self.store = store
        self.core = core
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
            if windows.isEmpty { showManager() }
            splash?.close()
            splash = nil
            Task {
                do { accountState.coreVersion = try await CoreClient.bundled.version() }
                catch { accountState.coreConnectionFailed = true }
            }
        }
    }

    func showManager() {
        if manager == nil {
            let window = makeWindow(size: NSSize(width: 900, height: 600), title: "Workspaces")
            window.minSize = NSSize(width: 700, height: 480)
            window.contentViewController = NSHostingController(rootView: WorkspaceManagerView(desktop: self))
            window.setContentSize(NSSize(width: 900, height: 600))
            window.identifier = NSUserInterfaceItemIdentifier("workspace-manager")
            manager = window
        }
        manager?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

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
        panel.message = "Choose a local Git working tree. Repository files will only be read."
        guard panel.runModal() == .OK, let selected = panel.url else { return }
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

    func openRegistered(_ workspace: WorkspaceRecord, reuseWindowID: UUID? = nil) {
        do { try open(workspace, reuseWindowID: reuseWindowID) }
        catch { message = "Workspace unavailable. Locate the folder to restore access; existing windows are unchanged." }
    }

    private func open(_ workspace: WorkspaceRecord, reuseWindowID: UUID? = nil) throws {
        guard !isLoading else { throw DesktopStoreError.invalidState }
        let grant = try makeGrant(workspace)
        var candidate = snapshot
        if let index = candidate.workspaces.firstIndex(where: { $0.id == workspace.id }) {
            candidate.workspaces[index].lastOpenedAt = Date()
        }
        if let reuseWindowID, let current = windows[reuseWindowID] {
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
            let controller = makeWorkspaceWindow(record, workspace, grant, self)
            windows[record.id] = controller
            core?.attach(windowID: record.id, workspaceID: workspace.id, path: workspace.path)
            controller.showWindow(nil)
        }
        manager?.orderOut(nil)
        message = nil
    }

    private func restore(_ record: WorkspaceWindowRecord) {
        guard let workspace = snapshot.workspaces.first(where: { $0.id == record.workspaceID }) else { return }
        let grant = try? makeGrant(workspace)
        let controller = makeWorkspaceWindow(record, workspace, grant, self)
        windows[record.id] = controller
        // Without a grant the folder is missing; the window offers to locate it.
        if grant != nil { core?.attach(windowID: record.id, workspaceID: workspace.id, path: workspace.path) }
        controller.showWindow(nil)
    }

    func removeRegistration(_ workspace: WorkspaceRecord) {
        guard openCount(workspace.id) == 0 else { return }
        var candidate = snapshot
        candidate.workspaces.removeAll { $0.id == workspace.id }
        do { try commit(candidate) }
        catch { message = "Registration could not be removed. Repository files were not changed." }
    }

    func selectSection(_ section: AppSection, windowID: UUID) {
        guard let index = snapshot.windows.firstIndex(where: { $0.id == windowID }) else { return }
        var candidate = snapshot
        candidate.windows[index].section = section
        do { try commit(candidate); windows[windowID]?.record.section = section }
        catch { message = "Window navigation could not be saved." }
    }

    func shouldClose(_ id: UUID) -> Bool {
        if terminationInProgress { return true }
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
        windows.removeValue(forKey: id)?.grant?.stop()
        core?.detach(windowID: id)
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
        self.grant?.stop()
        self.grant = grant
        self.record = record
        installContent(workspace)
    }

    private func installContent(_ workspace: WorkspaceRecord) {
        let frame = window?.frame
        let state = AppState()
        state.selectedSection = record.section
        window?.title = workspace.name + " - Runnir"
        window?.contentViewController = NSHostingController(rootView:
            DesktopWorkspaceView(desktop: desktop, workspace: workspace, windowID: record.id, reader: grant?.reader)
                .environment(state).environment(\.appEnvironment, AppEnvironment.live))
        if let frame { window?.setFrame(frame, display: false) }
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

    override init() {
        let supervisor = CoreProcessSupervisor.bundled()
        let hub = CoreHub(provider: supervisor)
        core = supervisor
        coreHub = hub
        desktop = DesktopCoordinator(core: hub)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              NSClassFromString("XCTestCase") == nil else { return }
        desktop.start()
        coreHub.startMonitoring()
        // A failed start shows up as the hub's status, with a restart offer in each window.
        Task { [core] in _ = try? await core.start() }
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
        desktop.prepareToQuit() ? .terminateNow : .terminateCancel
    }
}
