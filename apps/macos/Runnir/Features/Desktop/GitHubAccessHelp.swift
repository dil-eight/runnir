import SwiftUI

/// What stands between the user and GitHub, and the one step that fixes it.
/// Connecting is offered only when there is no sign-in; a sign-in GitHub no
/// longer accepts asks to sign in again; a repository the app does not reach
/// asks to give it access; permissions an installation has not accepted ask
/// an owner to review them; the user's own missing rights are explained,
/// since nothing in Runnir fixes them. Lists show it as a banner, sections as
/// a note, and actions as an alert (`githubAccessAlert`).
struct GitHubAccessHelp: Equatable, Identifiable {
    /// What the user was doing, for the wording and for what a missing
    /// permission blocks.
    enum Purpose: Equatable {
        /// See workflows, runs, jobs or logs.
        case read
        /// Start a workflow.
        case run
        /// Cancel or re-run a run.
        case change

        var phrase: String {
            switch self {
            case .read: "see workflows and runs"
            case .run: "start workflows"
            case .change: "cancel or re-run runs"
            }
        }
    }

    enum Fix: Equatable {
        /// No sign-in: connect GitHub.
        case connect
        /// GitHub refused the saved sign-in: sign in again.
        case signInAgain
        /// The app does not reach the repository: install it there or choose it.
        case giveAccess(URL)
        /// An installation waits for an owner: review and accept permissions,
        /// or resume a suspended installation.
        case reviewPermissions(URL)
        /// A personal token lacks the repository or a permission: change it,
        /// or create one that has them.
        case editToken(URL)
        /// The user's own rights on the repository; nothing here fixes them.
        case askForWriteAccess
        case retry
        case none

        var buttonTitle: String? {
            switch self {
            case .connect: "Connect GitHub..."
            case .signInAgain: "Sign In Again..."
            case .giveAccess: "Give Runnir Access..."
            case .reviewPermissions: "Review on GitHub..."
            case .editToken: "Edit Token on GitHub..."
            case .retry: "Try Again"
            case .askForWriteAccess, .none: nil
            }
        }
    }

    let title: String
    let message: String
    let fix: Fix
    var id: String { title + "|" + message }

    static let installationURL = GitHubAppConfiguration.runnirDesktop.installationURL

    /// Help for an access outcome GitHub reported; nil when it is `.ok`.
    /// `details` (the repository as the Core read it) tells a permission an
    /// owner has not accepted from the user's own missing write access.
    static func forAccess(_ access: CoreGitHubAccess, repository: String?, purpose: Purpose,
                          details: CoreGitHubRepository? = nil, credential: CoreGitHubCredentialKind? = nil) -> GitHubAccessHelp? {
        let name = repository.flatMap { $0.isEmpty ? nil : $0 } ?? "this repository"
        if let credential, credential.isPersonal,
           let help = forPersonalToken(access, repository: name, purpose: purpose, details: details, credential: credential) {
            return help
        }
        switch access {
        case .ok:
            return nil
        case .noRemote:
            return GitHubAccessHelp(title: "No GitHub remote",
                                    message: "This working tree has no origin on github.com, so it has no workflows or runs on GitHub.",
                                    fix: .none)
        case .signedOut:
            return GitHubAccessHelp(title: "Connect GitHub", message: "Connect GitHub to \(purpose.phrase) for \(name).", fix: .connect)
        case .tokenRejected:
            return GitHubAccessHelp(title: "Sign in to GitHub again",
                                    message: "GitHub no longer accepts the saved sign-in, for example because it was revoked. Sign in again to \(purpose.phrase); nothing else needs to change.",
                                    fix: .signInAgain)
        case .notVisible:
            return GitHubAccessHelp(title: "Runnir can't see \(name)",
                                    message: "The Runnir Desktop app is not installed on \(name), or the repository was not chosen when it was installed. Give Runnir access to it on GitHub, then try again.",
                                    fix: .giveAccess(installationURL))
        case .permissionMissing:
            if let blocker = installationBlocker(details?.installation, purpose: purpose, refused: true) { return blocker }
            if purpose != .read, details?.canPush == false { return noWriteAccess(name, purpose: purpose) }
            return GitHubAccessHelp(title: "GitHub did not allow this",
                                    message: "Runnir Desktop or your GitHub account lacks a permission to \(purpose.phrase) in \(name). Check the app's permissions on GitHub, or ask a maintainer of \(name) for access.",
                                    fix: .reviewPermissions(details?.installation?.htmlURL ?? installationURL))
        case .rateLimited(let until):
            let when = until.map { " after \($0.formatted(date: .omitted, time: .shortened))" } ?? " in a moment"
            let shown = purpose == .read ? "What is shown is from the last read. " : "Nothing was sent. "
            return GitHubAccessHelp(title: "GitHub is limiting requests", message: "\(shown)Try again\(when).", fix: .retry)
        case .unavailable:
            let shown = purpose == .read ? "What is shown is from the last read. " : "Nothing was sent. "
            return GitHubAccessHelp(title: "GitHub could not be reached", message: "\(shown)Check the connection and try again.", fix: .retry)
        }
    }

