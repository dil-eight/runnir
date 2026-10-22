import AppKit
import SwiftUI

// MARK: Dismissed pull requests

/// dismissed-pull-requests.json in the app's support directory: closed pull
/// requests removed from the menu, by link, with when. Entries older than a
/// week are dropped, since the menu shows only the last day.
struct FileDismissedPullRequestsStore: Sendable {
    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("dismissed-pull-requests.json") }

    static let maxEntries = 1000
    static let maxFileBytes = 256 * 1024
    static let keepFor: TimeInterval = 7 * 24 * 3600

    private struct Snapshot: Codable {
        var version = 1
        var dismissed: [String: Date]
    }

    static func live() throws -> FileDismissedPullRequestsStore {
        FileDismissedPullRequestsStore(directory: try RunnirSupportDirectory.url())
    }

    func load() throws -> [String: Date] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= Self.maxFileBytes else { throw DesktopStoreError.tooLarge }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: fileURL))
        guard snapshot.version == 1, snapshot.dismissed.count <= Self.maxEntries else { throw DesktopStoreError.invalidState }
        return snapshot.dismissed
    }

    func save(_ dismissed: [String: Date]) throws {
        guard dismissed.count <= Self.maxEntries else { throw DesktopStoreError.invalidState }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try AtomicFile.write(try encoder.encode(Snapshot(dismissed: dismissed)), to: fileURL)
    }
}

// MARK: Model

/// The signed-in user's open pull requests with their CI, and those closed
/// in the last day, for the menu bar and the Pull Requests window. Read
/// every three minutes while signed in, and when the menu or window opens.
@MainActor
@Observable
final class PullRequestsModel {
    private(set) var access: CoreGitHubAccess?
    private(set) var open: [CorePullRequest] = []
    private(set) var recentlyClosed: [CorePullRequest] = []
    private(set) var headsUnreadable = false
    private(set) var loadedAt: Date?
    private(set) var isLoading = false
    private(set) var dismissed: [String: Date] = [:]
    @ObservationIgnored private let store: FileDismissedPullRequestsStore?
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored var now: () -> Date = Date.init

    static let closedWindow: TimeInterval = 24 * 3600
    static let pollInterval: Duration = .seconds(180)
    static let staleAfter: TimeInterval = 60

    init(store: FileDismissedPullRequestsStore?) {
        self.store = store
        let loaded = (try? store?.load()) ?? [:]
        let cutoff = Date().addingTimeInterval(-FileDismissedPullRequestsStore.keepFor)
        dismissed = loaded.filter { $0.value > cutoff }
    }

    /// Closed in the last day and not removed from the list.
    var closed: [CorePullRequest] {
        recentlyClosed.filter { dismissed[$0.id] == nil }
    }

    /// The worst CI among open pull requests, for the menu bar icon.
    var worstCI: CorePullRequestCI? {
        let states = Set(open.map(\.ci))
        return [.failed, .running, .passed].first { states.contains($0) }
    }

    func refresh(hub: CoreHub) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let result = await hub.pullRequests(closedSince: now().addingTimeInterval(-Self.closedWindow))
        access = result.access
        switch result.access {
        case .ok:
            open = result.open
            recentlyClosed = result.closed
            headsUnreadable = result.headsUnreadable
            loadedAt = now()
        case .signedOut, .tokenRejected:
            open = []
            recentlyClosed = []
            headsUnreadable = false
            loadedAt = nil
        default:
            break // keep what was read; `access` says why it may be old
        }
    }

    /// Reads again when the list is older than a minute.
    func refreshIfStale(hub: CoreHub) async {
        if let loadedAt, now().timeIntervalSince(loadedAt) < Self.staleAfter, access == .ok { return }
        await refresh(hub: hub)
    }

    /// Removes a closed pull request from the list, on this Mac.
    func dismiss(_ pullRequest: CorePullRequest) {
        var candidate = dismissed
        candidate[pullRequest.id] = now()
        let cutoff = now().addingTimeInterval(-FileDismissedPullRequestsStore.keepFor)
        candidate = candidate.filter { $0.value > cutoff }
        try? store?.save(candidate)
        dismissed = candidate
    }

    /// Brings back the closed pull requests removed from the list.
    func restoreDismissed() {
        try? store?.save([:])
        dismissed = [:]
    }

    /// Reads every three minutes while `isSignedIn` holds, looking every
    /// `retry`: a sign-in (the saved one comes up after launch, as does the
    /// Core) is read within seconds, so the menu bar icon is right, and a
    /// sign-out clears the list.
    func startPolling(hub: CoreHub, retry: Duration = .seconds(5), isSignedIn: @escaping @MainActor () -> Bool) {
        poll?.cancel()
        poll = Task { [weak self] in
            let clock = ContinuousClock()
            var lastRead: ContinuousClock.Instant?
            while !Task.isCancelled {
                guard let self else { return }
                if !isSignedIn() {
                    self.clear()
                    lastRead = nil
                } else {
                    // Until a first read succeeds, an unready Core is tried again soon.
                    let every = self.loadedAt == nil && self.access == .unavailable ? retry : Self.pollInterval
                    if lastRead.map({ clock.now - $0 >= every }) ?? true {
                        lastRead = clock.now
                        await self.refresh(hub: hub)
                    }
                }
                try? await Task.sleep(for: retry)
            }
        }
    }

    func stopPolling() {
        poll?.cancel()
        poll = nil
    }

    private func clear() {
        guard access != nil || loadedAt != nil else { return }
        access = nil
        open = []
        recentlyClosed = []
        headsUnreadable = false
        loadedAt = nil
    }
}

