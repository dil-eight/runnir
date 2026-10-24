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
    /// Installations whose private repositories' pull requests are missing.
    private(set) var pendingInstallations: [CoreGitHubInstallation] = []
    private(set) var loadedAt: Date?
    private(set) var isLoading = false
    private(set) var dismissed: [String: Date] = [:]
    @ObservationIgnored private let store: FileDismissedPullRequestsStore?
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored var now: () -> Date = Date.init
    /// An open pull request's checks finished since the last read.
    @ObservationIgnored var onChecksFinished: (@MainActor (CorePullRequest) -> Void)?

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
            // Checks that were running at the last read and have finished.
            let running = Set(open.filter { $0.ci == .running }.map(\.id))
            for pr in result.open where running.contains(pr.id) && (pr.ci == .passed || pr.ci == .failed) {
                onChecksFinished?(pr)
            }
            open = result.open
            recentlyClosed = result.closed
            headsUnreadable = result.headsUnreadable
            pendingInstallations = result.pendingInstallations
            loadedAt = now()
        case .signedOut, .tokenRejected:
            open = []
            recentlyClosed = []
            headsUnreadable = false
            pendingInstallations = []
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

/// Colors of S19 that the theme has no token for, as sRGB values: S19's
/// own for dark, and for light deeper strokes and pale tints of the same
/// hues, so chips and icons read on either background.
enum PullRequestColors {
    static let runningValues: (light: UInt32, dark: UInt32) = (0x0F766E, 0x5EEAD4)
    static let runningSoftValues: (light: UInt32, dark: UInt32) = (0xE6FAF7, 0x13292A)
    static let failedSoftValues: (light: UInt32, dark: UInt32) = (0xFDECEC, 0x2D1B1E)
    static let passedSoftValues: (light: UInt32, dark: UInt32) = (0xEDFAF2, 0x16261C)
    static let mergedValues: (light: UInt32, dark: UInt32) = (0x6D28D9, 0xA78BFA)

    static let running = adaptive(runningValues)
    static let runningSoft = adaptive(runningSoftValues)
    static let failedSoft = adaptive(failedSoftValues)
    static let passedSoft = adaptive(passedSoftValues)
    static let merged = adaptive(mergedValues)

    private static func adaptive(_ values: (light: UInt32, dark: UInt32)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? values.dark : values.light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
}

/// One pull request: its CI (or how it closed), title, repository and
/// server. Hovering highlights it and shows what a click does; a closed one
/// can be removed from the list.
struct PullRequestRow: View {
    let pullRequest: CorePullRequest
    /// The server's host, shown when more than one account is signed in.
    var serverHost: String? = nil
    var dismiss: (() -> Void)? = nil
    @Environment(\.openURL) private var openURL
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon.frame(width: 16).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(pullRequest.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                        .foregroundStyle(pullRequest.state == "open" ? RunnirTheme.foreground : RunnirTheme.secondaryForeground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if pullRequest.draft {
                        Text("Draft").font(.system(size: 10)).foregroundStyle(RunnirTheme.secondaryForeground)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(RunnirTheme.border))
                    }
                }
                Text(subtitle).font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground).lineLimit(1)
            }
            trailing
        }
        .padding(.vertical, 7).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? RunnirTheme.selected : .clear))
        .clickable()
        .onHover { hovering = $0 }
        .onTapGesture { if let url = pullRequest.htmlURL { openURL(url) } }
        .help("Open \(pullRequest.repository) #\(pullRequest.number) on GitHub")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if let url = pullRequest.htmlURL { openURL(url) } }
        .accessibilityAction(named: "Remove from this list") { dismiss?() }
    }

    @ViewBuilder private var trailing: some View {
        if let dismiss {
            // A 28-point target with its own hover, so a near miss removes
            // instead of opening the pull request under it.
            RemoveButton(action: dismiss)
                .opacity(hovering ? 1 : 0)
                .padding(.top, -6).padding(.trailing, -6)
                .help("Remove from this list")
                .accessibilityLabel("Remove \(pullRequest.title) from this list")
        } else {
            Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(RunnirTheme.secondaryForeground)
                .frame(width: 14).padding(.top, 2)
                .opacity(hovering ? 1 : 0)
                .accessibilityHidden(true)
        }
    }

    private struct RemoveButton: View {
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hovering ? RunnirTheme.foreground : RunnirTheme.secondaryForeground)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(hovering ? RunnirTheme.secondary : .clear).frame(width: 22, height: 22))
            }
            .buttonStyle(.hit)
            .onHover { hovering = $0 }
        }
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
            let closed = pullRequest.closedAt.map { " " + $0.formatted(.relative(presentation: .named)) } ?? ""
            parts.append((pullRequest.state == "merged" ? "Merged" : "Closed") + closed)
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
                    .buttonStyle(.hit).help("Open the run on GitHub")
                    .accessibilityLabel(ciText)
            } else {
                Image(systemName: icon.symbol).foregroundStyle(icon.tint).accessibilityLabel(ciText)
            }
        } else if pullRequest.state == "merged" {
            Image(systemName: "arrow.triangle.merge").foregroundStyle(PullRequestColors.merged).accessibilityLabel("Merged")
        } else {
            Image(systemName: "minus.circle").foregroundStyle(RunnirTheme.mutedForeground).accessibilityLabel("Closed")
        }
    }

    static func ciIcon(_ ci: CorePullRequestCI) -> (symbol: String, tint: Color) {
        switch ci {
        case .passed: ("checkmark.circle.fill", RunnirTheme.success)
        case .failed: ("xmark.circle.fill", RunnirTheme.destructive)
        case .running: ("arrow.triangle.2.circlepath.circle.fill", PullRequestColors.running)
        case .cancelled: ("slash.circle", RunnirTheme.secondaryForeground)
        case .none: ("circle", RunnirTheme.mutedForeground)
        case .unknown: ("questionmark.circle", RunnirTheme.mutedForeground)
        }
    }
}

