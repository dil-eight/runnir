import SwiftUI

struct DashboardView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HeaderView(
                title: "Dashboard",
                subtitle: "Your local-first command center for GitHub Actions."
            )

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 16) {
                GridRow {
                    StatusCard(title: "Authentication", value: authenticationLabel, symbol: "person.crop.circle.badge.checkmark")
                    StatusCard(title: "Repositories", value: "Connect GitHub to load repositories", symbol: "shippingbox")
                }
                GridRow {
                    StatusCard(title: "Workflows", value: "Ready for GitHub Actions discovery", symbol: "point.3.connected.trianglepath.dotted")
                    StatusCard(title: "Privacy", value: "No telemetry by default", symbol: "lock.shield")
                }
            }

            Spacer()
        }
        .padding(RunnirTheme.contentPadding)
    }

    private var authenticationLabel: String {
        switch appState.authenticationState {
        case .unknown: "Not checked"
        case .unauthenticated: "Not authenticated"
        case .authenticated(let user): "Signed in as \(user.login)"
        }
    }
}

private struct StatusCard: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.headline)
            Text(value)
                .foregroundStyle(RunnirTheme.secondaryForeground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