// MARK: Views

/// One pull request: its CI (or how it closed), title, repository and branch.
struct PullRequestRow: View {
    let pullRequest: CorePullRequest
    /// The server's host, shown when more than one account is signed in.
    var serverHost: String? = nil
    var dismiss: (() -> Void)? = nil
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            statusIcon.frame(width: 16).padding(.top, 1)
            Button {
                if let url = pullRequest.htmlURL { openURL(url) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(pullRequest.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                        if pullRequest.draft {
                            Text("Draft").font(.system(size: 10)).foregroundStyle(RunnirTheme.secondaryForeground)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(RunnirTheme.border))
                        }
                    }
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(pullRequest.repository)#\(pullRequest.number) on GitHub")
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.borderless).foregroundStyle(RunnirTheme.secondaryForeground)
                    .help("Remove from this list")
                    .accessibilityLabel("Remove \(pullRequest.title) from this list")
            }
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String { Self.subtitle(pullRequest, serverHost: serverHost) }
    private var ciText: String { Self.ciText(pullRequest) }

    /// "host · owner/name #n · CI", the host only when given.
    static func subtitle(_ pullRequest: CorePullRequest, serverHost: String?) -> String {
        var parts = ["\(pullRequest.repository) #\(pullRequest.number)"]
        if let serverHost { parts.insert(serverHost, at: 0) }
        if pullRequest.state == "open" {
            parts.append(ciText(pullRequest))
        } else {
            parts.append(pullRequest.state == "merged" ? "Merged" : "Closed")
            if let closed = pullRequest.closedAt { parts.append(closed.formatted(.relative(presentation: .named))) }
        }
        return parts.joined(separator: " · ")
    }

    static func ciText(_ pullRequest: CorePullRequest) -> String {
        switch pullRequest.ci {
        case .none: "No CI"
        case .running: pullRequest.ciRunning == 1 ? "1 run in progress" : "\(pullRequest.ciRunning) runs in progress"
        case .passed: "CI passed"
        case .failed: pullRequest.ciFailed == 1 ? "1 run failed" : "\(pullRequest.ciFailed) runs failed"
        case .cancelled: "CI cancelled"
        case .unknown: "CI not readable"
        }
    }

    @ViewBuilder private var statusIcon: some View {
        if pullRequest.state == "open" {
            let icon = Self.ciIcon(pullRequest.ci)
            if let url = pullRequest.ciURL {
                Button { openURL(url) } label: { Image(systemName: icon.symbol).foregroundStyle(icon.tint) }
                    .buttonStyle(.plain).help("Open the run on GitHub")
                    .accessibilityLabel(ciText)
            } else {
                Image(systemName: icon.symbol).foregroundStyle(icon.tint).accessibilityLabel(ciText)
            }
        } else if pullRequest.state == "merged" {
            Image(systemName: "arrow.triangle.merge").foregroundStyle(Color.purple).accessibilityLabel("Merged")
        } else {
            Image(systemName: "xmark.circle").foregroundStyle(RunnirTheme.secondaryForeground).accessibilityLabel("Closed")
        }
    }

    static func ciIcon(_ ci: CorePullRequestCI) -> (symbol: String, tint: Color) {
        switch ci {
        case .passed: ("checkmark.circle.fill", RunnirTheme.success)
        case .failed: ("xmark.circle.fill", RunnirTheme.destructive)
        case .running: ("clock.fill", RunnirTheme.warning)
        case .cancelled: ("slash.circle", RunnirTheme.secondaryForeground)
        case .none: ("circle", RunnirTheme.mutedForeground)
        case .unknown: ("questionmark.circle", RunnirTheme.mutedForeground)
        }
    }
}

