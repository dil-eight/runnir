import Foundation
import Security

/// A value for local runs is a secret (secrets.X) or a variable (vars.X).
enum LocalRunValueKind: String, Sendable, CaseIterable {
    case secret, variable
}

/// A name, upper-cased, of one kind.
struct LocalRunValueKey: Hashable, Sendable, Comparable {
    let kind: LocalRunValueKind
    let name: String

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.name, lhs.kind.rawValue) < (rhs.name, rhs.kind.rawValue)
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
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return "dev.runnir.local-run.ui-testing" }
        #endif
        return "dev.runnir.local-run"
    }

    static func service(prefix: String, workspaceID: UUID) -> String {
        "\(prefix).\(workspaceID.uuidString.lowercased())"
    }

    static func account(for key: LocalRunValueKey) -> String { "\(key.kind.rawValue):\(key.name)" }

    static func key(fromAccount account: String) -> LocalRunValueKey? {
        let parts = account.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, let kind = LocalRunValueKind(rawValue: parts[0]), !parts[1].isEmpty else { return nil }
        return LocalRunValueKey(kind: kind, name: parts[1])
    }

    func keys(workspaceID: UUID) async throws -> Set<LocalRunValueKey> {
        var query = base(workspaceID)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError.unhandledStatus(status) }
        let attributes = items as? [[String: Any]] ?? []
        return Set(attributes.compactMap { ($0[kSecAttrAccount as String] as? String).flatMap(Self.key(fromAccount:)) })
    }

    func value(workspaceID: UUID, key: LocalRunValueKey) async throws -> String? {
        var query = item(workspaceID, key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var data: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &data)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unhandledStatus(status) }
        guard let data = data as? Data, let value = String(data: data, encoding: .utf8) else { throw KeychainError.invalidData }
        return value
    }

    func save(workspaceID: UUID, key: LocalRunValueKey, value: String) async throws {
        let data = Data(value.utf8)
        var query = item(workspaceID, key)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecAttrLabel as String] = "Runnir local run \(key.kind.rawValue) \(key.name)"
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(item(workspaceID, key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard update == errSecSuccess else { throw KeychainError.unhandledStatus(update) }
            return
        }
        guard status == errSecSuccess else { throw KeychainError.unhandledStatus(status) }
    }

    func remove(workspaceID: UUID, key: LocalRunValueKey) async throws {
        let status = SecItemDelete(item(workspaceID, key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.unhandledStatus(status) }
    }

    func removeAll(workspaceID: UUID) async throws {
        let status = SecItemDelete(base(workspaceID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.unhandledStatus(status) }
    }

    private func base(_ workspaceID: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service(prefix: prefix, workspaceID: workspaceID)]
    }

    private func item(_ workspaceID: UUID, _ key: LocalRunValueKey) -> [String: Any] {
        var query = base(workspaceID)
        query[kSecAttrAccount as String] = Self.account(for: key)
        return query
    }
}

/// Values in memory, for tests and previews.
actor InMemoryLocalRunValueStore: LocalRunValueStoring {
    private var values: [UUID: [LocalRunValueKey: String]]
    /// Makes `value` throw, as a Keychain that refuses access would.
    private var failReads = false

    init(values: [UUID: [LocalRunValueKey: String]] = [:]) { self.values = values }

    func setFailReads(_ fail: Bool) { failReads = fail }
    func keys(workspaceID: UUID) async throws -> Set<LocalRunValueKey> { Set(values[workspaceID, default: [:]].keys) }
    func value(workspaceID: UUID, key: LocalRunValueKey) async throws -> String? {
        if failReads { throw KeychainError.unhandledStatus(errSecAuthFailed) }
        return values[workspaceID]?[key]
    }
    func save(workspaceID: UUID, key: LocalRunValueKey, value: String) async throws { values[workspaceID, default: [:]][key] = value }
    func remove(workspaceID: UUID, key: LocalRunValueKey) async throws { values[workspaceID]?[key] = nil }
    func removeAll(workspaceID: UUID) async throws { values[workspaceID] = nil }
}
