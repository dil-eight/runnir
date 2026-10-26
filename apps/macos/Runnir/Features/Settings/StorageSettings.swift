import SwiftUI

/// Settings › Storage, kept in UserDefaults.
enum StorageSettings {
    /// Whether finished jobs' logs are kept on this Mac; off by default.
    static let keepJobLogsKey = "storage.keepJobLogs"
    /// Keeping logs was turned off and no Core has confirmed deleting the
    /// kept ones yet.
    static let logDeletionPendingKey = "storage.logDeletionPending"
}

/// One workspace in Settings › Storage.
struct StorageRow: Identifiable, Equatable {
    let id: UUID
    let name: String
    let detail: String
    /// nil: nothing saved on this Mac.
    let storage: CoreWorkspaceStorage?
    let isRegistered: Bool
}

@MainActor
@Observable
final class StorageSettingsModel {
    private(set) var rows: [StorageRow] = []
    private(set) var isLoading = false
    private(set) var keepJobLogs: Bool
    @ObservationIgnored private let hub: CoreHub?
    @ObservationIgnored private let workspaces: @MainActor () -> [WorkspaceRecord]
    @ObservationIgnored private let defaults: UserDefaults

    init(hub: CoreHub?, workspaces: @escaping @MainActor () -> [WorkspaceRecord], defaults: UserDefaults = .standard) {
        self.hub = hub
        self.workspaces = workspaces
        self.defaults = defaults
        keepJobLogs = defaults.bool(forKey: StorageSettings.keepJobLogsKey)
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        let usage = await hub?.storageUsage()
        let byID = Dictionary((usage?.workspaces ?? []).map { ($0.workspaceID, $0) }, uniquingKeysWith: { first, _ in first })
        let registered = workspaces().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        var out = registered.map { StorageRow(id: $0.id, name: $0.name, detail: $0.path, storage: byID[$0.id], isRegistered: true) }
        let known = Set(registered.map(\.id))
        for storage in usage?.workspaces ?? [] where !known.contains(storage.workspaceID) && storage.state != .absent {
            out.append(StorageRow(id: storage.workspaceID, name: "Removed workspace", detail: storage.workspaceID.uuidString,
                                  storage: storage, isRegistered: false))
        }
        rows = out
    }

    func clear(_ ids: [UUID]) async {
        await hub?.clearCache(workspaceIDs: ids)
        await load()
    }

    func clearAll() async { await clear([]) }

    func delete(_ id: UUID) async {
        await hub?.deleteWorkspaceData(id)
        await load()
    }

    func setKeepJobLogs(_ keep: Bool) async {
        keepJobLogs = keep
        defaults.set(keep, forKey: StorageSettings.keepJobLogsKey)
        defaults.set(!keep, forKey: StorageSettings.logDeletionPendingKey)
        await hub?.pushStoragePreferences()
        await load()
    }

    /// "12 saved runs · 1 local run · 3 MB", or why nothing is saved.
    static func summary(_ storage: CoreWorkspaceStorage?) -> String {
        guard let storage, storage.state != .absent else { return "Nothing saved on this Mac" }
        var parts = ["\(storage.cachedRuns) saved \(storage.cachedRuns == 1 ? "run" : "runs")",
                     "\(storage.localRuns) local \(storage.localRuns == 1 ? "run" : "runs")"]
        if storage.logBytes > 0 { parts.append("logs " + ByteCountFormatter.string(fromByteCount: Int64(storage.logBytes), countStyle: .file)) }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(storage.databaseBytes), countStyle: .file))
        if storage.recoveryCopies > 0 { parts.append("\(storage.recoveryCopies) recovery \(storage.recoveryCopies == 1 ? "copy" : "copies")") }
        return parts.joined(separator: " · ")
    }
}

/// Settings › Storage: what each workspace keeps on this Mac.
struct StorageSettingsSection: View {
    @State var model: StorageSettingsModel
    @State private var confirming: Confirmation?

    private enum Confirmation: Identifiable {
        case clear(StorageRow), clearAll, delete(StorageRow), stopKeepingLogs
        var id: String {
            switch self {
            case .clear(let row): "clear-\(row.id)"
            case .clearAll: "clear-all"
            case .delete(let row): "delete-\(row.id)"
            case .stopKeepingLogs: "logs"
            }
        }
    }

    var body: some View {
        Section("Job Logs") {
            Toggle("Keep job logs on this Mac", isOn: Binding(
                get: { model.keepJobLogs },
                set: { keep in if keep { Task { await model.setKeepJobLogs(true) } } else { confirming = .stopKeepingLogs } })).handPointer()
            Text("Logs of finished jobs open offline and are not downloaded again. They can contain output your workflows print; they stay in Runnir's folder on this Mac, up to 100 MB per workspace.")
                .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
        }
        Section("Workspaces") {
            ForEach(model.rows) { row in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name)
                        Text(StorageSettingsModel.summary(row.storage)).font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                        if let note = row.storage?.note {
                            Text(note).font(.system(size: 12)).foregroundStyle(RunnirTheme.warning)
                        }
                    }
                    Spacer()
                    if row.isRegistered {
                        Button("Clear Cache…") { confirming = .clear(row) }.disabled(row.storage == nil)
                    } else {
                        Button("Delete…", role: .destructive) { confirming = .delete(row) }
                    }
                }
            }
            HStack {
                Text("Clearing keeps local run history, presets, favorites and your sign-in. Saved activity downloads again when a workspace opens.")
                    .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                Spacer()
                Button("Clear All Caches…") { confirming = .clearAll }.disabled(model.rows.allSatisfy { $0.storage == nil })
            }
        }
        .task { await model.load() }
        .confirmationDialog(title, isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
            switch confirming {
            case .clear(let row): Button("Clear Cache") { Task { await model.clear([row.id]) } }
            case .clearAll: Button("Clear All Caches") { Task { await model.clearAll() } }
            case .delete(let row): Button("Delete", role: .destructive) { Task { await model.delete(row.id) } }
            case .stopKeepingLogs: Button("Stop and Delete Logs", role: .destructive) { Task { await model.setKeepJobLogs(false) } }
            case nil: EmptyView()
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: {
            Text(message)
        }
    }

    private var title: String {
        switch confirming {
        case .clear(let row): "Clear the cache of \(row.name)?"
        case .clearAll: "Clear every workspace's cache?"
        case .delete: "Delete this removed workspace's data?"
        case .stopKeepingLogs: "Stop keeping job logs?"
        case nil: ""
        }
    }

    private var message: String {
        switch confirming {
        case .clear, .clearAll: "Saved runs, jobs, workflows and kept logs are deleted and download again. Local run history, presets, favorites and your sign-in stay."
        case .delete: "Its saved activity and local run history are deleted from this Mac. Nothing in any repository changes."
        case .stopKeepingLogs: "Logs kept so far are deleted from this Mac."
        case nil: ""
        }
    }
}
