import SwiftUI

enum AppSection: String, CaseIterable, Identifiable, Codable, Sendable {
    case dashboard
    case repositories
    case workflows
    case runs
    case artifacts
    case workspace

    var id: String { rawValue }

    /// Sections no longer reachable from the window; a saved window that was
    /// on one opens on Overview instead.
    static let retired: Set<AppSection> = [.repositories]

    var restored: AppSection { Self.retired.contains(self) ? .dashboard : self }
    static let sidebarSections: [AppSection] = [.dashboard, .workflows, .runs, .workspace]

    var title: String {
        switch self {
        case .dashboard: "Overview"
        case .repositories: "Repositories"
        case .workflows: "Workflows"
        case .runs: "Runs"
        case .artifacts: "Artifacts"
        case .workspace: "Workspace"
        }
    }

    var symbolName: String {
        switch self {
        case .dashboard: "rectangle.3.group"
        case .repositories: "shippingbox"
        case .workflows: "point.3.connected.trianglepath.dotted"
        case .runs: "play.circle"
        case .artifacts: "archivebox"
        case .workspace: "folder"
        }
    }
}
