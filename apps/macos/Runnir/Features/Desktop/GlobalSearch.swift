import Foundation

/// A setting the global search can open: its section and the words a person
/// may look for it by. The list is kept by hand next to the Settings
/// screens; a test fails when a section has no entry.
struct SettingsItem: Equatable, Identifiable, Sendable {
    let id: String
    let section: SettingsSection
    let title: String
    let detail: String
    /// More words that find it: other names, what it is for.
    let keywords: [String]
}

enum SettingsIndex {
    static let items: [SettingsItem] = [
        SettingsItem(id: "account", section: .account, title: "GitHub account",
                     detail: "Sign in with GitHub, see which repositories Runnir reaches, sign out",
                     keywords: ["sign in", "login", "log in", "token", "authorization", "github.com", "sign out", "logout"]),
        SettingsItem(id: "enterprise", section: .account, title: "GitHub Enterprise servers",
                     detail: "Add a server and sign in to it with a personal access token kept in your Keychain",
                     keywords: ["ghe", "enterprise server", "personal access token", "pat", "keychain", "self-hosted"]),
        SettingsItem(id: "touch-id", section: .runs, title: "Confirm manual runs with Touch ID",
                     detail: "Ask for Touch ID or your Mac's password before Runnir sends a run to GitHub",
                     keywords: ["manual runs", "run workflow", "dispatch", "password", "biometrics", "confirm", "owner"]),
        SettingsItem(id: "notify-checks", section: .notifications, title: "Pull request checks",
                     detail: "Notify when the checks of a pull request you opened finish",
                     keywords: ["notifications", "alerts", "ci", "pr", "banner"]),
        SettingsItem(id: "notify-local", section: .notifications, title: "Local runs",
                     detail: "Notify when a run with act on this Mac finishes or fails",
                     keywords: ["notifications", "alerts", "act", "banner"]),
        SettingsItem(id: "notify-failures", section: .notifications, title: "Notify about failures only",
                     detail: "Failures and successes, or failures only",
                     keywords: ["notifications", "alerts", "success", "quiet"]),
        SettingsItem(id: "notify-system", section: .notifications, title: "macOS notification permission",
                     detail: "Open System Settings when macOS has notifications from Runnir turned off",
                     keywords: ["notifications", "allow", "denied", "focus", "system settings"]),
        SettingsItem(id: "pr-shortcut", section: .pullRequests, title: "Pull Requests shortcut",
                     detail: "Open the Pull Requests window from any app with a keyboard shortcut",
                     keywords: ["hotkey", "global shortcut", "keyboard", "menu bar", "pull requests window"]),
        SettingsItem(id: "installed-act", section: .tools, title: "Use installed act",
                     detail: "Run local workflows with the act installed on this Mac instead of the bundled one",
                     keywords: ["local runs", "experimental", "version", "homebrew"]),
        SettingsItem(id: "tools", section: .tools, title: "Tools and container engine",
                     detail: "act, the Docker CLI and the container engine: what is found and how to set them up",
                     keywords: ["docker", "colima", "orbstack", "podman", "engine", "act", "recheck", "install", "local runs"]),
        SettingsItem(id: "job-logs", section: .storage, title: "Keep job logs on this Mac",
                     detail: "Logs of finished jobs open offline and are not downloaded again",
                     keywords: ["logs", "offline", "disk", "100 MB", "output"]),
        SettingsItem(id: "clear-cache", section: .storage, title: "Clear cache of a workspace",
                     detail: "Delete saved activity that downloads again; local run history and presets stay",
                     keywords: ["storage", "disk", "delete", "workspace data", "saved runs", "reset"]),
        SettingsItem(id: "search-index", section: .storage, title: "Clear Search Index",
                     detail: "The runs Runnir keeps for search, also those GitHub deleted",
                     keywords: ["search", "index", "history", "storage", "delete"]),
        SettingsItem(id: "telemetry", section: .privacy, title: "Telemetry",
                     detail: "Runnir does not enable telemetry by default and sends no repository data to a Runnir backend",
                     keywords: ["privacy", "analytics", "tracking", "data", "backend", "diagnostics"]),
    ]

