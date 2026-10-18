import Foundation
import Observation

/// Why signing in or restoring the account stopped; each case has text the
/// user can act on.
enum GitHubSignInProblem: Equatable, Sendable {
    case denied
    case expired
    case notConfigured
    case network
    case rateLimited
    case keychain
    case sessionExpired
    case unexpected

    var message: String {
        switch self {
        case .denied: "Authorization was declined on GitHub."
        case .expired: "The code expired before it was entered. Start again to get a new one."
        case .notConfigured: "GitHub sign-in is not available for this build of Runnir."
        case .network: "GitHub could not be reached. Check the connection and try again."
        case .rateLimited: "GitHub is limiting requests right now. Wait a moment and try again."
        case .keychain: "The sign-in could not be saved to the Keychain. Allow Runnir to use the Keychain and try again."
        case .sessionExpired: "Your GitHub authorization is no longer valid. Sign in again."
        case .unexpected: "GitHub returned an unexpected answer. Try again."
        }
    }
}

/// Whether the signed-in user's token can see a repository.
enum GitHubRepositoryAccess: Equatable, Sendable {
    case signedOut
    case accessible(Repository)
    /// GitHub answers "not found": the Runnir Desktop app is not installed on
    /// the repository, or the user has no access to it.
    case notVisible
    case failed(String)
}

enum GitHubConnection: Equatable, Sendable {
    /// Restoring a saved sign-in at launch.
    case restoring
    case signedOut(GitHubSignInProblem?)
    case requestingCode
    /// The user enters `authorization.userCode` at `authorization.verificationURL`.
    case waiting(DeviceAuthorization, slowerPolling: Bool)
    case signedIn(GitHubUser)
    /// A saved sign-in exists but GitHub could not be reached to confirm it.
    case offline
}

/// The app-wide GitHub account: restores a saved token at launch, signs in
/// with the Device Flow, and signs out. Tokens live only in the Keychain and
/// never appear in state, logs or errors.
@MainActor
@Observable
final class GitHubSession {
    private(set) var connection: GitHubConnection = .restoring

    @ObservationIgnored private let deviceFlow: any DeviceFlowServicing
    @ObservationIgnored private let credentials: any CredentialStoring
    @ObservationIgnored private let api: any GitHubService
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let clock = ContinuousClock()
    @ObservationIgnored private var signInTask: Task<Void, Never>?

    /// Where a user revokes Runnir's authorization at GitHub.
    static let authorizationsURL = URL(string: "https://github.com/settings/apps/authorizations")!
    static let maxConsecutiveNetworkFailures = 3

    init(deviceFlow: any DeviceFlowServicing,
         credentials: any CredentialStoring,
         api: any GitHubService,
         openURL: @escaping @MainActor (URL) -> Void,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.deviceFlow = deviceFlow
        self.credentials = credentials
        self.api = api
        self.openURL = openURL
        self.sleep = sleep
    }

    var user: GitHubUser? {
        if case .signedIn(let user) = connection { return user }
        return nil
    }

    // MARK: Restore

    /// Confirms a saved token with GitHub. A rejected token is deleted; a
    /// network failure keeps it and reports `.offline`.
    func restore() async {
        connection = .restoring
        let token: String?
        do { token = try await credentials.token() } catch {
            connection = .signedOut(.keychain)
            return
        }
        guard token != nil else {
            connection = .signedOut(nil)
            return
        }
        await confirmUser(onRejected: .sessionExpired)
    }

    // MARK: Sign in

    /// Starts the Device Flow: requests a code, opens the verification page and
    /// polls until the user approves, declines or the code expires.
    func signIn() {
        guard signInTask == nil else { return }
        connection = .requestingCode
        signInTask = Task { [weak self] in
            await self?.runSignIn()
            self?.signInTask = nil
        }
    }

