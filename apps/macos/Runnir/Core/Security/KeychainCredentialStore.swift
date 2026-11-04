import Foundation

actor KeychainCredentialStore: CredentialStoring {
    private let service: String
    private let account: String

    /// github.com's sign-in, as before Enterprise servers.
    static let defaultAccount = "oauth-token"

    init(service: String = KeychainCredentialStore.defaultService, account: String = KeychainCredentialStore.defaultAccount) {
        self.service = service
        self.account = account
    }

    /// The sign-in's Keychain item, or, for UI tests of a Debug build, an
    /// item of their own: a test run never reads the user's sign-in, and its
    /// Sign Out never removes it.
    static var defaultService: String {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return "com.runnir.app.github.ui-testing" }
        #endif
        return service(for: .current)
    }

    /// The build's sign-in service: Runnir Dev keeps its own (B47).
    static func service(for build: RunnirBuild) -> String { "\(build.keychainPrefix).github" }

    func token() async throws -> String? {
        guard let data = try GenericPassword.read(service: service, account: account) else { return nil }
        guard let token = String(data: data, encoding: .utf8) else { throw KeychainError.invalidData }
        return token
    }

    func saveToken(_ token: String) async throws {
        try GenericPassword.write(Data(token.utf8), service: service, account: account)
    }

    func removeToken() async throws {
        try GenericPassword.delete(service: service, account: account)
    }
}

enum KeychainError: Error, Equatable, Sendable {
    case invalidData
    case unhandledStatus(OSStatus)
}
