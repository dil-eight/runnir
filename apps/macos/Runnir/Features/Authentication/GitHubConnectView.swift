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
    /// Signing in with a personal access token instead of the Device Flow.
    @State private var usingToken = false
    @State private var token = ""
    @State private var tokenCheck: CoreGitHubTokenCheck?
    @State private var checkingToken = false

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
        .frame(width: usingToken ? 520 : 440)
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
        case .signedOut where usingToken:
            GitHubTokenForm(token: $token, check: tokenCheck, checking: checkingToken)
                .onChange(of: token) { tokenCheck = nil }
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
                    }.handPointer()
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
            Button("Close") { dismiss() }.handPointer()
        case .signedOut where usingToken:
            Button("Back") { usingToken = false; token = ""; tokenCheck = nil }.handPointer()
            if let tokenCheck, tokenCheck.access == .ok {
                Button(tokenCheck.suitable ? "Use This Token" : "Use Anyway") { useToken() }.handPointer()
                    .keyboardShortcut(tokenCheck.suitable ? .defaultAction : nil)
                    .help(tokenCheck.suitable ? "Sign in with this token" : "Sign in with it; what it lacks shows up where it is needed")
            }
            if tokenCheck == nil || tokenCheck?.access != .ok {
                Button(checkingToken ? "Checking..." : "Check Token") { checkToken() }
                    .buttonStyle(DesignButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || checkingToken)
            }
        case .signedOut:
            Button("Close") { dismiss() }.handPointer()
            if session.tokenChecker != nil {
                Button("Use a Token Instead...") { usingToken = true }.handPointer()
                    .help("Sign in with a personal access token: Runnir checks what it can do first")
            }
            Button("Connect") { copied = false; session.signIn() }.buttonStyle(DesignButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
        case .waiting:
            Button("Cancel") { session.cancelSignIn() }.handPointer()
            Button("Open GitHub Again") { session.reopenVerificationPage() }.buttonStyle(DesignButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
        case .signedIn:
            Button("Install on Repositories...") { openURL(installationURL) }.handPointer()
            Button("Done") { dismiss() }.buttonStyle(DesignButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
        case .offline:
            Button("Close") { dismiss() }.handPointer()
            Button("Retry") { Task { await session.restore() } }.buttonStyle(DesignButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
        }
    }
}

extension GitHubConnectView {
    private func checkToken() {
        guard let checker = session.tokenChecker else { return }
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        checkingToken = true
        Task {
            let result = await checker(value)
            // The field may have changed while GitHub answered.
            if value == token.trimmingCharacters(in: .whitespacesAndNewlines) { tokenCheck = result }
            checkingToken = false
        }
    }

    private func useToken() {
        let value = token
        token = ""
        tokenCheck = nil
        usingToken = false
        Task { await session.useToken(value) }
    }
}

/// Pasting a personal access token: what Runnir found it can do, and what to
/// choose for a new one when it does not fit.
struct GitHubTokenForm: View {
    @Binding var token: String
    let check: CoreGitHubTokenCheck?
    let checking: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste a personal access token. Runnir asks GitHub what it can do before using it, and keeps it only in your Keychain.")
                .font(.system(size: 13)).foregroundStyle(RunnirTheme.secondaryForeground).fixedSize(horizontal: false, vertical: true)
            SecureField("github_pat_… or ghp_…", text: $token)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("github-token")
            if checking {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Asking GitHub what the token can do...") }
                    .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
            } else if let check {
                GitHubTokenCheckView(check: check)
            }
            if check.map({ !$0.suitable }) ?? true {
                GitHubTokenAdvice(emphasized: check != nil && check?.access == .ok)
            }
        }
    }
}

