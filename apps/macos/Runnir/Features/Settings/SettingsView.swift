import SwiftUI

struct SettingsView: View {
    var body: some View {
        Form {
            Section("GitHub") {
                Text("Authentication uses Keychain-backed credentials. OAuth/device-flow configuration is documented before enabling login.")
                    .foregroundStyle(RunnirTheme.secondaryForeground)
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
