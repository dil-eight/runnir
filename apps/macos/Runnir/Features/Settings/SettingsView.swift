import SwiftUI

/// Settings › Runs: confirming manual runs.
struct ManualRunSettingsSection: View {
    @AppStorage(ManualRunSettings.confirmWithTouchIDKey) private var confirmWithTouchID = false

    var body: some View {
        Section("Manual Runs") {
            Toggle(isOn: $confirmWithTouchID) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Confirm with Touch ID before starting a workflow")
                    Text(caption).font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityIdentifier("confirm-manual-runs-touch-id")
        }
    }

    private var caption: String {
        let how = OwnerConfirmation.hasTouchID ? "Touch ID" : "your Mac's password (Touch ID is not set up on this Mac)"
        return "Run Workflow asks for \(how) after you review a run and before Runnir sends it to GitHub. Cancelling sends nothing. Off by default."
    }
}
