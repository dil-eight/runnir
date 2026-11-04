import Foundation

/// The Secrets and Variables section of one window (S16): the names the
/// workspace's workflows read, which have saved values, and edits not saved
/// yet. A saved secret's value is read only to show it after Touch ID.
///
/// Values come in sets: the Repository's, which every job gets, and one per
/// GitHub environment a local run can take (ListEnvironments), which a job
/// deploying there gets first, as on GitHub. A job whose environment an
/// expression picks may run in any of them. The rows are those of the set
/// shown.
@MainActor
@Observable
final class WorkspaceValuesModel {
    struct Row: Identifiable, Equatable {
        let key: LocalRunValueKey
        /// File names of the workflows that read it; empty in `unused`.
        let workflows: [String]
        var saved: Bool
        /// In an environment: the Repository has a value, which jobs there
        /// get without one of their own.
        var inherited = false
        /// Some job gets no value unless this set has one: false for a
        /// Repository name every environment reading it sets.
        var needed = true
        /// In the Repository: environments that set their own value.
        var overriddenBy: [String] = []
        var id: LocalRunValueKey { key }
    }

    /// The environment shown; nil is the Repository's values.
    private(set) var environment: String?
    /// Environments a local run can take, and those with saved values.
    private(set) var environments: [String] = []
    /// Environments with saved values that no run can take any more.
    private(set) var staleEnvironments: Set<String> = []
    /// Environments some job names in `environment:`.
    private(set) var namedByJobs: Set<String> = []
    /// Some job picks its environment with an expression.
    private(set) var pickedByExpression = false
    /// Sets in which some job would get an empty value; nil is the Repository.
    private(set) var incomplete: Set<String?> = []
    private(set) var secrets: [Row] = []
    private(set) var variables: [Row] = []
    /// Saved values of the set shown that no workflow reads any more.
    private(set) var unused: [Row] = []
    /// Typed values, not saved yet.
    private(set) var edits: [LocalRunValueKey: String] = [:]
    /// Saved values to forget on Save.
    private(set) var removals: Set<LocalRunValueKey> = []
    /// Saved values on screen: every variable, and a secret after Touch ID.
    private(set) var shown: [LocalRunValueKey: String] = [:]
    /// Names whose saved value Keychain would not give.
    private(set) var refused: Set<LocalRunValueKey> = []
    private(set) var error: String?
    private(set) var importSummary: String?

    var isDirty: Bool { !edits.isEmpty || !removals.isEmpty }

    @ObservationIgnored private var workflows: [CoreWorkflow] = []
    /// What ListEnvironments last answered.
    @ObservationIgnored private var listed: [String] = []
    @ObservationIgnored private var savedKeys: Set<LocalRunValueKey> = []

    func load(workspaceID: UUID, workflows: [CoreWorkflow], store: any LocalRunValueStoring) async {
        let saved: Set<LocalRunValueKey>
        do {
            saved = try await store.keys(workspaceID: workspaceID)
        } catch {
            self.error = "Keychain did not list the saved values. \(error.localizedDescription)"
            return
        }
        self.workflows = workflows
        savedKeys = saved
        let known = rebuild()
        // Edits of names no row shows any more would be saved unseen.
        edits = edits.filter { known.contains($0.key) }
        removals = removals.intersection(known)
        error = nil
        // Every variable, and each secret on screen, is read again: another
        // window may have changed it.
        let revealed = Set(shown.keys.filter { $0.kind == .secret })
        var fresh: [LocalRunValueKey: String] = [:]
        var refusedNow: Set<LocalRunValueKey> = []
        for key in saved.sorted() where key.kind == .variable || revealed.contains(key) {
            do { fresh[key] = try await store.value(workspaceID: workspaceID, key: key) } catch { refusedNow.insert(key) }
        }
        // A secret hidden while reading stays hidden; one shown meanwhile
        // stays shown.
        let onScreen = Set(shown.keys.filter { $0.kind == .secret })
        var next = fresh.filter { $0.key.kind == .variable || onScreen.contains($0.key) }
        for (key, value) in shown where key.kind == .secret && next[key] == nil && saved.contains(key) && !refusedNow.contains(key) {
            next[key] = value
        }
        shown = next
        refused = refusedNow
    }

