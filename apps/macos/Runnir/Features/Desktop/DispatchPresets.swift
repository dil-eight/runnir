import CryptoKit
import Foundation
import Observation

/// A saved branch and input values for one workflow of one workspace. Kept on
/// this Mac only; values of inputs that look secret are never saved.
struct DispatchPreset: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    let workspaceID: UUID
    /// ".github/workflows/<file>", as GitHub reports the workflow's path.
    let workflowPath: String
    var ref: String
    var inputs: [String: String]
    var updatedAt: Date

    static let maxNameLength = 80
    static let maxInputs = 25
    static let maxValueLength = 4096

    var isValid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && name.count <= Self.maxNameLength && !workflowPath.isEmpty
            && !ref.isEmpty && ref.count <= 255 && inputs.count <= Self.maxInputs
            && inputs.allSatisfy { !$0.key.isEmpty && $0.key.count <= 100 && $0.value.count <= Self.maxValueLength }
    }

    /// Inputs whose name or description suggests a secret. This is a
    /// heuristic: the app cannot know what an input carries, so the sheet
    /// says which inputs are left out rather than promising none are kept.
    static func looksSecret(_ input: CoreDispatchInput) -> Bool {
        looksSecret(name: input.name, description: input.description)
    }

    /// The same check from a name and, when known, the input's description.
    static func looksSecret(name: String, description: String) -> Bool {
        let text = (name + " " + description).lowercased()
        if ["secret", "token", "passw", "passphrase", "credential", "apikey", "privatekey"].contains(where: text.contains) {
            return true
        }
        let secretWords: Set<String> = ["key", "pat", "pwd", "pass", "otp", "pin", "auth", "cert", "cookie", "session"]
        return !secretWords.isDisjoint(with: words(name)) || !secretWords.isDisjoint(with: words(description))
    }

    /// Lowercased words of an identifier or sentence: "deployKey" and
    /// "deploy_key" both give ["deploy", "key"].
    static func words(_ text: String) -> Set<String> {
        var words: Set<String> = []
        var current = ""
        var previousWasLower = false
        for character in text {
            if character.isLetter || character.isNumber {
                if character.isUppercase && previousWasLower, !current.isEmpty {
                    words.insert(current)
                    current = ""
                }
                current.append(Character(character.lowercased()))
                previousWasLower = character.isLowercase || character.isNumber
            } else {
                if !current.isEmpty { words.insert(current) }
                current = ""
                previousWasLower = false
            }
        }
        if !current.isEmpty { words.insert(current) }
        return words
    }
}

protocol DispatchPresetStoring: Sendable {
    func load() throws -> [DispatchPreset]
    func save(_ presets: [DispatchPreset]) throws
}

/// dispatch-presets.json in the app's support directory (inside the container
/// when sandboxed): versioned, bounded, written atomically with mode 0600.
struct FileDispatchPresetStore: DispatchPresetStoring {
    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("dispatch-presets.json") }

    static let maxPresets = 500
    static let maxFileBytes = 2 * 1024 * 1024

    private struct Snapshot: Codable {
        var version = 1
        var presets: [DispatchPreset]
    }

    static func live() throws -> FileDispatchPresetStore {
        FileDispatchPresetStore(directory: try RunnirSupportDirectory.url())
    }

    func load() throws -> [DispatchPreset] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= Self.maxFileBytes else { throw DesktopStoreError.tooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(Snapshot.self, from: Data(contentsOf: fileURL))
        guard snapshot.version == 1, snapshot.presets.count <= Self.maxPresets,
              snapshot.presets.allSatisfy(\.isValid) else { throw DesktopStoreError.invalidState }
        return snapshot.presets
    }

    func save(_ presets: [DispatchPreset]) throws {
        guard presets.count <= Self.maxPresets, presets.allSatisfy(\.isValid) else { throw DesktopStoreError.invalidState }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Snapshot(presets: presets))
        guard data.count <= Self.maxFileBytes else { throw DesktopStoreError.tooLarge }
        try AtomicFile.write(data, to: fileURL)
    }
}

/// The app's presets, read on first use. When the file cannot be read the
/// presets are unavailable for the session and nothing overwrites the file.
@MainActor
@Observable
final class DispatchPresetLibrary {
    private(set) var presets: [DispatchPreset] = []
    /// Why presets are unavailable or the last change was not saved.
    private(set) var problem: String?
    @ObservationIgnored private let store: (any DispatchPresetStoring)?
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var readable = true

