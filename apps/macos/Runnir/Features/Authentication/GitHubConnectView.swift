import AppKit
import SwiftUI

/// S02 GitHub connection: request a code, show it, wait for the browser, and
/// report every outcome with a next step.
struct GitHubConnectView: View {
    @Bindable var session: GitHubSession
    var installationURL: URL = GitHubAppConfiguration.runnirDesktop.installationURL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.checkmark").font(.system(size: 22))
                    .foregroundStyle(RunnirTheme.primary)
                Text("Connect GitHub").font(.system(size: 17, weight: .semibold))
            }
            content
            HStack {
                Spacer()
                actions
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(RunnirTheme.background)
        .foregroundStyle(RunnirTheme.foreground)
    }

    @ViewBuilder private var content: some View {
        switch session.connection {
        case .restoring, .requestingCode:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(session.connection == .restoring ? "Checking the saved sign-in..." : "Requesting a code from GitHub...")
            }
        case .signedOut(let problem):
            VStack(alignment: .leading, spacing: 8) {
                if let problem {
                    Label(problem.message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(RunnirTheme.warning)
                }
                Text("Runnir signs in with a one-time code that you confirm on github.com. Runnir never sees your password, and the authorization is stored only in your Keychain.")
                    .foregroundStyle(RunnirTheme.secondaryForeground)
                Text("Local repositories and offline validation work without signing in.")
                    .foregroundStyle(RunnirTheme.secondaryForeground)
            }.font(.system(size: 13))
        case .waiting(let authorization, let slower):
            VStack(alignment: .leading, spacing: 12) {
                Text("Enter this code on GitHub:").font(.system(size: 13))
                HStack(spacing: 12) {
                    // Not selectable: Copy is next to it. A selectable Text is
                    // an AppKit view, and an accessibility label on it made
                    // SwiftUI ask itself for the label until the stack ran
                    // out when an accessibility client read the sheet.
                    Text(authorization.userCode)
                        .font(.system(size: 28, weight: .semibold, design: .monospaced))
                        .accessibilityLabel("Code \(authorization.userCode)")
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(authorization.userCode, forType: .string)
                        copied = true
                    }
                }
                Text("The page \(authorization.verificationURL.host() ?? "github.com")\(authorization.verificationURL.path()) opened in your browser.")
                    .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(slower ? "Waiting for approval (GitHub asked Runnir to check less often)..." : "Waiting for approval...")
                        .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                }
            }
        case .signedIn(let user):
            VStack(alignment: .leading, spacing: 8) {
                Label("Signed in as \(user.login)", systemImage: "checkmark.circle").foregroundStyle(RunnirTheme.success)
                Text("Runnir sees only repositories where the Runnir Desktop app is installed. Install it on the accounts and repositories you want to use.")
                    .font(.system(size: 13)).foregroundStyle(RunnirTheme.secondaryForeground)
            }
        case .offline:
            Label("Signed in, but GitHub cannot be reached right now.", systemImage: "wifi.exclamationmark")
                .font(.system(size: 13)).foregroundStyle(RunnirTheme.warning)
        }
    }

    @ViewBuilder private var actions: some View {
        switch session.connection {
        case .restoring, .requestingCode:
            Button("Close") { dismiss() }
        case .signedOut:
            Button("Close") { dismiss() }
            Button("Connect") { copied = false; session.signIn() }.keyboardShortcut(.defaultAction)
        case .waiting:
            Button("Cancel") { session.cancelSignIn() }
            Button("Open GitHub Again") { session.reopenVerificationPage() }.keyboardShortcut(.defaultAction)
        case .signedIn:
            Button("Install on Repositories...") { openURL(installationURL) }
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        case .offline:
            Button("Close") { dismiss() }
            Button("Retry") { Task { await session.restore() } }.keyboardShortcut(.defaultAction)
        }
    }
}

/// The account row at the bottom of a workspace sidebar.
struct GitHubAccountRow: View {
    let session: GitHubSession
    @State private var showingConnect = false

    var body: some View {
        Button { showingConnect = true } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(RunnirTheme.secondaryForeground)
                VStack(alignment: .leading, spacing: 1) {
                    Text("GitHub").font(.system(size: 12))
                    Text(status).font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("GitHub connection")
        .sheet(isPresented: $showingConnect) { GitHubConnectView(session: session) }
    }

    private var status: String {
        switch session.connection {
        case .restoring: "Checking..."
        case .signedOut: "Not connected"
        case .requestingCode, .waiting: "Connecting..."
        case .signedIn(let user): user.login
        case .offline: "Offline"
        }
    }

    private var symbol: String {
        if case .signedIn = session.connection { return "person.crop.circle.fill" }
        return "person.crop.circle"
    }
}

/// Account section of the Settings window.
struct GitHubAccountSettings: View {
    let session: GitHubSession
    @Environment(\.openURL) private var openURL
    @State private var showingConnect = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch session.connection {
            case .signedIn(let user):
                Text("Signed in as \(user.login)")
                HStack {
                    Button("Sign Out") { Task { await session.signOut() } }
                    Button("Manage Repository Access...") { openURL(GitHubAppConfiguration.runnirDesktop.installationURL) }
                    Button("Manage Authorization on GitHub...") { openURL(GitHubSession.authorizationsURL) }
                }
                Text("Runnir sees only repositories where the Runnir Desktop app is installed. Manage Repository Access adds or removes them on GitHub.")
                    .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                Text("Sign Out removes the authorization from this Mac's Keychain. To revoke Runnir's access entirely, use Manage Authorization on GitHub.")
                    .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
            case .offline:
                Text("Signed in; GitHub is unreachable right now.")
                Button("Sign Out") { Task { await session.signOut() } }
            default:
                Text("Not connected").foregroundStyle(RunnirTheme.secondaryForeground)
                Button("Connect GitHub...") { showingConnect = true }
            }
        }
        .sheet(isPresented: $showingConnect) { GitHubConnectView(session: session) }
    }
}
