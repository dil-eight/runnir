import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    var selectedSection: AppSection = .dashboard
    /// The workspace switcher is showing in this window.
    var showingSwitcher = false
    /// The run shown in the Runs section.
    var selectedRunID: Int64?
    /// Shows the Run Workflow sheet.
    var runWorkflowRequest: RunWorkflowRequest?
    /// The Workspace section shows the editor or the local run.
    var workspaceTab: WorkspaceTab = .editor
    /// Shows the Run Locally review sheet.
    var localRunRequest: LocalRunRequest?
    /// The workflow selected in the Overview, kept while switching sections.
    var overviewWorkflowPath: String?
    /// The workflow files of this window and the one in its editor.
    let files: WorkspaceFilesModel

    init(files: WorkspaceFilesModel = WorkspaceFilesModel()) {
        self.files = files
    }
}
