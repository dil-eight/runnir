import Foundation
import Security

/// A value for local runs is a secret (secrets.X) or a variable (vars.X).
enum LocalRunValueKind: String, Sendable, CaseIterable {
    case secret, variable
}

/// A name, upper-cased, of one kind, in the Repository's values (no
/// environment) or in a GitHub environment's, which a job deploying there
/// takes first.
struct LocalRunValueKey: Hashable, Sendable, Comparable {
    let kind: LocalRunValueKind
    let name: String
    var environment: String?

    /// The same name in another set of values; nil is the Repository's.
    func `in`(_ environment: String?) -> LocalRunValueKey {
        LocalRunValueKey(kind: kind, name: name, environment: environment)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.name, lhs.kind.rawValue, lhs.environment ?? "") < (rhs.name, rhs.kind.rawValue, rhs.environment ?? "")
    }
}

/// Values for local runs, kept per workspace on this Mac.
protocol LocalRunValueStoring: Sendable {
    /// The saved names, without reading any value.
    func keys(workspaceID: UUID) async throws -> Set<LocalRunValueKey>
    func value(workspaceID: UUID, key: LocalRunValueKey) async throws -> String?
    func save(workspaceID: UUID, key: LocalRunValueKey, value: String) async throws
    func remove(workspaceID: UUID, key: LocalRunValueKey) async throws
    func removeAll(workspaceID: UUID) async throws
}

extension Notification.Name {
    /// Values of a workspace changed; `userInfo["workspaceID"]` names it.
    static let localRunValuesChanged = Notification.Name("com.runnir.localRunValuesChanged")
}

/// Tells open views that a workspace's values changed.
private func announceChange(_ workspaceID: UUID) {
    NotificationCenter.default.post(name: .localRunValuesChanged, object: nil, userInfo: ["workspaceID": workspaceID])
}

/// Keychain items, one service per workspace, so its names list in one
/// query without reading values and go in one delete.
actor KeychainLocalRunValueStore: LocalRunValueStoring {
    private let prefix: String

    init(prefix: String = KeychainLocalRunValueStore.defaultPrefix) {
        self.prefix = prefix
    }

    /// UI tests of a Debug build keep their own items.
    static var defaultPrefix: String {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return "com.runnir.app.run-values.ui-testing" }
        #endif
        return prefix(for: .current)
    }

    /// The build's prefix: Runnir Dev keeps its own values (B47).
    static func prefix(for build: RunnirBuild) -> String { "\(build.keychainPrefix).run-values" }

    static func service(prefix: String, workspaceID: UUID) -> String {
        "\(prefix).\(workspaceID.uuidString.lowercased())"
    }

    /// "secret:NAME" for the Repository, "environment:production:secret:NAME"
    /// for an environment.
    static func account(for key: LocalRunValueKey) -> String {
        let account = "\(key.kind.rawValue):\(key.name)"
        return key.environment.map { "\(environmentPrefix)\($0):\(account)" } ?? account
    }

    private static let environmentPrefix = "environment:"

    static func key(fromAccount account: String) -> LocalRunValueKey? {
        var rest = Substring(account)
        var environment: String?
        if rest.hasPrefix(environmentPrefix) {
            rest = rest.dropFirst(environmentPrefix.count)
            // A name and a kind hold no colon; an environment's name may.
            guard let nameColon = rest.lastIndex(of: ":"), let kindColon = rest[..<nameColon].lastIndex(of: ":"),
                  kindColon > rest.startIndex else { return nil }
            environment = String(rest[..<kindColon])
            rest = rest[rest.index(after: kindColon)...]
        }
        let parts = rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, let kind = LocalRunValueKind(rawValue: parts[0]), !parts[1].isEmpty else { return nil }
        return LocalRunValueKey(kind: kind, name: parts[1], environment: environment)
    }

    func keys(workspaceID: UUID) async throws -> Set<LocalRunValueKey> {
        Set(try GenericPassword.accounts(service: service(workspaceID)).compactMap(Self.key(fromAccount:)))
    }

    func value(workspaceID: UUID, key: LocalRunValueKey) async throws -> String? {
        guard let data = try GenericPassword.read(service: service(workspaceID), account: Self.account(for: key)) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else { throw KeychainError.invalidData }
        return value
    }

    func save(workspaceID: UUID, key: LocalRunValueKey, value: String) async throws {
        try GenericPassword.write(Data(value.utf8), service: service(workspaceID), account: Self.account(for: key),
                                  label: "Runnir local run \(key.kind.rawValue) \(key.name)" + (key.environment.map { " for \($0)" } ?? ""))
        announceChange(workspaceID)
    }

    func remove(workspaceID: UUID, key: LocalRunValueKey) async throws {
        try GenericPassword.delete(service: service(workspaceID), account: Self.account(for: key))
        announceChange(workspaceID)
    }

    func removeAll(workspaceID: UUID) async throws {
        try GenericPassword.delete(service: service(workspaceID), account: nil)
        announceChange(workspaceID)
    }

    private func service(_ workspaceID: UUID) -> String { Self.service(prefix: prefix, workspaceID: workspaceID) }
}

/// Values in memory, for tests and previews.
actor InMemoryLocalRunValueStore: LocalRunValueStoring {
    private var values: [UUID: [LocalRunValueKey: String]]
    /// Makes `value` throw, as a Keychain that refuses access would.
    private var failReads = false
    /// Makes `save` throw, as a locked Keychain would.
    private var failSaves = false
    /// How many values were read, for tests.
    private(set) var reads = 0

    init(values: [UUID: [LocalRunValueKey: String]] = [:]) { self.values = values }

    func setFailReads(_ fail: Bool) { failReads = fail }
    func setFailSaves(_ fail: Bool) { failSaves = fail }
    func keys(workspaceID: UUID) async throws -> Set<LocalRunValueKey> { Set(values[workspaceID, default: [:]].keys) }
    func value(workspaceID: UUID, key: LocalRunValueKey) async throws -> String? {
        reads += 1
        if failReads { throw KeychainError.unhandledStatus(errSecAuthFailed) }
        return values[workspaceID]?[key]
    }
    func save(workspaceID: UUID, key: LocalRunValueKey, value: String) async throws {
        if failSaves { throw KeychainError.unhandledStatus(errSecInteractionNotAllowed) }
        values[workspaceID, default: [:]][key] = value
        announceChange(workspaceID)
    }
    func remove(workspaceID: UUID, key: LocalRunValueKey) async throws {
        values[workspaceID]?[key] = nil
        announceChange(workspaceID)
    }
    func removeAll(workspaceID: UUID) async throws {
        values[workspaceID] = nil
        announceChange(workspaceID)
    }
}