    /// The environments a local run can take, from the Core, which may ask
    /// GitHub and answer after the workflows load.
    func update(environments: [String]) {
        listed = environments
        rebuild()
    }

    /// Shows another set of values; nil is the Repository's.
    func select(_ environment: String?) {
        self.environment = environment
        rebuild()
    }

    /// The rows of the set shown and what the picker marks, from the
    /// workflows and saved names last loaded. Returns every name some set
    /// reads or has saved.
    @discardableResult private func rebuild() -> Set<LocalRunValueKey> {
        let saved = savedKeys
        let jobs = workflows.flatMap { workflow in
            workflow.jobs.map { (file: (workflow.id as NSString).lastPathComponent, job: $0) }
        }
        namedByJobs = Set(jobs.map(\.job.environment).filter { !$0.isEmpty })
        pickedByExpression = jobs.contains { $0.job.environmentExpression }
        let named = namedByJobs.union(listed)
        let savedIn = Set(saved.compactMap(\.environment))
        environments = named.union(savedIn).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        staleEnvironments = savedIn.subtracting(named)
        if let environment, !environments.contains(environment) { self.environment = nil }
        // A job whose environment an expression picks may run in any of them.
        let placed = jobs.flatMap { item -> [(file: String, job: CoreJob, environment: String)] in
            guard item.job.environmentExpression, !named.isEmpty else { return [(item.file, item.job, item.job.environment)] }
            return named.sorted().map { (item.file, item.job, $0) }
        }

        // Who reads each name of a set: in the Repository every workflow
        // that names it, in an environment the jobs that may deploy there.
        func readers(_ set: String?) -> [LocalRunValueKey: [String]] {
            var out: [LocalRunValueKey: Set<String>] = [:]
            func add(_ names: [String], _ kind: LocalRunValueKind, _ file: String) {
                for name in names { out[LocalRunValueKey(kind: kind, name: name, environment: set), default: []].insert(file) }
            }
            if let set {
                for (file, job, environment) in placed where environment == set {
                    add(job.secrets, .secret, file)
                    add(job.variables, .variable, file)
                }
            } else {
                for workflow in workflows {
                    let file = (workflow.id as NSString).lastPathComponent
                    add(workflow.secrets, .secret, file)
                    add(workflow.variables, .variable, file)
                }
            }
            return out.mapValues { $0.sorted() }
        }
        // A Repository value is needed unless every job reading the name
        // deploys to an environment that sets its own; one an expression
        // places, to each environment it may run in.
        func needed(_ key: LocalRunValueKey) -> Bool {
            let reading = placed.filter { (key.kind == .secret ? $0.job.secrets : $0.job.variables).contains(key.name) }
            return reading.isEmpty || reading.contains { $0.environment.isEmpty || !saved.contains(key.in($0.environment)) }
        }

        let repository = readers(nil)
        var known = Set(repository.keys).union(saved)
        var incomplete: Set<String?> = []
        if repository.keys.contains(where: { !saved.contains($0) && needed($0) }) { incomplete.insert(nil) }
        for name in named {
            let own = readers(name)
            known.formUnion(own.keys)
            if own.keys.contains(where: { !saved.contains($0) && !saved.contains($0.in(nil)) }) { incomplete.insert(name) }
        }
        self.incomplete = incomplete

        let shown = environment.map(readers) ?? repository
        let rows = shown.map { key, files in
            var row = Row(key: key, workflows: files, saved: saved.contains(key))
            if environment == nil {
                row.needed = needed(key)
                row.overriddenBy = named.filter { saved.contains(key.in($0)) }.sorted()
            } else {
                row.inherited = saved.contains(key.in(nil))
                row.needed = !row.inherited
            }
            return row
        }.sorted { $0.key < $1.key }
        secrets = rows.filter { $0.key.kind == .secret }
        variables = rows.filter { $0.key.kind == .variable }
        unused = saved.filter { $0.environment == environment && shown[$0] == nil }.sorted().map { Row(key: $0, workflows: [], saved: true) }
        return known
    }

