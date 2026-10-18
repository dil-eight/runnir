import SwiftUI

struct SettingsView: View {
    var github: GitHubSession?

    var body: some View {
        Form {
            Section("GitHub") {
                if let github {
                    GitHubAccountSettings(session: github)
                } else {
                    Text("GitHub sign-in is not available.").foregroundStyle(RunnirTheme.secondaryForeground)
                }
            }

            Section("Privacy") {
                Text("Runnir does not enable telemetry by default and does not send repository data to a Runnir backend.")
                    .foregroundStyle(RunnirTheme.secondaryForeground)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 520)
    }
}
