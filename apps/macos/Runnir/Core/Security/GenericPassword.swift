import Foundation
import Security

/// Generic-password Keychain items by service and account: the add-or-update,
/// read and delete steps the credential and local-run value stores share.
enum GenericPassword {
    static func read(service: String, account: String) throws -> Data? {
        var query = base(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unhandledStatus(status) }
        guard let data = item as? Data else { throw KeychainError.invalidData }
        return data
    }

    /// The accounts of a service, without reading any value.
    static func accounts(service: String) throws -> [String] {
        var query = base(service: service, account: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError.unhandledStatus(status) }
        return (items as? [[String: Any]] ?? []).compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// Adds the item, or replaces the data of the one already there.
    static func write(_ data: Data, service: String, account: String, label: String? = nil) throws {
        var query = base(service: service, account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if let label { query[kSecAttrLabel as String] = label }
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(base(service: service, account: account) as CFDictionary,
                                       [kSecValueData as String: data] as CFDictionary)
            guard update == errSecSuccess else { throw KeychainError.unhandledStatus(update) }
            return
        }
        guard status == errSecSuccess else { throw KeychainError.unhandledStatus(status) }
    }

    /// Deletes one item, or every item of the service when `account` is nil.
    static func delete(service: String, account: String?) throws {
        let status = SecItemDelete(base(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.unhandledStatus(status) }
    }

    private static func base(service: String, account: String?) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }
}