    /// With a personal token, GitHub's refusals are about the token: its
    /// repositories, permissions or scopes, changed in its settings.
    private static func forPersonalToken(_ access: CoreGitHubAccess, repository name: String, purpose: Purpose,
                                         details: CoreGitHubRepository?, credential: CoreGitHubCredentialKind) -> GitHubAccessHelp? {
        let settings = tokenSettingsURL(credential)
        switch access {
        case .tokenRejected:
            return GitHubAccessHelp(title: "Sign in to GitHub again",
                                    message: "GitHub no longer accepts the token, for example because it expired or was revoked. Sign in again with a new token or with the Runnir Desktop app.",
                                    fix: .signInAgain)
        case .notVisible:
            let message = credential == .fineGrained
                ? "Add \(name) to the token's repository access on GitHub, or create a token that includes it."
                : "For private repositories the token needs the repo scope; an organization that uses single sign-on also needs the token authorized for it."
            return GitHubAccessHelp(title: "This token can't see \(name)", message: message, fix: .editToken(settings))
        case .permissionMissing:
            if purpose != .read, details?.canPush == false { return noWriteAccess(name, purpose: purpose) }
            let message = credential == .fineGrained
                ? "To \(purpose.phrase) in \(name), a fine-grained token needs Actions: Read and write and Contents: Read-only for it."
                : "To \(purpose.phrase) in \(name), the token needs the repo scope."
            return GitHubAccessHelp(title: "The token lacks a permission", message: message, fix: .editToken(settings))
        default:
            return nil
        }
    }

    static func tokenSettingsURL(_ credential: CoreGitHubCredentialKind, webURL: URL = GitHubTokenAdvice.dotComWebURL) -> URL {
        credential == .fineGrained ? GitHubTokenAdvice.fineGrainedSettingsURL(webURL: webURL) : GitHubTokenAdvice.classicSettingsURL(webURL: webURL)
    }

    /// What is known to block an action before trying it: a suspended
    /// installation, permissions it needs that an owner has not accepted, or
    /// no write access for the user.
    static func blocker(for purpose: Purpose, repository: String, details: CoreGitHubRepository?) -> GitHubAccessHelp? {
        guard let details, details.access == .ok else { return nil }
        if let blocker = installationBlocker(details.installation, purpose: purpose, refused: false) { return blocker }
        if purpose != .read, !details.canPush { return noWriteAccess(repository, purpose: purpose) }
        return nil
    }

    /// Same for a repository from the account list, which carries the push
    /// right and the installation it came from.
    static func blocker(for purpose: Purpose, repository: CoreGitHubAccountRepository,
                        installation: CoreGitHubInstallation?) -> GitHubAccessHelp? {
        if let blocker = installationBlocker(installation, purpose: purpose, refused: false) { return blocker }
        if purpose != .read, !repository.canPush { return noWriteAccess(repository.fullName, purpose: purpose) }
        return nil
    }

    /// An installation that needs an owner: suspended, or with permissions
    /// waiting to be accepted. Before trying, only what the purpose needs
    /// counts (starting, cancelling and re-running need Actions write); once
    /// GitHub refused (`refused`), any permission still waiting is the
    /// likely cause.
    static func installationBlocker(_ installation: CoreGitHubInstallation?, purpose: Purpose, refused: Bool) -> GitHubAccessHelp? {
        guard let installation else { return nil }
        if installation.suspended {
            return GitHubAccessHelp(title: "Runnir Desktop is suspended on \(installation.account)",
                                    message: "Runnir can't reach \(installation.account)'s repositories until an owner of \(installation.account) resumes the app on GitHub.",
                                    fix: .reviewPermissions(installation.htmlURL ?? installationURL))
        }
        guard !installation.missingPermissions.isEmpty else { return nil }
        let needed = refused || (purpose != .read && installation.missingPermissions.contains { $0.hasPrefix("actions") })
        return needed ? pendingPermissions(installation, purpose: purpose) : nil
    }

    /// The app asks for permissions an owner of the account has not accepted.
    static func pendingPermissions(_ installation: CoreGitHubInstallation, purpose: Purpose? = nil) -> GitHubAccessHelp {
        let list = ListFormatter.localizedString(byJoining: installation.missingPermissions.map(Self.permissionName))
        let blocked = purpose.map { " Until then Runnir can't \($0.phrase) there." } ?? ""
        let who = installation.accountType == "User"
            ? "\(installation.account) reviews and accepts them on GitHub."
            : "An owner of \(installation.account) reviews and accepts them on GitHub; if that is not you, ask one."
        return GitHubAccessHelp(title: "Runnir Desktop needs new permissions on \(installation.account)",
                                message: "The app now asks for \(list). \(who)\(blocked)",
                                fix: .reviewPermissions(installation.htmlURL ?? installationURL))
    }