    /// The settings that match every word, best matches first: a word in the
    /// title ranks above one in a keyword, which ranks above the detail.
    static func search(_ query: String, limit: Int = 8) -> [SettingsItem] {
        let words = SearchText.words(query)
        guard !words.isEmpty else { return [] }
        var scored: [(item: SettingsItem, score: Int, index: Int)] = []
        for (index, item) in items.enumerated() {
            var total = 0
            var found = true
            for word in words {
                if let score = score(word, in: item) { total += score } else { found = false; break }
            }
            if found { scored.append((item, total, index)) }
        }
        return scored.sorted { ($0.score, $1.index) > ($1.score, $0.index) }.prefix(limit).map(\.item)
    }

    private static func score(_ word: String, in item: SettingsItem) -> Int? {
        let title = item.title.lowercased()
        if title.hasPrefix(word) || title.contains(" " + word) { return 4 }
        if title.contains(word) { return 3 }
        if item.keywords.contains(where: { $0.lowercased().contains(word) }) { return 2 }
        if item.detail.lowercased().contains(word) || item.section.title.lowercased().contains(word) { return 1 }
        return nil
    }
}

enum SearchText {
    /// The lowercased words of a typed query that are not qualifiers such as
    /// `branch:main`: what is marked in a result's title.
    static func words(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).compactMap { token in
            let text = token.lowercased()
            if let colon = text.firstIndex(of: ":"), text.index(after: colon) < text.endIndex,
               qualifiers.contains(String(text[..<colon])) { return nil }
            return text
        }
    }

    private static let qualifiers: Set<String> = ["branch", "author", "actor", "event", "workflow", "status", "after", "before"]

    /// The text with each word marked, to show why a result matched.
    static func marked(_ text: String, words: [String]) -> AttributedString {
        var result = AttributedString(text)
        let lowered = text.lowercased()
        guard lowered.count == text.count else { return result }
        for word in words where !word.isEmpty {
            var from = lowered.startIndex
            while let range = lowered.range(of: word, range: from..<lowered.endIndex) {
                let start = result.characters.index(result.startIndex, offsetBy: lowered.distance(from: lowered.startIndex, to: range.lowerBound))
                let end = result.characters.index(start, offsetBy: word.count)
                result[start..<end].inlinePresentationIntent = .stronglyEmphasized
                from = range.upperBound
            }
        }
        return result
    }
}

/// Where a search result leads.
enum SearchDestination: Equatable, Sendable {
    /// The Runs list with the run chosen. `number` finds it by search when the
    /// saved runs do not hold it.
    case run(id: Int64, number: Int64)
    /// The Runs list with a query typed in it, for the rest of a kind.
    case runsList(query: String)
    /// The Overview with the workflow file chosen.
    case workflow(path: String)
    /// The local run of the Workspace section.
    case localRuns
    /// A pull request, on GitHub.
    case pullRequest(URL?)
    /// Settings, at a section.
    case setting(SettingsSection)
}

struct SearchResult: Identifiable, Equatable, Sendable {
    enum Kind: Int, CaseIterable, Sendable {
        case run, pullRequest, workflow, localRun, setting

        var title: String {
            switch self {
            case .run: "Runs"
            case .pullRequest: "Pull requests"
            case .workflow: "Workflows"
            case .localRun: "Local runs"
            case .setting: "Settings"
            }
        }

        var symbol: String {
            switch self {
            case .run: "play.circle"
            case .pullRequest: "arrow.triangle.pull"
            case .workflow: "point.3.connected.trianglepath.dotted"
            case .localRun: "terminal"
            case .setting: "gearshape"
            }
        }
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    /// The workspace it belongs to; nil for settings.
    let workspaceID: UUID?
    let workspaceName: String?
    /// "saved 3 days ago" for a workspace that is not open.
    let age: String?
    let outcome: CoreRunOutcome?
    let destination: SearchDestination
    /// A row that opens the rest of the matches rather than one of them.
    var isMore = false
}

/// The global search: the saved data of the workspaces from the Core, and
/// the settings from a list built in the app. Nothing goes to GitHub.
@MainActor
@Observable
final class GlobalSearchModel {
    enum Scope: Hashable, Sendable { case all, thisWorkspace }