    /// What the value field shows: a typed value, else the saved one when it
    /// is on screen, else nothing.
    func text(for key: LocalRunValueKey) -> String {
        if removals.contains(key) { return "" }
        return edits[key] ?? shown[key] ?? ""
    }

    /// Clearing a value that is on screen forgets it; an empty field over a
    /// hidden saved secret changes nothing.
    func setText(_ text: String, for key: LocalRunValueKey) {
        if text.isEmpty {
            edits[key] = nil
            if shown[key] != nil { removals.insert(key) }
            return
        }
        removals.remove(key)
        if text == shown[key] { edits[key] = nil } else { edits[key] = text }
    }

    func forget(_ key: LocalRunValueKey) {
        edits[key] = nil
        removals.insert(key)
    }

    func undoForget(_ key: LocalRunValueKey) { removals.remove(key) }

    /// Shows a saved secret once the Mac's owner confirms.
    func reveal(_ key: LocalRunValueKey, workspaceID: UUID, store: any LocalRunValueStoring,
                ask: @MainActor (String) async -> OwnerConfirmation) async {
        guard key.kind == .secret else { return }
        guard case .confirmed = await ask("show the saved value of \(key.name)") else { return }
        do { shown[key] = try await store.value(workspaceID: workspaceID, key: key) } catch { refused.insert(key) }
    }

    /// Hides revealed secrets, when the window loses focus or the section changes.
    func hideSecrets() { shown = shown.filter { $0.key.kind == .variable } }

    /// Writes the edits and removals; keeps them and says why on failure.
    func save(workspaceID: UUID, store: any LocalRunValueStoring) async -> Bool {
        do {
            for (key, value) in edits.sorted(by: { $0.key < $1.key }) {
                try await store.save(workspaceID: workspaceID, key: key, value: value)
            }
            for key in removals.sorted() { try await store.remove(workspaceID: workspaceID, key: key) }
        } catch {
            self.error = "Keychain did not save the changes. \(error.localizedDescription)"
            return false
        }
        let written = edits
        let forgotten = removals
        edits = [:]
        removals = []
        error = nil
        importSummary = nil
        for key in forgotten { shown[key] = nil }
        // Variables show their value; a secret on screen shows the new one.
        for (key, value) in written where key.kind == .variable || shown[key] != nil { shown[key] = value }
        savedKeys.formUnion(written.keys)
        savedKeys.subtract(forgotten)
        rebuild()
        return true
    }

    func revert() {
        edits = [:]
        removals = []
        importSummary = nil
    }

    /// Fills the names some workflow reads from a .env file, as edits.
    func apply(_ file: CoreEnvFile) {
        var filled = 0, notUsed = 0, encrypted = 0
        let known = (secrets + variables).map(\.key)
        for entry in file.entries {
            let keys = known.filter { $0.name == entry.name }
            if keys.isEmpty { notUsed += 1; continue }
            if entry.encrypted { encrypted += 1; continue }
            // An empty value or the one already there changes nothing.
            for key in keys where !entry.value.isEmpty && text(for: key) != entry.value {
                setText(entry.value, for: key)
                filled += 1
            }
        }
        var parts = ["Filled \(filled) \(filled == 1 ? "value" : "values")."]
        if notUsed > 0 { parts.append("\(notUsed) \(notUsed == 1 ? "name is" : "names are") not used by any workflow.") }
        if encrypted > 0 {
            parts.append("\(encrypted) \(encrypted == 1 ? "value is" : "values are") encrypted by dotenvx and \(encrypted == 1 ? "was" : "were") not imported.")
        }
        let lines = file.problems.map { String($0.line) }
        if lines.count == 1 { parts.append("Line \(lines[0]) could not be read.") }
        if lines.count > 1 { parts.append("Lines \(ListFormatter.localizedString(byJoining: lines)) could not be read.") }
        importSummary = parts.joined(separator: " ")
    }

    func showImportFailure(_ reason: String) { importSummary = reason }
}
