import Foundation
import Observation

// MARK: Which repositories

/// The repositories the Runs tab watches (B39).
enum WatchedRepositories {
    /// The repositories of registered workspaces linked to GitHub, in the
    /// registry's order of their first workspace, each with all its
    /// workspaces, open ones first (a click opens the first); then the
    /// starred repositories in the order they were starred. A repository is
    /// listed once, whatever the case of its name.
    static func of(workspaces: [WorkspaceRecord], isOpen: (UUID) -> Bool, starred: [String]) -> [CoreWatchedRepository] {
        var out: [CoreWatchedRepository] = []
        var position: [String: Int] = [:]
        for workspace in workspaces {
            guard let key = workspace.githubRepository, let ref = GitHubRepositoryRef(key: key) else { continue }
            if let at = position[ref.key.lowercased()] {
                out[at].workspaceIDs.append(workspace.id)
            } else {
                position[ref.key.lowercased()] = out.count
                out.append(CoreWatchedRepository(repository: ref, workspaceIDs: [workspace.id]))
            }
        }
        for index in out.indices {
            let ids = out[index].workspaceIDs
            out[index].workspaceIDs = ids.filter(isOpen) + ids.filter { !isOpen($0) }
        }
        for key in starred {
            guard let ref = GitHubRepositoryRef(key: key), position[ref.key.lowercased()] == nil else { continue }
            position[ref.key.lowercased()] = out.count
            out.append(CoreWatchedRepository(repository: ref))
        }
        return out
    }
}

// MARK: Model

/// A failed or running run of a watched repository.
struct WatchedRun: Equatable, Identifiable, Sendable {
    let run: CoreWorkflowRun
    let repository: CoreWatchedRepository
    /// Its server, run and attempt: a re-run that fails again is a new row.
    var id: String { "\(repository.repository.serverID):\(run.id):\(run.runAttempt)" }
}

/// The tab the menu bar window and the Pull Requests window show, kept in
/// UserDefaults and shared by both.
enum MenuListTab: String, CaseIterable, Sendable {
    case pullRequests, runs

    static let defaultsKey = "menuListTab"

    /// The window's title.
    var title: String { self == .pullRequests ? "Pull Requests" : "Runs" }
    /// The control's label.
    var segment: String { self == .pullRequests ? "Pull requests" : "Runs" }
}

/// The signed-in user's failed and running runs in the watched
/// repositories, for the Runs tab and the menu bar icon (B39). Asked of the
/// Core every three minutes while signed in, when the menu or window opens
/// and when the watched repositories change.
@MainActor
@Observable
final class WatchedRunsModel {
    private(set) var answers: [CoreWatchedRuns] = []
    /// Servers the Core reads nothing from until a time, by server id.
    private(set) var pauses: [String: Date] = [:]
    private(set) var loadedAt: Date?
    private(set) var isLoading = false
    /// The last ask got no answer: the Core is not ready or failed.
    private(set) var unanswered = false
    private(set) var dismissed: [String: Date] = [:]
    @ObservationIgnored private let store: FileDismissalStore?
    @ObservationIgnored private var poll: Task<Void, Never>?
    /// What the last answer was for; nil before any.
    @ObservationIgnored private var sent: [CoreWatchedRepository]?
    @ObservationIgnored var now: () -> Date = Date.init
    /// What to watch, read at every ask; the app delegate sets it.
    @ObservationIgnored var repositories: @MainActor () -> [CoreWatchedRepository] = { [] }

    static let pollInterval: Duration = .seconds(180)
    static let staleAfter: TimeInterval = 60

    init(store: FileDismissalStore?) {
        self.store = store
        let loaded = (try? store?.load()) ?? [:]
        let cutoff = Date().addingTimeInterval(-FileDismissalStore.keepFor)
        dismissed = loaded.filter { $0.value > cutoff }
    }

    /// The repositories read: the first 100.
    var watched: [CoreWatchedRuns] { answers.filter(\.watched) }
    /// Watched repositories whose Actions Runnir can't read.
    var skipped: [CoreWatchedRuns] { watched.filter { $0.access == .notVisible || $0.access == .permissionMissing } }
    /// Beyond the first 100: not read.
    var unwatched: [CoreWatchedRuns] { answers.filter { !$0.watched } }
    /// GitHub did not answer for some repositories; their runs are as read before.
    var offline: Bool { watched.contains { $0.access == .unavailable } }
    /// The oldest read of the runs listed; nil when none was read.
    var oldestRead: Date? { watched.compactMap(\.readAt).min() }
    /// When the latest pause of a server ends; nil when none is paused.
    var pausedUntil: Date? { pauses.values.filter { $0 > now() }.max() }

    /// Failed runs not removed from the list, newest first.
    var failed: [WatchedRun] {
        rows(\.failed).filter { dismissed[$0.id] == nil }
            .sorted { ($0.run.updatedAt ?? .distantPast) > ($1.run.updatedAt ?? .distantPast) }
    }

    /// Running runs, newest first.
    var running: [WatchedRun] {
        rows(\.running).sorted { ($0.run.createdAt ?? .distantPast) > ($1.run.createdAt ?? .distantPast) }
    }

    /// The menu bar dot for the runs alone.
    var badge: MenuBarIcon.Badge { !failed.isEmpty ? .failed : running.isEmpty ? .none : .running }

