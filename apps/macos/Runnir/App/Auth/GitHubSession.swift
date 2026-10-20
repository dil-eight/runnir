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
    /// Identifies the current sign-in, so a cancelled one that finishes late
    /// cannot clear the handle of the sign-in that replaced it.
    @ObservationIgnored private var signInID: UUID?
    @ObservationIgnored private let offlineRetryDelays: [Duration]
    @ObservationIgnored private var offlineRetry: Task<Void, Never>?
    /// Called whenever the usable token appears or goes away.
    @ObservationIgnored var onCredentialChange: (@MainActor () -> Void)?

    /// Where a user revokes Runnir's authorization at GitHub.
    static let authorizationsURL = URL(string: "https://github.com/settings/apps/authorizations")!
    static let maxConsecutiveNetworkFailures = 3

    init(deviceFlow: any DeviceFlowServicing,
         credentials: any CredentialStoring,
         api: any GitHubService,
         openURL: @escaping @MainActor (URL) -> Void,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         offlineRetryDelays: [Duration] = [.seconds(30), .seconds(60), .seconds(120), .seconds(300)]) {
        self.deviceFlow = deviceFlow
        self.credentials = credentials
        self.api = api
        self.openURL = openURL
        self.sleep = sleep
        self.offlineRetryDelays = offlineRetryDelays
    }

    var user: GitHubUser? {
        if case .signedIn(let user) = connection { return user }
        return nil
    }

    /// The token, only while signed in and confirmed by GitHub.
    func currentToken() async -> String? {
        guard user != nil else { return nil }
        return try? await credentials.token()
    }

    // MARK: Restore

    /// Confirms a saved token with GitHub. A rejected token is deleted; a
    /// network failure keeps it and reports `.offline`.
    func restore() async {
        stopOfflineRetry()
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
        stopOfflineRetry()
        connection = .requestingCode
        let id = UUID()
        signInID = id
        signInTask = Task { [weak self] in
            await self?.runSignIn()
            guard let self, self.signInID == id else { return }
            self.signInTask = nil
            self.signInID = nil
        }
    }

    /// Stops waiting for the browser. Nothing is saved.
    func cancelSignIn() {
        cancelSignInIfRunning()
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

    /// While `.offline`, asks GitHub again after each delay in
    /// `offlineRetryDelays` (the last one repeats) until it answers, so a
    /// launch without network recovers by itself once it is back.
    private func scheduleOfflineRetry() {
        offlineRetry?.cancel()
        let delays = offlineRetryDelays
        guard !delays.isEmpty else { return }
        let sleep = sleep
        offlineRetry = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                do { try await sleep(delays[min(attempt, delays.count - 1)]) } catch { return }
                guard let self, !Task.isCancelled, self.connection == .offline else { return }
                attempt += 1
                await self.confirmUser(onRejected: .sessionExpired, retryWhenOffline: false)
                guard self.connection == .offline else { return }
            }
        }
    }

    private func stopOfflineRetry() {
        offlineRetry?.cancel()
        offlineRetry = nil
    }

    private func confirmUser(onRejected problem: GitHubSignInProblem, retryWhenOffline: Bool = true) async {
        do {
            connection = .signedIn(try await api.getCurrentUser())
            onCredentialChange?()
        } catch GitHubAPIError.authenticationFailed {
            try? await credentials.removeToken()
            connection = .signedOut(problem)
            onCredentialChange?()
        } catch GitHubAPIError.networkUnavailable, GitHubAPIError.rateLimited,
                GitHubAPIError.serverError, GitHubAPIError.invalidResponse {
            // GitHub is unreachable or failing for now; the saved sign-in stays.
            connection = .offline
            if retryWhenOffline { scheduleOfflineRetry() }
        } catch {
            connection = .signedOut(.unexpected)
        }
    }

    /// GitHub refused the token on some request: forget it and ask the user
    /// to sign in again.
    func tokenWasRejected() async {
        guard user != nil else { return }
        stopOfflineRetry()
        try? await credentials.removeToken()
        connection = .signedOut(.sessionExpired)
        onCredentialChange?()
    }

    // MARK: Sign out

    /// Deletes the local token. Authorization at GitHub stays until the user
    /// revokes it at `authorizationsURL`: revoking from the app would need a
    /// client secret, which the app does not have.
    func signOut() async {
        cancelSignInIfRunning()
        stopOfflineRetry()
        do {
            try await credentials.removeToken()
            connection = .signedOut(nil)
        } catch {
            connection = .signedOut(.keychain)
        }
        onCredentialChange?()
    }

    private func cancelSignInIfRunning() {
        signInTask?.cancel()
        signInTask = nil
        signInID = nil
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
