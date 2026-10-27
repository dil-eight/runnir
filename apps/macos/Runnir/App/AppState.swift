import Foundation
import Observation

/// How the Runs section lists runs.
enum RunsMode: String, Codable, Sendable {
    case list
    case byChange
}

/// A search the global search asks the Runs list to show.
struct RunsListRequest: Equatable, Sendable {
    var query: String
    /// The query is typed only when the saved runs do not hold this run.
    var unlessSaved: Int64?
}

@MainActor
@Observable
final class AppState {
    var selectedSection: AppSection = .dashboard
    /// The workspace switcher is showing in this window.
    var showingSwitcher = false
    /// The run shown in the Runs section.
    var selectedRunID: Int64?
    /// The Runs section's list or changes; List until the user switches.
    var runsMode: RunsMode = .list
    /// Shows the Run Workflow sheet.
    var runWorkflowRequest: RunWorkflowRequest?
    /// The Workspace section shows the editor or the local run.
    var workspaceTab: WorkspaceTab = .editor
    /// Shows the Run Locally review sheet.
    var localRunRequest: LocalRunRequest?
    /// The workflow selected in the Overview, kept while switching sections.
    var overviewWorkflowPath: String?
    /// Set by the global search, taken by the Runs list.
    var runsRequest: RunsListRequest?
    /// The workflow files of this window and the one in its editor.
    let files: WorkspaceFilesModel
    /// The Secrets and Variables section: names, saved values and edits.
    let values: WorkspaceValuesModel

    /// Shows where a search result leads. Settings and pull requests open
    /// elsewhere and are not handled here.
    func go(to destination: SearchDestination) {
        switch destination {
        case .run(let id, let number):
            selectedSection = .runs
            selectedRunID = id
            runsRequest = RunsListRequest(query: "#\(number)", unlessSaved: id)
        case .runsList(let query):
            selectedSection = .runs
            runsRequest = RunsListRequest(query: query)
        case .workflow(let path):
            selectedSection = .dashboard
            overviewWorkflowPath = path
        case .localRuns:
            selectedSection = .workspace
            workspaceTab = .localRun
        case .pullRequest, .setting:
            break
        }
    }

    init(files: WorkspaceFilesModel = WorkspaceFilesModel(), values: WorkspaceValuesModel = WorkspaceValuesModel()) {
        self.files = files
        self.values = values
    }
}