/// What the list shows: signed out, checking the saved sign-in, or lists.
enum PullRequestsListState: Equatable {
    case restoring, signedOut, lists

    @MainActor
    static func of(_ desktop: DesktopCoordinator) -> PullRequestsListState {
        let enterprise = !(desktop.core?.signedInServers.isEmpty ?? true)
        guard let github = desktop.github, github.user == nil, !enterprise else { return .lists }
        if case .restoring = github.connection { return .restoring }
        return .signedOut
    }
}

/// The list the menu bar and the window share (S19): a summary of the open
/// pull requests' CI, the open ones, then those closed today, each
/// removable.
struct PullRequestsList: View {
    let model: PullRequestsModel
    let desktop: DesktopCoordinator
    /// Inset of the rows' text from the edges.
    var inset: CGFloat = 16
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch PullRequestsListState.of(desktop) {
            case .restoring:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking the saved sign-in...") }
                    .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                    .padding(.horizontal, inset).padding(.vertical, 16)
            case .signedOut:
                PullRequestsSignedOut(desktop: desktop)
            case .lists:
                lists
            }
        }
    }

    @ViewBuilder private var lists: some View {
        if let access = model.access, let help = notice(access) {
            GitHubAccessNotice(help: help, style: .note, github: desktop.github) {
                if let hub = desktop.core { Task { await model.refresh(hub: hub) } }
            }.padding(.horizontal, inset).padding(.bottom, 10)
        }
        if model.headsUnreadable { headsNote.padding(.horizontal, inset).padding(.bottom, 10) }
        summary
        DesignDivider()
        sectionHeader("OPEN", count: model.open.count)
        if model.open.isEmpty {
            nothingOpen
        }
        ForEach(model.open) { PullRequestRow(pullRequest: $0, serverHost: host(of: $0)).padding(.horizontal, inset - 8) }
        if !model.closed.isEmpty {
            sectionHeader("CLOSED TODAY", count: model.closed.count)
            ForEach(model.closed) { pr in
                PullRequestRow(pullRequest: pr, serverHost: host(of: pr)) { model.dismiss(pr) }.padding(.horizontal, inset - 8)
            }
        }
        if model.access == .ok {
            ForEach(model.pendingInstallations) { installation in
                pendingNote(installation).padding(.horizontal, inset).padding(.top, 10)
            }
            scope(Self.scopeNote(credential: desktop.core?.credentialKind)).padding(.horizontal, inset).padding(.top, 10)
        }
        Color.clear.frame(height: 8)
    }

    /// Search finds pull requests only in repositories the sign-in reaches:
    /// with Runnir Desktop, those where it is installed. Said under the list,
    /// so a missing one is not a mystery. `credential` is github.com's; nil
    /// when only Enterprise servers are signed in.
    static func scopeNote(credential: CoreGitHubCredentialKind?) -> (text: String, managesAccess: Bool) {
        credential == .appUser
            ? ("Only repositories where Runnir Desktop is installed are listed.", true)
            : ("Only repositories your token reaches are listed.", false)
    }

    /// Why an account's private pull requests are missing: "dil-eight hasn't
    /// accepted Pull requests (read) for Runnir Desktop, so pull requests in
    /// its private repositories are not listed."
    static func pendingText(_ installation: CoreGitHubInstallation) -> String {
        installation.suspended
            ? "Runnir Desktop is suspended on \(installation.account), so its repositories' pull requests are not listed."
            : "\(installation.account) hasn't accepted Pull requests (read) for Runnir Desktop, so pull requests in its private repositories are not listed."
    }

    private func pendingNote(_ installation: CoreGitHubInstallation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(Self.pendingText(installation), systemImage: "exclamationmark.triangle")
                .foregroundStyle(RunnirTheme.warning).fixedSize(horizontal: false, vertical: true)
            Button(installation.accountType == "User" ? "Review Permissions..." : "Review Permissions (an owner of \(installation.account))...") {
                openURL(installation.htmlURL ?? GitHubAppConfiguration.runnirDesktop.installationURL)
            }
            .buttonStyle(.link).pointerStyle(.link)
            .help("Opens the installation on GitHub, where the new permissions are accepted")
        }
        .font(.system(size: 11))
    }

    private func scope(_ note: (text: String, managesAccess: Bool)) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(note.text).foregroundStyle(RunnirTheme.secondaryForeground).fixedSize(horizontal: false, vertical: true)
            if note.managesAccess {
                Button("Manage Repository Access...") { openURL(GitHubAppConfiguration.runnirDesktop.installationURL) }
                    .buttonStyle(.link).pointerStyle(.link)
                    .help("Install Runnir Desktop on more repositories on GitHub")
            }
        }
        .font(.system(size: 11))
    }

    /// Chips counting failing, running and passing open pull requests.
    @ViewBuilder private var summary: some View {
        let failing = model.open.count { $0.ci == .failed }
        let running = model.open.count { $0.ci == .running }
        let passed = model.open.count { $0.ci == .passed }
        if failing + running + passed > 0 {
            HStack(spacing: 6) {
                if failing > 0 { chip("xmark.circle.fill", "\(failing) failing", RunnirTheme.destructive, PullRequestColors.failedSoft) }
                if running > 0 { chip("arrow.triangle.2.circlepath", "\(running) running", PullRequestColors.running, PullRequestColors.runningSoft) }
                if passed > 0 { chip("checkmark.circle.fill", "\(passed) passed", RunnirTheme.success, PullRequestColors.passedSoft) }
            }
            .padding(.horizontal, inset).padding(.bottom, 12)
            .accessibilityElement(children: .combine)
        }
    }

    private func chip(_ symbol: String, _ label: String, _ tint: Color, _ background: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10))
            Text(label).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(background))
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(RunnirTheme.secondaryForeground)
            Text("\(count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(RunnirTheme.mutedForeground)
        }
        .padding(.horizontal, inset).padding(.top, 10).padding(.bottom, 4)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private var nothingOpen: some View {
        if model.isLoading && model.loadedAt == nil {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading pull requests...") }
                .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                .padding(.horizontal, inset).padding(.vertical, 12)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle").font(.system(size: 20)).foregroundStyle(RunnirTheme.success)
                Text("No open pull requests").font(.system(size: 13, weight: .medium))
                Text("New ones you open on GitHub show up here with their CI.")
                    .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, inset).padding(.top, 14).padding(.bottom, 16)
        }
    }

    /// The pull request's server host, when more than one account is
    /// signed in; nil otherwise.
    private func host(of pullRequest: CorePullRequest) -> String? {
        guard let hub = desktop.core, hub.signedInServers.count > 1 else { return nil }
        return pullRequest.server.isEmpty ? "github.com" : hub.serverRef(for: pullRequest.server)?.webHost
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

/// No account signed in: the logo, what the list is for, and where to sign
/// in. Both ways in live in Settings › Account.
struct PullRequestsSignedOut: View {
    let desktop: DesktopCoordinator

    var body: some View {
        VStack(spacing: 10) {
            BrandLogo(markOnly: true, height: 54, width: 56)
            Text("Your pull requests, with their CI").font(.system(size: 14, weight: .semibold))
            Text("Connect GitHub, or add an Enterprise server in Settings. Runnir lists the pull requests you opened and shows whether their checks pass.")
                .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                .multilineTextAlignment(.center).frame(maxWidth: 300).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Connect GitHub…") { desktop.showSettingsInFrontWindow(section: .account) }
                    .buttonStyle(DesignButtonStyle(primary: true))
                Button("Add Enterprise Server…") { desktop.showSettingsInFrontWindow(section: .account) }
                    .buttonStyle(DesignButtonStyle())
            }.padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28).padding(.top, 14).padding(.bottom, 22)
    }
}

