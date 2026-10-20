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
        let text = (input.name + " " + input.description).lowercased()
        if ["secret", "token", "passw", "passphrase", "credential", "apikey", "privatekey"].contains(where: text.contains) {
            return true
        }
        let secretWords: Set<String> = ["key", "pat", "pwd", "pass", "otp", "pin", "auth", "cert", "cookie", "session"]
        return !secretWords.isDisjoint(with: words(input.name)) || !secretWords.isDisjoint(with: words(input.description))
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