/// The list the menu bar and the window share: open pull requests with
/// their CI, then those closed in the last day, each removable.
struct PullRequestsList: View {
    let model: PullRequestsModel
    let desktop: DesktopCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let github = desktop.github, github.user == nil, desktop.core?.signedInServers.isEmpty ?? true {
                if case .restoring = github.connection {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking the saved sign-in...") }
                        .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Connect GitHub to see your pull requests.").font(.system(size: 12))
                        Button("Open Runnir...") { desktop.showManager() }
                    }
                }
            } else {
                if let access = model.access, let help = notice(access) {
                    GitHubAccessNotice(help: help, style: .note, github: desktop.github) {
                        if let hub = desktop.core { Task { await model.refresh(hub: hub) } }
                    }
                }
                if model.headsUnreadable { headsNote }
                section("OPEN") {
                    if model.open.isEmpty {
                        Text(model.isLoading && model.loadedAt == nil ? "Reading pull requests..." : "No open pull requests.")
                            .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                    }
                    ForEach(model.open) { PullRequestRow(pullRequest: $0, serverHost: host(of: $0)) }
                }
                if !model.closed.isEmpty {
                    section("CLOSED IN THE LAST DAY") {
                        ForEach(model.closed) { pr in PullRequestRow(pullRequest: pr, serverHost: host(of: pr)) { model.dismiss(pr) } }
                    }
                }
            }
        }
    }

    /// The pull request's server host, when more than one account is
    /// signed in; nil otherwise.
    private func host(of pullRequest: CorePullRequest) -> String? {
        guard let hub = desktop.core, hub.signedInServers.count > 1 else { return nil }
        return pullRequest.server.isEmpty ? "github.com" : hub.serverRef(for: pullRequest.server)?.webHost
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(title: title)
            DesignDivider()
            content()
        }
    }

    private func notice(_ access: CoreGitHubAccess) -> GitHubAccessHelp? {
        switch access {
        case .ok, .noRemote: nil
        default: GitHubAccessHelp.forAccess(access, repository: "your pull requests", purpose: .read, credential: desktop.core?.credentialKind)
        }
    }

    /// Pull requests are found, but their heads need Pull requests read.
    private var headsNote: some View {
        let personal = desktop.core?.credentialKind?.isPersonal == true
        return Label(personal
                     ? "CI of some pull requests can't be shown: the token needs Pull requests: Read-only (a fine-grained token) for their repositories."
                     : "CI of some pull requests can't be shown: Runnir Desktop needs Pull requests: Read-only. The app's owner adds it on GitHub, then each installation accepts it.",
                     systemImage: "info.circle")
            .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground).fixedSize(horizontal: false, vertical: true)
    }
}

/// The menu bar item's window.
struct PullRequestsMenu: View {
    let model: PullRequestsModel
    let desktop: DesktopCoordinator
    let shortcut: String?
    /// The list's own height: a scroll view in the menu bar window has none
    /// and would show nothing.
    @State private var listHeight: CGFloat = 0

    static let maxListHeight: CGFloat = 460

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Pull Requests").font(.system(size: 13, weight: .semibold))
                Spacer()
                if let hub = desktop.core {
                    Button { Task { await model.refresh(hub: hub) } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).disabled(model.isLoading).help("Read pull requests again")
                }
            }
            ScrollView {
                PullRequestsList(model: model, desktop: desktop).frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .frame(height: min(max(listHeight, 16), Self.maxListHeight))
            DesignDivider()
            HStack {
                Button("Show Pull Requests Window") { desktop.showPullRequests() }.buttonStyle(.link)
                if let shortcut { Text(shortcut).font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground) }
                Spacer()
                if !model.dismissed.isEmpty {
                    Button("Show Removed") { model.restoreDismissed() }.buttonStyle(.link)
                        .help("Bring back the closed pull requests removed from this list")
                }
            }.font(.system(size: 12))
        }
        .padding(14)
        .frame(width: 400)
        .task { if let hub = desktop.core { await model.refreshIfStale(hub: hub) } }
    }
}

/// The Pull Requests window, opened from the menu bar or the shortcut.
struct PullRequestsWindowView: View {
    let model: PullRequestsModel
    let desktop: DesktopCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Pull Requests").font(.system(size: 15, weight: .semibold))
                if let loaded = model.loadedAt {
                    // Ticks while the window stays open, not only when the list is read.
                    TimelineView(.periodic(from: .now, by: 15)) { _ in
                        Text("updated \(loaded.formatted(.relative(presentation: .named)))")
                    }
                    .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                }
                Spacer()
                if let hub = desktop.core {
                    Button { Task { await model.refresh(hub: hub) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .buttonStyle(DesignButtonStyle()).disabled(model.isLoading)
                }
            }
            .padding(.horizontal, 20).padding(.top, 34).padding(.bottom, 12)
            DesignDivider()
            ScrollView {
                PullRequestsList(model: model, desktop: desktop).padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .background(RunnirTheme.background)
        .foregroundStyle(RunnirTheme.foreground)
        .task { if let hub = desktop.core { await model.refreshIfStale(hub: hub) } }
    }
}