    enum Tab: Hashable, CaseIterable, Sendable {
        case all, runs, pullRequests, workflows, settings

        var title: String {
            switch self {
            case .all: "All"
            case .runs: "Runs"
            case .pullRequests: "Pull requests"
            case .workflows: "Workflows"
            case .settings: "Settings"
            }
        }

        func includes(_ kind: SearchResult.Kind) -> Bool {
            switch self {
            case .all: true
            case .runs: kind == .run
            case .pullRequests: kind == .pullRequest
            case .workflows: kind == .workflow || kind == .localRun
            case .settings: kind == .setting
            }
        }
    }

    enum Status: Equatable, Sendable {
        case idle
        case searching
        case done
        /// The Core did not answer: the settings are still searched.
        case unavailable
    }

    let currentWorkspaceID: UUID
    @ObservationIgnored private let hub: CoreHub?
    @ObservationIgnored private let workspaces: @MainActor () -> [WorkspaceRecord]
    @ObservationIgnored private let now: () -> Date
    /// How long typing pauses before the Core is asked.
    @ObservationIgnored var debounce: Duration = .milliseconds(150)
    @ObservationIgnored private var task: Task<Void, Never>?

    private(set) var query = ""
    var scope: Scope = .all {
        didSet { if scope != oldValue { search(again: true) } }
    }
    var tab: Tab = .all {
        didSet { selection = visible.first?.id }
    }
    private(set) var status: Status = .idle
    private(set) var results: [SearchResult] = []
    /// Workspaces that could not be searched, with the reason.
    private(set) var unreadable: [(name: String, reason: String)] = []
    private(set) var problems: [String] = []
    var selection: SearchResult.ID?

    init(hub: CoreHub?, currentWorkspaceID: UUID, workspaces: @escaping @MainActor () -> [WorkspaceRecord], now: @escaping () -> Date = Date.init) {
        self.hub = hub
        self.currentWorkspaceID = currentWorkspaceID
        self.workspaces = workspaces
        self.now = now
    }

    var words: [String] { SearchText.words(query) }
    var visible: [SearchResult] { results.filter { tab.includes($0.kind) } }

    func count(_ tab: Tab) -> Int {
        results.filter { tab.includes($0.kind) && !$0.isMore }.count
    }

    var selected: SearchResult? { visible.first { $0.id == selection } }

    /// The typed text changed.
    func update(query text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != query else { return }
        query = trimmed
        search(again: false)
    }

    /// Back to nothing typed, as when the layer closes.
    func reset() {
        task?.cancel()
        query = ""
        results = []
        unreadable = []
        problems = []
        status = .idle
        selection = nil
        tab = .all
    }

    func moveSelection(by step: Int) {
        let rows = visible
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == selection } ?? (step > 0 ? -1 : rows.count)
        selection = rows[min(max(current + step, 0), rows.count - 1)].id
    }

    private func search(again: Bool) {
        task?.cancel()
        guard !query.isEmpty else {
            reset()
            return
        }
        let text = query
        let settings = SettingsIndex.search(text).map(Self.result)
        // The settings answer at once; the rest follows the Core.
        results = results.filter { $0.kind != .setting && again } + settings
        status = .searching
        selection = visible.first?.id
        task = Task { [weak self] in
            guard let self else { return }
            if !again { try? await Task.sleep(for: debounce) }
            guard !Task.isCancelled else { return }
            let records = workspaces()
            let ids = scope == .thisWorkspace ? records.filter { $0.id == currentWorkspaceID }.map(\.id) : records.map(\.id)
            var answer: CoreWorkspaceSearch? = CoreWorkspaceSearch()
            if !ids.isEmpty { answer = await hub?.searchWorkspaces(query: text, workspaceIDs: ids) }
            guard !Task.isCancelled, text == query else { return }
            apply(answer, records: records, settings: settings)
        }
    }