    private func rows(_ list: KeyPath<CoreWatchedRuns, [CoreWorkflowRun]>) -> [WatchedRun] {
        watched.flatMap { answer in answer[keyPath: list].map { WatchedRun(run: $0, repository: answer.repository) } }
    }

    /// Asks the Core; `force` reads every repository on GitHub again.
    func refresh(hub: CoreHub, force: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let asked = repositories()
        guard !asked.isEmpty else {
            answers = []
            pauses = [:]
            unanswered = false
            sent = asked
            loadedAt = now()
            return
        }
        guard let result = await hub.watchedRuns(asked, refresh: force) else {
            unanswered = true
            return // keep what was read
        }
        answers = result.repositories
        pauses = result.pauses
        unanswered = false
        sent = asked
        loadedAt = now()
    }

    /// Asks again when the list is older than a minute or watches other repositories.
    func refreshIfStale(hub: CoreHub) async {
        if let loadedAt, now().timeIntervalSince(loadedAt) < Self.staleAfter, !unanswered, sent == repositories() { return }
        await refresh(hub: hub)
    }

    /// Removes a failed run's attempt from the list, on this Mac.
    func dismiss(_ run: WatchedRun) {
        var candidate = dismissed
        candidate[run.id] = now()
        let cutoff = now().addingTimeInterval(-FileDismissalStore.keepFor)
        candidate = candidate.filter { $0.value > cutoff }
        try? store?.save(candidate)
        dismissed = candidate
    }

    /// Brings back the runs removed from the list.
    func restoreDismissed() {
        try? store?.save([:])
        dismissed = [:]
    }

    /// Asks every three minutes while `isSignedIn` holds, looking every
    /// `retry`: a sign-in or a change of the watched repositories is read
    /// within seconds, and a sign-out clears the list.
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
                    // Until a first answer, an unready Core is asked again soon.
                    let every = self.loadedAt == nil && self.unanswered ? retry : Self.pollInterval
                    let changed = self.sent.map { $0 != self.repositories() } ?? false
                    if changed || lastRead.map({ clock.now - $0 >= every }) ?? true {
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
        guard loadedAt != nil || !answers.isEmpty || sent != nil else { return }
        answers = []
        pauses = [:]
        loadedAt = nil
        unanswered = false
        sent = nil
    }
}

// MARK: Text

/// The words of the Runs tab, kept apart from the views to be tested.
enum WatchedRunText {
    /// "Workflow · title"; the title alone when it is the workflow's name.
    static func title(_ run: CoreWorkflowRun) -> String {
        run.displayTitle.isEmpty || run.displayTitle == run.name ? run.name : "\(run.name) · \(run.displayTitle)"
    }

    /// "host · owner/name · branch · failed 4 minutes ago", the host only when given.
    static func subtitle(_ row: WatchedRun, host: String?, now: Date) -> String {
        var parts = [row.repository.repository.fullName, row.run.branch, when(row.run, now: now)].filter { !$0.isEmpty }
        if let host { parts.insert(host, at: 0) }
        return parts.joined(separator: " · ")
    }

    /// What the run did and how long ago.
    static func when(_ run: CoreWorkflowRun, now: Date) -> String {
        let at: Date?
        let word: String
        switch (run.status, run.conclusion) {
        case ("completed", "timed_out"): (word, at) = ("timed out", run.updatedAt)
        case ("completed", _): (word, at) = ("failed", run.updatedAt)
        case ("in_progress", _): (word, at) = ("started", run.createdAt)
        case ("waiting", _): (word, at) = ("waiting", run.createdAt)
        default: (word, at) = ("queued", run.createdAt)
        }
        guard let at else { return word }
        return word + " " + ActivityFreshnessText.relative(at, now)
    }

    /// What a click does: its workspace's window, or GitHub.
    static func action(_ row: WatchedRun, workspaceName: (UUID) -> String?) -> String {
        if let id = row.repository.workspaceIDs.first, let name = workspaceName(id) { return "Open in \(name)" }
        return "Open on GitHub"
    }

    /// After "Updated …": the number of repositories watched.
    static func updated(count: Int) -> String {
        " · \(count) " + (count == 1 ? "repository" : "repositories")
    }

    static func skipped(_ count: Int) -> String {
        count == 1
            ? "1 repository skipped: Runnir can't read its Actions."
            : "\(count) repositories skipped: Runnir can't read their Actions."
    }

    static func budget(watched: Int, total: Int) -> String {
        "Watching \(watched) of \(total) repositories: workspaces first, then starred ones in the order you starred them."
    }

    /// Under "No failed or running runs".
    static func scope(workspaces: Int, starred: Int) -> String {
        var parts: [String] = []
        if workspaces > 0 { parts.append("\(workspaces) " + (workspaces == 1 ? "workspace" : "workspaces")) }
        if starred > 0 { parts.append("\(starred) starred " + (starred == 1 ? "repository" : "repositories")) }
        return "Your runs in " + parts.joined(separator: " and ") + "."
    }

    static func paused(until: Date, readAt: Date?) -> String {
        let read = readAt.map { " These runs were read at \(time($0))." } ?? ""
        return "Paused until \(time(until)) to keep the GitHub rate limit." + read
    }

    static func offline(readAt: Date?) -> String {
        "GitHub can't be reached." + (readAt.map { " These runs were read at \(time($0))." } ?? "")
    }

    private static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
}
