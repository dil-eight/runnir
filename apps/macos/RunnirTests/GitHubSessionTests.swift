import Foundation
import Testing
@testable import Runnir

private actor ScriptedDeviceFlow: DeviceFlowServicing {
    var authorization = DeviceAuthorization(deviceCode: "dc", userCode: "ABCD-1234",
                                            verificationURL: URL(string: "https://github.com/login/device")!,
                                            expiresIn: .seconds(900), interval: .seconds(5))
    var requestError: DeviceFlowError?
    var answers: [Result<DeviceTokenPoll, DeviceFlowError>] = []
    var polls = 0
    var requests = 0

    func set(answers: [Result<DeviceTokenPoll, DeviceFlowError>]) { self.answers = answers }
    func set(requestError: DeviceFlowError?) { self.requestError = requestError }
    func set(authorization: DeviceAuthorization) { self.authorization = authorization }

    func requestAuthorization() async throws -> DeviceAuthorization {
        requests += 1
        if let requestError { throw requestError }
        return authorization
    }

    func poll(deviceCode: String) async throws -> DeviceTokenPoll {
        polls += 1
        guard !answers.isEmpty else { return .pending }
        return try answers.removeFirst().get()
    }
}

private actor FakeGitHubAPI: GitHubService {
    var userResult: Result<GitHubUser, GitHubAPIError> = .success(GitHubUser(id: 1, login: "octocat", name: nil))
    func set(_ result: Result<GitHubUser, GitHubAPIError>) { userResult = result }
    func getCurrentUser() async throws -> GitHubUser { try userResult.get() }
    func listRepositories() async throws -> [Repository] { [] }
    var repositoryResult: Result<Repository, GitHubAPIError> = .failure(.notFound)
    func set(repository: Result<Repository, GitHubAPIError>) { repositoryResult = repository }
    func repository(owner: String, name: String) async throws -> Repository { try repositoryResult.get() }
    func listWorkflows(owner: String, repository: String) async throws -> [Workflow] { [] }
}

private actor FailingCredentialStore: CredentialStoring {
    func token() async throws -> String? { throw KeychainError.unhandledStatus(-25293) }
    func saveToken(_ token: String) async throws { throw KeychainError.unhandledStatus(-25293) }
    func removeToken() async throws { throw KeychainError.unhandledStatus(-25293) }
}

/// Records requested sleeps and returns at once.
private final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Duration] = []
    var sleeps: [Duration] { lock.withLock { recorded } }
    func sleep(_ duration: Duration) async throws {
        lock.withLock { recorded.append(duration) }
        await Task.yield()
    }
}

@MainActor
private struct Rig {
    let flow = ScriptedDeviceFlow()
    let api = FakeGitHubAPI()
    let credentials: any CredentialStoring
    let sleeper = SleepRecorder()
    let opened = OpenedURLs()
    let session: GitHubSession

    init(credentials: any CredentialStoring = InMemoryCredentialStore(), offlineRetry: [Duration] = []) {
        self.credentials = credentials
        let opened = opened
        let sleeper = sleeper
        session = GitHubSession(deviceFlow: flow, credentials: credentials, api: api,
                                openURL: { opened.urls.append($0) },
                                sleep: { try await sleeper.sleep($0) },
                                offlineRetryDelays: offlineRetry)
    }
}