/// The menu bar item's window (S19).
struct PullRequestsMenu: View {
    let model: PullRequestsModel
    let desktop: DesktopCoordinator
    let shortcut: String?
    /// The list's own height: a scroll view in the menu bar window has none
    /// and would show nothing.
    @State private var listHeight: CGFloat = 0

    static let maxListHeight: CGFloat = 460

    private var signedOut: Bool { PullRequestsListState.of(desktop) != .lists }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                PullRequestsList(model: model, desktop: desktop).frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .frame(height: min(max(listHeight, 16), Self.maxListHeight))
            DesignDivider()
            footer
        }
        .frame(width: 384)
        // Solid, as in the design: the menu bar window's own material lets
        // the wallpaper through and the list becomes hard to read.
        .background(RunnirTheme.background)
        .foregroundStyle(RunnirTheme.foreground)
        .task { if let hub = desktop.core { await model.refreshIfStale(hub: hub) } }
    }

    private var header: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pull Requests").font(.system(size: 13, weight: .semibold))
                TimelineView(.periodic(from: .now, by: 15)) { _ in
                    Text(updatedText).font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                }
            }
            Spacer()
            if !signedOut, let hub = desktop.core {
                iconButton("arrow.clockwise", help: "Read pull requests again") { Task { await model.refresh(hub: hub) } }
                    .disabled(model.isLoading)
                iconButton("macwindow", help: "Open the Pull Requests window") { desktop.showPullRequests() }
            }
        }
        .padding(.top, 14).padding(.bottom, 10).padding(.leading, 16).padding(.trailing, 12)
    }

    private var updatedText: String {
        if signedOut { return "Not connected" }
        guard let loaded = model.loadedAt else { return model.isLoading ? "Reading..." : "Not read yet" }
        if Date().timeIntervalSince(loaded) < 30 { return "Updated just now" }
        return "Updated " + loaded.formatted(.relative(presentation: .named))
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(RunnirTheme.secondaryForeground)
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.hit).help(help).accessibilityLabel(help)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if signedOut {
                Button("Open Runnir") { desktop.showManager() }.buttonStyle(.link).pointerStyle(.link)
                Spacer()
                Button("Settings…") { desktop.showSettingsInFrontWindow() }.buttonStyle(.hit)
                    .foregroundStyle(RunnirTheme.secondaryForeground)
            } else {
                Button("Open Pull Requests Window") { desktop.showPullRequests() }.buttonStyle(.link).pointerStyle(.link).fontWeight(.medium)
                if let shortcut {
                    Text(shortcut).font(.system(size: 10)).foregroundStyle(RunnirTheme.secondaryForeground)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(RunnirTheme.border))
                        .accessibilityLabel("Shortcut \(shortcut)")
                }
                Spacer()
                if !model.dismissed.isEmpty {
                    Button("Show Removed (\(model.dismissed.count))") { model.restoreDismissed() }.buttonStyle(.hit)
                        .foregroundStyle(RunnirTheme.secondaryForeground)
                        .help("Bring back the closed pull requests removed from this list")
                }
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16).padding(.vertical, 10)
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
                PullRequestsList(model: model, desktop: desktop, inset: 20).padding(.top, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .background(RunnirTheme.background)
        .foregroundStyle(RunnirTheme.foreground)
        .task { if let hub = desktop.core { await model.refreshIfStale(hub: hub) } }
    }
}