    static func noWriteAccess(_ repository: String, purpose: Purpose) -> GitHubAccessHelp {
        GitHubAccessHelp(title: "You can't \(purpose.phrase) in \(repository)",
                         message: "Your GitHub account can read \(repository) but not write to it, and GitHub allows only people with write access to \(purpose.phrase). Ask a maintainer of \(repository) for write access.",
                         fix: .askForWriteAccess)
    }

    /// "actions: write" reads as "Actions (write)".
    static func permissionName(_ permission: String) -> String {
        let parts = permission.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return permission }
        return "\(parts[0].capitalized) (\(parts[1]))"
    }
}

/// Where a help is shown: a banner over a list, or a note in a section.
enum GitHubAccessNoticeStyle { case banner, note }

/// A help with its button, as a banner over a list or a note in a section.
struct GitHubAccessNotice: View {
    let help: GitHubAccessHelp
    var style: GitHubAccessNoticeStyle = .note
    let github: GitHubSession?
    var retry: () -> Void = {}
    @Environment(\.openURL) private var openURL
    @State private var showingConnect = false

    var body: some View {
        content
            .sheet(isPresented: $showingConnect) { if let github { GitHubConnectView(session: github) } }
    }

    @ViewBuilder private var content: some View {
        switch style {
        case .banner:
            // The button sits beside the text where there is room, and
            // under it in a narrow list such as Runs.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: symbol).foregroundStyle(tint).padding(.top, 1)
                    text.frame(minWidth: 260, alignment: .leading)
                    Spacer(minLength: 8)
                    button
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: symbol).foregroundStyle(tint).padding(.top, 1)
                    VStack(alignment: .leading, spacing: 8) {
                        text
                        button
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(DesignButtonStyle())
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityElement(children: .contain)
        case .note:
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: symbol).foregroundStyle(tint).padding(.top, 1)
                    text
                }
                HStack(spacing: 8) { button }.buttonStyle(DesignButtonStyle())
            }
        }
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(help.title).font(.system(size: 12, weight: .semibold))
            Text(help.message).font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var button: some View {
        if let title = help.fix.buttonTitle {
            Button(title) { perform(help.fix) }
        }
    }

    private func perform(_ fix: GitHubAccessHelp.Fix) {
        switch fix {
        case .connect, .signInAgain: showingConnect = true
        case .giveAccess(let url), .reviewPermissions(let url), .editToken(let url): openURL(url)
        case .retry: retry()
        case .askForWriteAccess, .none: break
        }
    }

    private var symbol: String {
        switch help.fix {
        case .connect, .signInAgain: "person.crop.circle.badge.exclamationmark"
        case .giveAccess, .reviewPermissions, .editToken: "key"
        case .askForWriteAccess: "lock"
        case .retry: "arrow.clockwise.circle"
        case .none: "info.circle"
        }
    }

    private var tint: Color {
        switch help.fix {
        case .none, .askForWriteAccess: RunnirTheme.secondaryForeground
        default: RunnirTheme.warning
        }
    }
}

/// An action GitHub refused, or one known to be refused, as an alert with
/// the step that fixes it.
struct GitHubAccessAlert: ViewModifier {
    @Binding var help: GitHubAccessHelp?
    let github: GitHubSession?
    @Environment(\.openURL) private var openURL
    @State private var showingConnect = false

    func body(content: Content) -> some View {
        content
            .alert(help?.title ?? "", isPresented: Binding(get: { help != nil }, set: { if !$0 { help = nil } }), presenting: help) { help in
                if let title = help.fix.buttonTitle, help.fix != .retry {
                    Button(title) { perform(help.fix) }
                    Button("Cancel", role: .cancel) {}
                } else {
                    Button("OK", role: .cancel) {}
                }
            } message: { help in
                Text(help.message)
            }
            .sheet(isPresented: $showingConnect) { if let github { GitHubConnectView(session: github) } }
    }

    private func perform(_ fix: GitHubAccessHelp.Fix) {
        switch fix {
        case .connect, .signInAgain: showingConnect = true
        case .giveAccess(let url), .reviewPermissions(let url), .editToken(let url): openURL(url)
        case .retry, .askForWriteAccess, .none: break
        }
    }
}

extension View {
    /// Shows `help` as an alert while it is set; its button opens GitHub or
    /// the sign-in sheet.
    func githubAccessAlert(_ help: Binding<GitHubAccessHelp?>, github: GitHubSession?) -> some View {
        modifier(GitHubAccessAlert(help: help, github: github))
    }
}

extension GitHubSession {
    /// Why there is no sign-in: `.tokenRejected` when GitHub stopped
    /// accepting the saved one (sign in again), otherwise `.signedOut`.
    var signedOutAccess: CoreGitHubAccess {
        if case .signedOut(let problem) = connection, problem == .sessionExpired { return .tokenRejected }
        return .signedOut
    }
}

extension GitHubAccessHelp {
    /// Access outcomes the user can fix, worth an alert after an action.
    static func needsExplaining(_ access: CoreGitHubAccess) -> Bool {
        switch access {
        case .signedOut, .tokenRejected, .notVisible, .permissionMissing: true
        default: false
        }
    }
}