@MainActor
private final class OpenedURLs { var urls: [URL] = [] }

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct GitHubSessionTests {
    @Test
    func signInStoresTheTokenOnlyInTheCredentialStoreAndShowsTheUser() async throws {
        let rig = Rig()
        await rig.flow.set(answers: [.success(.pending), .success(.authorized(token: "ghu_secret"))])
        rig.session.signIn()

        #expect(await eventually { rig.session.user?.login == "octocat" })
        #expect(try await rig.credentials.token() == "ghu_secret")
        #expect(rig.opened.urls == [URL(string: "https://github.com/login/device")!])
        #expect(rig.sleeper.sleeps == [.seconds(5), .seconds(5)])
        #expect(!String(describing: rig.session.connection).contains("ghu_secret"))
    }

    @Test
    func showsTheCodeWhileWaiting() async throws {
        let rig = Rig()
        await rig.flow.set(answers: Array(repeating: .success(.pending), count: 50))
        rig.session.signIn()
        #expect(await eventually {
            if case .waiting(let authorization, _) = rig.session.connection { authorization.userCode == "ABCD-1234" } else { false }
        })
        rig.session.cancelSignIn()
        #expect(rig.session.connection == .signedOut(nil))
        #expect(try await rig.credentials.token() == nil)
    }

    @Test
    func slowDownIncreasesTheIntervalAndIsShown() async throws {
        let rig = Rig()
        await rig.flow.set(answers: [.success(.slowDown(interval: nil)), .success(.slowDown(interval: .seconds(20))),
                                     .success(.authorized(token: "t"))])
        rig.session.signIn()
        #expect(await eventually { rig.session.user != nil })
        #expect(rig.sleeper.sleeps == [.seconds(5), .seconds(10), .seconds(20)])
    }

    @Test
    func declinedAndExpiredCodesEndWithAnActionableMessage() async throws {
        for (answer, problem) in [(DeviceTokenPoll.denied, GitHubSignInProblem.denied), (.expired, .expired)] {
            let rig = Rig()
            await rig.flow.set(answers: [.success(answer)])
            rig.session.signIn()
            #expect(await eventually { rig.session.connection == .signedOut(problem) })
            #expect(!problem.message.isEmpty)
        }
    }

    @Test
    func theCodeExpiresLocallyEvenIfGitHubKeepsSayingPending() async throws {
        let rig = Rig()
        await rig.flow.set(authorization: DeviceAuthorization(deviceCode: "dc", userCode: "C", verificationURL: URL(string: "https://github.com/login/device")!,
                                                              expiresIn: .zero, interval: .seconds(5)))
        rig.session.signIn()
        #expect(await eventually { rig.session.connection == .signedOut(.expired) })
        #expect(await rig.flow.polls == 0)
    }

    @Test
    func briefNetworkDropsAreRetriedButRepeatedOnesStop() async throws {
        let rig = Rig()
        await rig.flow.set(answers: [.failure(.network), .failure(.network), .success(.authorized(token: "t"))])
        rig.session.signIn()
        #expect(await eventually { rig.session.user != nil })

        let failing = Rig()
        await failing.flow.set(answers: Array(repeating: .failure(.network), count: 5))
        failing.session.signIn()
        #expect(await eventually { failing.session.connection == .signedOut(.network) })
        #expect(await failing.flow.polls == GitHubSession.maxConsecutiveNetworkFailures)
    }

    @Test
    func aDisabledDeviceFlowIsReportedAsNotConfigured() async throws {
        let rig = Rig()
        await rig.flow.set(requestError: .notConfigured)
        rig.session.signIn()
        #expect(await eventually { rig.session.connection == .signedOut(.notConfigured) })
    }

    @Test
    func aKeychainFailureDoesNotLeaveYouSignedIn() async throws {
        let rig = Rig(credentials: FailingCredentialStore())
        await rig.flow.set(answers: [.success(.authorized(token: "t"))])
        rig.session.signIn()
        #expect(await eventually { rig.session.connection == .signedOut(.keychain) })
    }

    @Test
    func anOfflineLaunchRecoversByItselfWhenGitHubAnswersAgain() async throws {
        let rig = Rig(credentials: InMemoryCredentialStore(token: "t"), offlineRetry: [.seconds(30), .seconds(60)])
        var changes = 0
        rig.session.onCredentialChange = { changes += 1 }
        await rig.api.set(.failure(.networkUnavailable))
        await rig.session.restore()
        #expect(rig.session.connection == .offline)
        #expect(await eventually { rig.sleeper.sleeps.count >= 2 }, "it keeps trying while offline")
        #expect(Array(rig.sleeper.sleeps.prefix(2)) == [.seconds(30), .seconds(60)])

        await rig.api.set(.success(GitHubUser(id: 1, login: "octocat", name: nil)))
        #expect(await eventually { rig.session.user?.login == "octocat" })
        #expect(changes >= 1, "the Core is told about the token")
        let settled = rig.sleeper.sleeps.count
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.sleeper.sleeps.count == settled, "no retries once signed in")
    }

    @Test
    func signingOutStopsTheOfflineRetry() async throws {
        let rig = Rig(credentials: InMemoryCredentialStore(token: "t"), offlineRetry: [.seconds(30)])
        await rig.api.set(.failure(.networkUnavailable))
        await rig.session.restore()
        await rig.session.signOut()
        await rig.api.set(.success(GitHubUser(id: 1, login: "octocat", name: nil)))
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.session.connection == .signedOut(nil))
    }

    @Test
    func aCancelledSignInFinishingLateDoesNotFreeTheNextOne() async {
        let rig = Rig()
        rig.session.signIn()
        #expect(await eventually { if case .waiting = rig.session.connection { true } else { false } })
        rig.session.cancelSignIn()
        rig.session.signIn()
        // Let the cancelled sign-in run to its end.
        try? await Task.sleep(for: .milliseconds(100))
        rig.session.signIn() // must be ignored: one sign-in is still running
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await rig.flow.requests == 2)
        rig.session.cancelSignIn()
    }

    @Test
    func restoreConfirmsASavedTokenAndDropsARevokedOne() async throws {
        let saved = Rig(credentials: InMemoryCredentialStore(token: "t"))
        await saved.session.restore()
        #expect(saved.session.user?.login == "octocat")

        let revoked = Rig(credentials: InMemoryCredentialStore(token: "t"))
        await revoked.api.set(.failure(.authenticationFailed))
        await revoked.session.restore()
        #expect(revoked.session.connection == .signedOut(.sessionExpired))
        #expect(try await revoked.credentials.token() == nil)

        let offline = Rig(credentials: InMemoryCredentialStore(token: "t"))
        await offline.api.set(.failure(.networkUnavailable))
        await offline.session.restore()
        #expect(offline.session.connection == .offline)
        #expect(try await offline.credentials.token() == "t")

        // A failing GitHub is not a signed-out user: the sign-in is kept.
        for failure: GitHubAPIError in [.serverError(statusCode: 502), .invalidResponse] {
            let outage = Rig(credentials: InMemoryCredentialStore(token: "t"))
            await outage.api.set(.failure(failure))
            await outage.session.restore()
            #expect(outage.session.connection == .offline)
            #expect(try await outage.credentials.token() == "t")
        }

        let none = Rig()
        await none.session.restore()
        #expect(none.session.connection == .signedOut(nil))
    }

    @Test
    func signOutRemovesTheLocalToken() async throws {
        let rig = Rig(credentials: InMemoryCredentialStore(token: "t"))
        await rig.session.restore()
        await rig.session.signOut()
        #expect(rig.session.connection == .signedOut(nil))
        #expect(try await rig.credentials.token() == nil)
    }
}