/// The result of a token check, item by item.
struct GitHubTokenCheckView: View {
    let check: CoreGitHubTokenCheck

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if check.access == .ok {
                Text(summary).font(.system(size: 13, weight: .medium))
                ForEach(check.checks) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: symbol(item.state)).foregroundStyle(tint(item.state)).padding(.top, 1)
                            .accessibilityLabel(label(item.state))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.system(size: 12, weight: .medium))
                            Text(item.detail).font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } else {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(RunnirTheme.warning).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RunnirTheme.surface, in: RoundedRectangle(cornerRadius: 6))
    }

    private var summary: String {
        var text = Self.kindName(check.kind) + (check.login.isEmpty ? "" : " for \(check.login)")
        if let expires = check.expiresAt { text += " · expires \(expires.formatted(date: .abbreviated, time: .omitted))" }
        return text
    }

    static func kindName(_ kind: CoreGitHubCredentialKind) -> String {
        switch kind {
        case .appUser: "Runnir Desktop sign-in"
        case .classic: "Classic token"
        case .fineGrained: "Fine-grained token"
        case .oauth: "OAuth token"
        case .other: "Token"
        }
    }

    private var problem: String {
        switch check.access {
        case .tokenRejected, .signedOut: "GitHub does not accept this token: it may be mistyped, expired or revoked."
        case .rateLimited: "GitHub is limiting requests. Try again in a moment."
        default: "GitHub or Runnir Core could not be reached. Try again."
        }
    }

    private func symbol(_ state: CoreGitHubTokenCheck.State) -> String {
        switch state {
        case .passed: "checkmark.circle.fill"
        case .missing: "xmark.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private func tint(_ state: CoreGitHubTokenCheck.State) -> Color {
        switch state {
        case .passed: RunnirTheme.success
        case .missing: RunnirTheme.destructive
        case .unknown: RunnirTheme.secondaryForeground
        }
    }

    private func label(_ state: CoreGitHubTokenCheck.State) -> String {
        switch state {
        case .passed: "Has it"
        case .missing: "Missing"
        case .unknown: "Not known yet"
        }
    }
}

/// What to choose for a token Runnir can use.
struct GitHubTokenAdvice: View {
    /// The token checked does not fit: say so first.
    var emphasized = false
    /// The server's web URL, for the links; github.com unless an
    /// Enterprise server is being added.
    var webURL: URL = GitHubTokenAdvice.dotComWebURL
    /// An Enterprise server: say which versions have fine-grained tokens.
    var enterprise = false
    @Environment(\.openURL) private var openURL

    nonisolated static let dotComWebURL = URL(string: "https://github.com")!

    nonisolated static func newFineGrainedURL(webURL: URL) -> URL { webURL.appending(path: "settings/personal-access-tokens/new") }
    nonisolated static func newClassicURL(webURL: URL) -> URL {
        var components = URLComponents(url: webURL.appending(path: "settings/tokens/new"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "scopes", value: "repo"), URLQueryItem(name: "description", value: "Runnir")]
        return components?.url ?? webURL
    }
    nonisolated static func fineGrainedSettingsURL(webURL: URL) -> URL { webURL.appending(path: "settings/personal-access-tokens") }
    nonisolated static func classicSettingsURL(webURL: URL) -> URL { webURL.appending(path: "settings/tokens") }

    nonisolated static let newFineGrainedURL = newFineGrainedURL(webURL: dotComWebURL)
    nonisolated static let newClassicURL = newClassicURL(webURL: dotComWebURL)
    nonisolated static let fineGrainedSettingsURL = fineGrainedSettingsURL(webURL: dotComWebURL)
    nonisolated static let classicSettingsURL = classicSettingsURL(webURL: dotComWebURL)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(emphasized ? "This token does not have what Runnir needs. Create one that does:" : "A token Runnir can use:")
                .font(.system(size: 12, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text("Fine-grained token (recommended)").font(.system(size: 12, weight: .medium))
                Text("Resource owner: your account or the organization. Repository access: the repositories you use in Runnir, or all. Repository permissions: Actions — Read and write; Contents — Read-only. GitHub adds Metadata — Read-only."
                     + (enterprise ? " Fine-grained tokens need GitHub Enterprise Server 3.10 or later; use a classic token on older servers." : ""))
                    .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground).fixedSize(horizontal: false, vertical: true)
                Button("New Fine-Grained Token...") { openURL(Self.newFineGrainedURL(webURL: webURL)) }.buttonStyle(.link).pointerStyle(.link).font(.system(size: 11))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Classic token").font(.system(size: 12, weight: .medium))
                Text("Scope: repo. For an organization that uses single sign-on, authorize the token for it afterwards (Configure SSO).")
                    .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground).fixedSize(horizontal: false, vertical: true)
                Button("New Classic Token...") { openURL(Self.newClassicURL(webURL: webURL)) }.buttonStyle(.link).pointerStyle(.link).font(.system(size: 11))
            }
        }
    }
}

