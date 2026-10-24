import Foundation
import Observation

/// Workflows for which the user turned the concurrency suggestion off, per
/// workspace, kept on this Mac in UserDefaults.
@MainActor
@Observable
final class ConcurrencyHintDismissals {
    static let key = "dismissedConcurrencyHints"
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var dismissed: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dismissed = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func isDismissed(_ path: String, workspaceID: UUID) -> Bool {
        dismissed.contains(Self.entry(path, workspaceID))
    }

    func dismiss(_ path: String, workspaceID: UUID) {
        dismissed.insert(Self.entry(path, workspaceID))
        save()
    }

    /// Forgets a removed workspace's choices.
    func removeAll(workspaceID: UUID) {
        let prefix = workspaceID.uuidString.lowercased() + "|"
        dismissed = dismissed.filter { !$0.hasPrefix(prefix) }
        save()
    }

    private func save() { defaults.set(dismissed.sorted(), forKey: Self.key) }

    private static func entry(_ path: String, _ workspaceID: UUID) -> String {
        workspaceID.uuidString.lowercased() + "|" + path
    }
}