    static let perWorkflowLimit = 50

    init(store: (any DispatchPresetStoring)?) {
        self.store = store
    }

    /// Reads the file once; call before showing presets.
    func prepare() { loadIfNeeded() }

    var isAvailable: Bool { store != nil && readable }

    func presets(workspaceID: UUID, workflowPath: String) -> [DispatchPreset] {
        presets.filter { $0.workspaceID == workspaceID && $0.workflowPath == workflowPath }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func preset(id: UUID) -> DispatchPreset? {
        presets.first { $0.id == id }
    }

    /// Adds a preset; nil when it cannot be saved (see `problem`).
    @discardableResult
    func add(name: String, workspaceID: UUID, workflowPath: String, ref: String, inputs: [String: String]) -> DispatchPreset? {
        let preset = DispatchPreset(id: UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                    workspaceID: workspaceID, workflowPath: workflowPath, ref: ref, inputs: inputs, updatedAt: Date())
        guard preset.isValid else {
            problem = "The preset needs a name of at most \(DispatchPreset.maxNameLength) characters, and values of at most \(DispatchPreset.maxValueLength)."
            return nil
        }
        loadIfNeeded()
        guard self.presets(workspaceID: workspaceID, workflowPath: workflowPath).count < Self.perWorkflowLimit else {
            problem = "A workflow can have at most \(Self.perWorkflowLimit) presets."
            return nil
        }
        return commit(presets + [preset]) ? preset : nil
    }

    @discardableResult
    func update(_ id: UUID, ref: String, inputs: [String: String]) -> Bool {
        change(id) { $0.ref = ref; $0.inputs = inputs }
    }

    @discardableResult
    func rename(_ id: UUID, to name: String) -> Bool {
        change(id) { $0.name = name.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    @discardableResult
    func delete(_ id: UUID) -> Bool {
        commit(presets.filter { $0.id != id })
    }

    /// Copies a workflow's presets to the path a rename gave its file. The
    /// old ones stay: GitHub runs the workflow under its old path until the
    /// rename reaches the default branch, and Run Workflow looks presets up
    /// by that path. A preset whose name the new path already has (after
    /// renaming back, say) is not copied again; the per-workflow limit holds.
    func copyWorkflowPresets(workspaceID: UUID, from oldPath: String, to newPath: String) {
        loadIfNeeded()
        guard oldPath != newPath else { return }
        let existing = self.presets(workspaceID: workspaceID, workflowPath: newPath)
        let names = Set(existing.map(\.name))
        let copies = self.presets(workspaceID: workspaceID, workflowPath: oldPath)
            .filter { !names.contains($0.name) }
            .prefix(max(0, Self.perWorkflowLimit - existing.count))
            .map { DispatchPreset(id: UUID(), name: $0.name, workspaceID: workspaceID, workflowPath: newPath,
                                  ref: $0.ref, inputs: $0.inputs, updatedAt: Date()) }
        guard !copies.isEmpty else { return }
        commit(presets + copies)
    }

    /// Removes a workspace's presets with its registration.
    func removeAll(workspaceID: UUID) {
        loadIfNeeded()
        guard presets.contains(where: { $0.workspaceID == workspaceID }) else { return }
        commit(presets.filter { $0.workspaceID != workspaceID })
    }

    private func change(_ id: UUID, _ edit: (inout DispatchPreset) -> Void) -> Bool {
        loadIfNeeded()
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return false }
        var candidate = presets
        edit(&candidate[index])
        candidate[index].updatedAt = Date()
        guard candidate[index].isValid else {
            problem = "The preset needs a name of at most \(DispatchPreset.maxNameLength) characters, and values of at most \(DispatchPreset.maxValueLength)."
            return false
        }
        return commit(candidate)
    }

    @discardableResult
    private func commit(_ candidate: [DispatchPreset]) -> Bool {
        loadIfNeeded()
        guard let store, readable else {
            problem = problem ?? "Presets are not available."
            return false
        }
        do {
            try store.save(candidate)
            presets = candidate
            problem = nil
            return true
        } catch {
            problem = "The preset could not be saved. Check available storage and try again."
            return false
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let store else { return }
        do {
            presets = try store.load()
        } catch {
            readable = false
            problem = "Saved presets could not be read, so presets are off for now. The file was left as it is."
        }
    }
}

// MARK: Repository presets

extension CoreLaunchPreset {
    /// Whether the Run Workflow form can use it.
    var isUsable: Bool { problem == nil }

    /// The file name for a problem row, or the folder for an entry about it.
    var fileName: String {
        let folder = ".runnir/launches/"
        return path.hasPrefix(folder) ? String(path.dropFirst(folder.count)) : path
    }

    /// The preset as the Run Workflow form applies it. Its branch is empty
    /// when the preset keeps the form's.
    func dispatchPreset(workspaceID: UUID) -> DispatchPreset {
        DispatchPreset(id: Self.presetID(workspaceID: workspaceID, path: path), name: name, workspaceID: workspaceID,
                       workflowPath: workflowPath, ref: ref ?? "", inputs: inputs, updatedAt: .distantPast)
    }

    /// A name-based id from the workspace and the file, so a preset keeps it
    /// across rescans and the Overview can hand it to Run Workflow.
    static func presetID(workspaceID: UUID, path: String) -> UUID {
        var b = Array(SHA256.hash(data: Data((workspaceID.uuidString + "\n" + path).utf8)).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50 // version 5: name-based
        b[8] = (b[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

extension CoreLaunchPreset {
    /// Menu order: by name as Finder sorts ("P2" before "P10", case
    /// ignored), then by file.
    static func menuOrder(_ a: CoreLaunchPreset, _ b: CoreLaunchPreset) -> Bool {
        switch a.name.localizedStandardCompare(b.name) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: a.path < b.path
        }
    }
}

extension DispatchPreset {
    /// "Deploy · main · environment=staging": the workflow, the branch when
    /// set, then the values by name. A value is hidden when its input looks
    /// secret, judged with the description `declared` gives for it.
    static func detail(workflow: String, ref: String, inputs: [String: String], declared: [CoreDispatchInput] = []) -> String {
        let descriptions = Dictionary(declared.map { ($0.name, $0.description) }, uniquingKeysWith: { first, _ in first })
        let values = inputs.sorted { $0.key < $1.key }.map { name, value in
            "\(name)=\(looksSecret(name: name, description: descriptions[name] ?? "") ? "•••" : value)"
        }
        return ([workflow] + (ref.isEmpty ? [] : [ref]) + values).joined(separator: " · ")
    }
}

/// One row of Overview › Run manually's repository group.
enum RepositoryPresetRow: Equatable, Identifiable {
    /// A usable preset; `workflow` is GitHub's workflow for its file, nil
    /// when GitHub's list does not have it.
    case preset(CoreLaunchPreset, workflow: CoreGitHubWorkflow?)
    /// A file or folder that cannot be used.
    case problem(CoreLaunchPreset)
    /// The presets could not be read; the reason.
    case unreadable(String)

    var id: String {
        switch self {
        case .preset(let preset, _): "preset:" + preset.path
        case .problem(let preset): "problem:" + preset.path
        case .unreadable: "unreadable"
        }
    }

    /// Usable presets in menu order, then problems as the Core lists them,
    /// then a row for a failed read.
    static func rows(presets: [CoreLaunchPreset], remoteWorkflows: [CoreGitHubWorkflow], readError: String?) -> [RepositoryPresetRow] {
        var rows = presets.filter(\.isUsable).sorted(by: CoreLaunchPreset.menuOrder).map { preset -> RepositoryPresetRow in
            .preset(preset, workflow: remoteWorkflows.first { $0.path == preset.workflowPath })
        }
        rows += presets.filter { !$0.isUsable }.map { .problem($0) }
        if let readError { rows.append(.unreadable(readError)) }
        return rows
    }

    /// Run is offered while GitHub can be used and runs the preset's workflow.
    static func canRun(workflow: CoreGitHubWorkflow?, available: Bool) -> Bool {
        available && workflow?.state == "active"
    }

    /// A usable preset's detail line. `declared` are the inputs the local
    /// workflow file declares. "not on GitHub yet" is added only while
    /// GitHub's list is known (`available`); without it every Run is off.
    static func detail(_ preset: CoreLaunchPreset, workflow: CoreGitHubWorkflow?, declared: [CoreDispatchInput], available: Bool) -> String {
        let name = workflow?.name ?? (preset.workflowPath as NSString).lastPathComponent
        let detail = DispatchPreset.detail(workflow: name, ref: preset.ref ?? "", inputs: preset.inputs, declared: declared)
        return workflow == nil && available ? detail + " · not on GitHub yet" : detail
    }
}