    /// Stops waiting for the browser. Nothing is saved.
    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        connection = .signedOut(nil)
    }

    /// Opens the verification page again, for a closed browser tab.
    func reopenVerificationPage() {
        if case .waiting(let authorization, _) = connection { openURL(authorization.verificationURL) }
    }

    private func runSignIn() async {
        let authorization: DeviceAuthorization
        do {
            authorization = try await deviceFlow.requestAuthorization()
        } catch {
            if !Task.isCancelled { connection = .signedOut(Self.problem(for: error)) }
            return
        }
        guard !Task.isCancelled else { return }
        connection = .waiting(authorization, slowerPolling: false)
        openURL(authorization.verificationURL)

        let deadline = clock.now + authorization.expiresIn
        var interval = authorization.interval
        var networkFailures = 0
        while !Task.isCancelled {
            do { try await sleep(interval) } catch { return }
            guard !Task.isCancelled else { return }
            if clock.now >= deadline {
                connection = .signedOut(.expired)
                return
            }
            let answer: DeviceTokenPoll
            do {
                answer = try await deviceFlow.poll(deviceCode: authorization.deviceCode)
                networkFailures = 0
            } catch DeviceFlowError.network {
                // A dropped request is retried at the next interval.
                networkFailures += 1
                if networkFailures >= Self.maxConsecutiveNetworkFailures {
                    connection = .signedOut(.network)
                    return
                }
                continue
            } catch {
                if !Task.isCancelled { connection = .signedOut(Self.problem(for: error)) }
                return
            }
            guard !Task.isCancelled else { return }
            switch answer {
            case .pending:
                continue
            case .slowDown(let requested):
                // RFC 8628: add 5 seconds unless GitHub names the new interval.
                interval = max(requested ?? interval + .seconds(5), interval + .seconds(1))
                connection = .waiting(authorization, slowerPolling: true)
            case .expired:
                connection = .signedOut(.expired)
                return
            case .denied:
                connection = .signedOut(.denied)
                return
            case .authorized(let token):
                await finishSignIn(token: token)
                return
            }
        }
    }

    private func finishSignIn(token: String) async {
        do {
            try await credentials.saveToken(token)
        } catch {
            connection = .signedOut(.keychain)
            return
        }
        await confirmUser(onRejected: .unexpected)
    }

    private func confirmUser(onRejected problem: GitHubSignInProblem) async {
        do {
            connection = .signedIn(try await api.getCurrentUser())
        } catch GitHubAPIError.authenticationFailed {
            try? await credentials.removeToken()
            connection = .signedOut(problem)
        } catch GitHubAPIError.networkUnavailable {
            connection = .offline
        } catch GitHubAPIError.rateLimited {
            connection = .offline
        } catch {
            connection = .signedOut(.unexpected)
        }
    }

    // MARK: Repository access

    /// Checks whether Runnir can see `fullName` ("owner/name") with the current
    /// sign-in. A token GitHub rejects signs the user out.
    func access(to fullName: String) async -> GitHubRepositoryAccess {
        guard user != nil else { return .signedOut }
        let parts = fullName.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return .notVisible }
        do {
            return .accessible(try await api.repository(owner: String(parts[0]), name: String(parts[1])))
        } catch GitHubAPIError.notFound {
            return .notVisible
        } catch GitHubAPIError.authorizationFailed {
            return .notVisible
        } catch GitHubAPIError.authenticationFailed {
            try? await credentials.removeToken()
            connection = .signedOut(.sessionExpired)
            return .signedOut
        } catch GitHubAPIError.rateLimited {
            return .failed(GitHubSignInProblem.rateLimited.message)
        } catch GitHubAPIError.networkUnavailable {
            return .failed(GitHubSignInProblem.network.message)
        } catch {
            return .failed(GitHubSignInProblem.unexpected.message)
        }
    }

    // MARK: Sign out

    /// Deletes the local token. Authorization at GitHub stays until the user
    /// revokes it at `authorizationsURL`: revoking from the app would need a
    /// client secret, which the app does not have.
    func signOut() async {
        cancelSignInIfRunning()
        do {
            try await credentials.removeToken()
            connection = .signedOut(nil)
        } catch {
            connection = .signedOut(.keychain)
        }
    }

    private func cancelSignInIfRunning() {
        signInTask?.cancel()
        signInTask = nil
    }

    static func problem(for error: any Error) -> GitHubSignInProblem {
        switch error as? DeviceFlowError {
        case .notConfigured: .notConfigured
        case .network: .network
        case .rateLimited: .rateLimited
        default: .unexpected
        }
    }
}