    private func apply(_ answer: CoreWorkspaceSearch?, records: [WorkspaceRecord], settings: [SearchResult]) {
        guard let answer else {
            results = settings
            status = .unavailable
            selection = visible.first?.id
            return
        }
        problems = answer.problems
        var rows: [SearchResult] = []
        unreadable = []
        let names = Dictionary(records.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        // The window's own workspace first, then the others as they are listed.
        let order = records.map(\.id).sorted { lhs, _ in lhs == currentWorkspaceID }
        let byWorkspace = Dictionary(answer.workspaces.map { ($0.workspaceID, $0) }, uniquingKeysWith: { first, _ in first })
        for id in order {
            guard let hits = byWorkspace[id], let name = names[id] else { continue }
            if let problem = hits.problem {
                unreadable.append((name, problem))
                continue
            }
            rows += Self.results(from: hits, workspaceName: name, query: query, now: now())
        }
        // Kinds stay together; within a kind the workspace order holds.
        rows = SearchResult.Kind.allCases.flatMap { kind in rows.filter { $0.kind == kind } }
        results = rows + settings
        status = .done
        selection = visible.first?.id
    }

    static func results(from hits: CoreWorkspaceHits, workspaceName: String, query: String, now: Date) -> [SearchResult] {
        let age = hits.isOpen ? nil : hits.savedAt.map { "saved " + $0.formatted(.relative(presentation: .named, unitsStyle: .wide)) }
        let id = hits.workspaceID
        var rows: [SearchResult] = []
        for run in hits.runs {
            rows.append(SearchResult(id: "run-\(id)-\(run.id)", kind: .run, title: run.title, detail: RunPresentation.detail(run),
                                     workspaceID: id, workspaceName: workspaceName, age: age, outcome: run.outcome,
                                     destination: .run(id: run.id, number: run.runNumber)))
        }
        if hits.runsMatched > hits.runs.count {
            rows.append(SearchResult(id: "runs-more-\(id)", kind: .run, title: "Show all \(hits.runsMatched) runs", detail: "in \(workspaceName)",
                                     workspaceID: id, workspaceName: workspaceName, age: nil, outcome: nil,
                                     destination: .runsList(query: query), isMore: true))
        }
        for pull in hits.pullRequests {
            let state = pull.isDraft ? "draft" : pull.state
            rows.append(SearchResult(id: "pr-\(id)-\(pull.number)", kind: .pullRequest, title: pull.title,
                                     detail: ["#\(pull.number)", state, pull.headRef, pull.author].filter { !$0.isEmpty }.joined(separator: " · "),
                                     workspaceID: id, workspaceName: workspaceName, age: age, outcome: nil,
                                     destination: .pullRequest(pull.htmlURL)))
        }
        for workflow in hits.workflows {
            rows.append(SearchResult(id: "workflow-\(id)-\(workflow.id)", kind: .workflow, title: workflow.name, detail: workflow.path,
                                     workspaceID: id, workspaceName: workspaceName, age: age, outcome: nil,
                                     destination: .workflow(path: workflow.path)))
        }
        for run in hits.localRuns {
            let file = run.workflowPath.split(separator: "/").last.map(String.init) ?? run.workflowPath
            let when = run.startedAt.map { $0.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)) }
            rows.append(SearchResult(id: "local-\(id)-\(run.executionID)", kind: .localRun, title: file + (run.jobID.isEmpty ? "" : " · " + run.jobID),
                                     detail: [run.state.capitalized, run.message.isEmpty ? nil : run.message, when].compactMap { $0 }.joined(separator: " · "),
                                     workspaceID: id, workspaceName: workspaceName, age: age, outcome: Self.outcome(ofLocal: run.state),
                                     destination: .localRuns))
        }
        return rows
    }

    private static func outcome(ofLocal state: String) -> CoreRunOutcome {
        switch state {
        case "succeeded": .succeeded
        case "failed", "interrupted": .failed
        case "cancelled": .cancelled
        case "running": .running
        default: .queued
        }
    }

    private static func result(_ item: SettingsItem) -> SearchResult {
        SearchResult(id: "setting-\(item.id)", kind: .setting, title: item.title, detail: item.detail, workspaceID: nil,
                     workspaceName: nil, age: nil, outcome: nil, destination: .setting(item.section))
    }
}
