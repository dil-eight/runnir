import Foundation

/// The Secrets and Variables section of one window (S16): the names the
/// workspace's workflows read, which have saved values, and edits not saved
/// yet. A saved secret's value is read only to show it after Touch ID.
@MainActor
@Observable
final class WorkspaceValuesModel {
    struct Row: Identifiable, Equatable {
        let key: LocalRunValueKey
        /// File names of the workflows that read it; empty in `unused`.
        let workflows: [String]
        var saved: Bool
        var id: LocalRunValueKey { key }
    }

    private(set) var secrets: [Row] = []
    private(set) var variables: [Row] = []
    /// Saved values no workflow reads any more.
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

    func load(workspaceID: UUID, workflows: [CoreWorkflow], store: any LocalRunValueStoring) async {
        let saved: Set<LocalRunValueKey>
        do {
            saved = try await store.keys(workspaceID: workspaceID)
        } catch {
            self.error = "Keychain did not list the saved values. \(error.localizedDescription)"
            return
        }
        var readers: [LocalRunValueKey: [String]] = [:]
        for workflow in workflows {
            let file = (workflow.id as NSString).lastPathComponent
            for name in workflow.secrets { readers[LocalRunValueKey(kind: .secret, name: name), default: []].append(file) }
            for name in workflow.variables { readers[LocalRunValueKey(kind: .variable, name: name), default: []].append(file) }
        }
        let rows = readers.map { Row(key: $0.key, workflows: $0.value.sorted(), saved: saved.contains($0.key)) }.sorted { $0.key < $1.key }
        secrets = rows.filter { $0.key.kind == .secret }
        variables = rows.filter { $0.key.kind == .variable }
        unused = saved.subtracting(readers.keys).sorted().map { Row(key: $0, workflows: [], saved: true) }
        shown = shown.filter { $0.key.kind == .secret && saved.contains($0.key) }
        refused = []
        error = nil
        for key in saved.sorted() where key.kind == .variable {
            do { shown[key] = try await store.value(workspaceID: workspaceID, key: key) } catch { refused.insert(key) }
        }
    }

    /// What the value field shows: a typed value, else the saved one when it
    /// is on screen, else nothing.
    func text(for key: LocalRunValueKey) -> String {
        if removals.contains(key) { return "" }
        return edits[key] ?? shown[key] ?? ""
    }

    func setText(_ text: String, for key: LocalRunValueKey) {
        removals.remove(key)
        if text == (shown[key] ?? "") { edits[key] = nil } else { edits[key] = text }
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
        for (key, value) in written where key.kind == .variable { shown[key] = value }
        func mark(_ rows: inout [Row]) {
            for index in rows.indices {
                if written[rows[index].key] != nil { rows[index].saved = true }
                if forgotten.contains(rows[index].key) { rows[index].saved = false }
            }
        }
        mark(&secrets)
        mark(&variables)
        unused.removeAll { forgotten.contains($0.key) }
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
            for key in keys {
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