/// The account row at the bottom of a workspace sidebar.
struct GitHubAccountRow: View {
    let session: GitHubSession
    @State private var showingConnect = false

    var body: some View {
        Button { showingConnect = true } label: {
            // The icon column matches the sidebar items' (16 points, 10 apart).
            HStack(spacing: 10) {
                SidebarIcon(symbol: symbol).foregroundStyle(RunnirTheme.secondaryForeground)
                VStack(alignment: .leading, spacing: 1) {
                    Text("GitHub").font(.system(size: 12))
                    Text(status).font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.hit)
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
    /// The kind of token the Core holds, for what to manage where.
    var credentialKind: CoreGitHubCredentialKind? = nil
    @Environment(\.openURL) private var openURL
    @State private var showingConnect = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch session.connection {
            case .signedIn(let user):
                if let credentialKind, credentialKind.isPersonal {
                    Text("Signed in as \(user.login) with a \(GitHubTokenCheckView.kindName(credentialKind).lowercased())")
                    HStack {
                        Button("Sign Out") { Task { await session.signOut() } }.handPointer()
                        Button("Token Settings on GitHub...") { openURL(GitHubAccessHelp.tokenSettingsURL(credentialKind)) }.handPointer()
                    }
                    Text("Runnir sees the repositories this token reaches, with the permissions it has. Change them, or revoke the token, in its settings on GitHub.")
                        .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                    Text("Sign Out removes the token from this Mac's Keychain; the token itself stays valid on GitHub until it expires or you revoke it.")
                        .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                } else {
                    Text("Signed in as \(user.login)")
                    // Where the row is too narrow, the three buttons wrap
                    // rather than cut the last title short.
                    ViewThatFits(in: .horizontal) {
                        HStack { signOut; manageAccess; manageAuthorization }
                        VStack(alignment: .leading) {
                            HStack { signOut; manageAccess }
                            manageAuthorization
                        }
                    }
                    Text("Runnir sees only repositories where the Runnir Desktop app is installed. Manage Repository Access adds or removes them on GitHub.")
                        .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                    Text("Sign Out removes the authorization from this Mac's Keychain. To revoke Runnir's access entirely, use Manage Authorization on GitHub.")
                        .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                }
            case .offline:
                Text("Signed in; GitHub is unreachable right now.")
                Button("Sign Out") { Task { await session.signOut() } }.handPointer()
            case .restoring:
                // The Keychain may be asking whether Runnir can read the sign-in.
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking the saved sign-in...").foregroundStyle(RunnirTheme.secondaryForeground)
                }
            default:
                Text("Not connected").foregroundStyle(RunnirTheme.secondaryForeground)
                Button("Connect GitHub...") { showingConnect = true }.handPointer()
            }
        }
        .sheet(isPresented: $showingConnect) { GitHubConnectView(session: session) }
    }

    private var signOut: some View {
        Button("Sign Out") { Task { await session.signOut() } }.handPointer()
    }

    private var manageAccess: some View {
        Button("Manage Repository Access...") { openURL(GitHubAppConfiguration.runnirDesktop.installationURL) }.handPointer()
    }

    private var manageAuthorization: some View {
        Button("Manage Authorization on GitHub...") { openURL(GitHubSession.authorizationsURL) }.handPointer()
    }
}
